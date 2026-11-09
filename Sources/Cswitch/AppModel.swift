import AppKit
import CswitchCore
import Foundation
import SwiftUI

struct SwitchProgress {
    let accountID: String
    let total: Int
    /// Device ID → whether the switch succeeded there.
    var finished: [String: Bool] = [:]
}

/// The header's one-line answer to "which account do my devices use?".
enum SyncSummary: Equatable {
    case checking
    case switching(label: String, done: Int, total: Int)
    case inSync(label: String, devices: Int, cached: Int)
    case partial(label: String, count: Int, total: Int)
    case mixed(accounts: Int, devices: Int)
    case notDetected
}

enum AccountState: Equatable {
    case active(cached: Bool)
    case partial(count: Int, total: Int)
    case inactive
    case switching
}

@MainActor
final class AppModel: ObservableObject {
    @Published var data = AppData()
    @Published var statuses: [String: DeviceStatus] = [:]
    @Published var deviceErrors: [String: String] = [:]
    @Published var checking: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var message: String?
    @Published var failure: String?
    @Published var busy = false
    @Published var refreshing = false
    @Published var switchProgress: SwitchProgress?
    @Published var dismissedLogins: Set<String> = []
    @Published var loginURL: URL?
    @Published var isSigningIn = false
    @Published var history = HistoryReport()
    @Published var historyLoading = false
    let demo: Bool
    private var service: AccountService?
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var oauthLogin: OAuthLogin?
    private var loginTask: Task<Bool, Never>?
    private var signInWindow: SignInWindow?
    private let historyService = HistoryService()
    private var historyTask: Task<Void, Never>?

    var accounts: [SavedAccount] { data.accounts }
    var devices: [Device] { data.devices }
    var localDevice: Device { devices.first { $0.sshHost == nil } ?? .local }

    init(demo: Bool, mixed: Bool = false) {
        self.demo = demo
        if demo { seedDemo(mixed: mixed); return }
        do { service = try AccountService() }
        catch { failure = error.localizedDescription }
    }

    // MARK: Device state

    func isLive(_ device: Device) -> Bool { statuses[device.id] != nil }

    func lastSeen(_ device: Device) -> Date? { data.deviceSelections?[device.id]?.checkedAt }

    /// Claude Code's own report wins; offline devices use their last observation.
    func deviceAccount(on device: Device) -> DeviceAccount {
        if let status = statuses[device.id] {
            return .resolve(login: status.login, configured: status.configuredIdentity, accounts: accounts)
        }
        guard let cached = data.deviceSelections?[device.id] else { return .unknown }
        return .resolve(login: cached.login, configured: cached.identity, accounts: accounts)
    }

    func account(id: String) -> SavedAccount? { accounts.first { $0.id == id } }

    func activeDevices(for account: SavedAccount) -> [Device] {
        devices.filter { deviceAccount(on: $0).savedID == account.id }
    }

    func accountState(_ account: SavedAccount) -> AccountState {
        if switchProgress?.accountID == account.id { return .switching }
        let active = activeDevices(for: account)
        if !devices.isEmpty, active.count == devices.count { return .active(cached: active.contains { !isLive($0) }) }
        return active.isEmpty ? .inactive : .partial(count: active.count, total: devices.count)
    }

    var lastChecked: Date? {
        devices.compactMap { isLive($0) ? lastSeen($0) : nil }.max() ?? lastRefresh
    }

    var sync: SyncSummary {
        if let progress = switchProgress {
            return .switching(label: account(id: progress.accountID)?.label ?? "account",
                              done: progress.finished.count, total: progress.total)
        }
        let resolved = devices.map { deviceAccount(on: $0) }
        let known = resolved.filter { $0 != .unknown }
        if known.isEmpty { return checking.isEmpty ? .notDetected : .checking }
        let distinct = known.reduce(into: [DeviceAccount]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count == 1, let id = distinct[0].savedID, let account = account(id: id) {
            if known.count == devices.count {
                return .inSync(label: account.label, devices: devices.count, cached: devices.filter { !isLive($0) }.count)
            }
            return .partial(label: account.label, count: known.count, total: devices.count)
        }
        return .mixed(accounts: distinct.count, devices: devices.count)
    }

    /// Live logins Claude Code reports that are not saved in Cswitch.
    var unsavedLogins: [(device: Device, email: String)] {
        devices.compactMap { device in
            guard isLive(device), case .unsaved(let email, _, _) = deviceAccount(on: device),
                  !dismissedLogins.contains(device.id + "|" + email) else { return nil }
            return (device, email)
        }
    }

    func dismissLogin(on device: Device, email: String) { dismissedLogins.insert(device.id + "|" + email) }

    /// On macOS, Claude Code can keep using a Keychain login that differs from its files.
    func keychainOverride(on device: Device) -> Bool {
        device.sshHost == nil && statuses[device.id]?.loginOverridesFiles == true
    }

    func deviceDetails(_ device: Device) -> String {
        var lines: [String] = []
        if let error = deviceErrors[device.id] { lines.append(error) }
        if keychainOverride(on: device), let configured = statuses[device.id]?.configuredIdentity {
            lines.append("Claude's account files select \(name(for: configured)), but its Keychain login or subscription differs. Click Switch to apply the full saved login, then restart Claude Code.")
        }
        if !isLive(device), let seen = lastSeen(device) {
            lines.append("Last checked \(seen.formatted(date: .abbreviated, time: .shortened)).")
        }
        if let host = device.sshHost { lines.append("SSH host: \(host)") }
        return lines.joined(separator: "\n")
    }

    private func name(for identity: AccountIdentity) -> String {
        accounts.first { $0.identity.matches(identity) }?.label ?? identity.email
    }

    func displayName(_ value: DeviceAccount) -> String {
        switch value {
        case .saved(let id): return account(id: id)?.label ?? "Saved account"
        case .unsaved(let email, _, _): return email
        case .signedOut: return "Signed out"
        case .other(let text): return text
        case .unknown: return "Not detected"
        }
    }

    func selectionDetails() -> String {
        devices.map { device in
            var line = "\(device.name): \(displayName(deviceAccount(on: device)))"
            if !isLive(device), let seen = lastSeen(device) { line += " (last checked \(seen.formatted(date: .omitted, time: .shortened)))" }
            return line
        }.joined(separator: "\n") + "\nRestart running Claude Code sessions to apply a switch."
    }

    // MARK: Refresh

    func load() async {
        guard !demo, let service else { return }
        data = await service.snapshot()
        if !history.loaded { history = await historyService.cached(for: data.devices) }
    }

    func appeared() async {
        await load()
        if lastRefresh.map({ Date().timeIntervalSince($0) < 60 }) != true { await refresh(interactive: false) }
        else if refreshTask == nil, switchProgress == nil, let service {
            // Reopening the menu is cheap to keep honest for this Mac.
            await probe([localDevice], with: service)
        }
    }

    func refresh(interactive: Bool = true) async {
        guard !demo, let service, switchProgress == nil else { return }
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh(service, interactive: interactive) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(_ service: AccountService, interactive: Bool) async {
        refreshing = true
        defer { refreshing = false }
        await probe(devices, with: service)
        refreshHistory()
        // Usage needs only a saved login; this Mac's file login is checked for a
        // newer generation, and remote replicas are consulted only near expiry.
        let local = localDevice, status = statuses[local.id]
        await withTaskGroup(of: (String, Error?).self) { group in
            for account in accounts {
                group.addTask {
                    do { _ = try await service.refresh(account, on: local, status: status, interactive: interactive); return (account.id, nil) }
                    catch { return (account.id, error) }
                }
            }
            for await (id, error) in group { errors[id] = error.map(friendly) }
        }
        data = await service.snapshot(); lastRefresh = Date()
    }

    private func probe(_ targets: [Device], with service: AccountService) async {
        checking.formUnion(targets.map(\.id))
        var outcomes: [DeviceOutcome] = []
        await withTaskGroup(of: DeviceOutcome.self) { group in
            for device in targets { group.addTask { service.probe(device) } }
            for await outcome in group {
                outcomes.append(outcome); apply(outcome); checking.remove(outcome.device.id)
            }
        }
        await service.remember(outcomes)
        data = await service.snapshot()
    }

    private func apply(_ outcome: DeviceOutcome) {
        statuses[outcome.device.id] = outcome.status
        deviceErrors[outcome.device.id] = outcome.failure
    }

    private func refreshHistory() {
        guard !demo, historyTask == nil else { return }
        let devices = data.devices, reachable = Set(statuses.keys)
        historyLoading = true
        historyTask = Task { [weak self, historyService] in
            let report = await historyService.refresh(devices, reachable: reachable)
            guard let self, !Task.isCancelled else { return }
            self.history = report; self.historyLoading = false; self.historyTask = nil
        }
    }

    func shutdown() { cancelSignIn(); historyTask?.cancel() }

    // MARK: Actions

    func saveCurrent(on device: Device, label: String) async -> Bool {
        guard !busy else { return false }
        if demo { message = "Demo account saved for all devices."; return true }
        guard let service else { return false }
        busy = true; failure = nil
        do {
            _ = try await service.importCurrent(on: device, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            data = await service.snapshot()
            busy = false
            await refresh()
            return true
        } catch { busy = false; failure = friendly(error); return false }
    }

    func switchTo(_ account: SavedAccount, force: Bool = false) async {
        guard !busy, switchProgress == nil else { return }
        if case .active = accountState(account), !force { return }
        busy = true; failure = nil; message = nil
        switchProgress = SwitchProgress(accountID: account.id, total: devices.count)
        defer { busy = false; switchProgress = nil }
        if demo { return await demoSwitch(account) }
        guard let service else { return }
        // A refresh already in flight finishes first; its device reads stay consistent.
        await refreshTask?.value
        do {
            let report = try await service.switchEverywhere(account, force: force) { [weak self] outcome in
                Task { @MainActor in
                    self?.switchProgress?.finished[outcome.device.id] = outcome.failure == nil
                    self?.apply(outcome)
                }
            }
            report.outcomes.forEach(apply)
            data = await service.snapshot()
            let failed = report.outcomes.filter { $0.failure != nil }
            if !failed.isEmpty {
                let succeeded = report.outcomes.count - failed.count
                failure = "Applied on \(succeeded)/\(report.outcomes.count) devices. Retry for " +
                    failed.map { $0.device.name }.joined(separator: ", ") + ". Hover a device for details."
            }
            if let saveFailure = report.saveFailure { failure = [failure, saveFailure].compactMap { $0 }.joined(separator: " ") }
        } catch { failure = friendly(error) }
    }

    func signIn(label: String) async -> Bool {
        guard !busy else { return false }
        if demo { message = "Demo mode does not open a real login."; return false }
        guard service != nil else { return false }
        busy = true; failure = nil
        let task = Task { await performSignIn(label: label) }
        loginTask = task
        return await task.value
    }

    private func performSignIn(label: String) async -> Bool {
        guard let service else { busy = false; return false }
        let flow = OAuthLogin()
        oauthLogin = flow; isSigningIn = true; message = nil
        defer {
            signInWindow?.finish(); signInWindow = nil
            flow.cancel(); oauthLogin = nil; loginTask = nil
            loginURL = nil; isSigningIn = false; busy = false
        }
        do {
            try Task.checkCancellation()
            let url = try await flow.begin()
            loginURL = url
            message = "Finish signing in in the Cswitch sign-in window."
            let window = SignInWindow(url: url, onCancel: { [weak self] in self?.cancelSignIn() },
                                      onCallback: { try flow.submit($0.absoluteString) })
            signInWindow = window
            try window.open()
            let code = try await flow.waitForCode()
            try Task.checkCancellation()
            message = "Saving your account…"
            _ = try await service.finishLogin(code: code, verifier: flow.verifier, state: flow.state,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            data = await service.snapshot()
            failure = nil; message = "Account saved. Click Switch to use it on all devices."
            return true
        } catch is CancellationError { message = nil; return false }
        catch { failure = friendly(error); return false }
    }

    func cancelSignIn() {
        loginTask?.cancel(); oauthLogin?.cancel()
    }

    func showSignIn() { signInWindow?.present() }

    func submitSignInCode(_ text: String) {
        do { try oauthLogin?.submit(text); failure = nil }
        catch { failure = error.localizedDescription }
    }

    func copySignInLink() {
        guard let loginURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(loginURL.absoluteString, forType: .string)
    }

    func addDevice(name: String, host: String) async -> Bool {
        guard !busy else { return false }
        if demo { return true }
        guard let service else { return false }
        busy = true; failure = nil
        do {
            _ = try await service.addDevice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines))
            data = await service.snapshot()
            busy = false
            await refresh()
            return true
        } catch { busy = false; failure = friendly(error); return false }
    }

    func rename(_ account: SavedAccount, label: String) async {
        if demo { if let i = data.accounts.firstIndex(where: { $0.id == account.id }) { data.accounts[i].label = label }; return }
        guard !busy, let service else { return }
        do { try await service.rename(account.id, label: label); data = await service.snapshot() }
        catch { failure = friendly(error) }
    }

    func forget(_ account: SavedAccount) async {
        if demo { data.accounts.removeAll { $0.id == account.id }; return }
        guard !busy, let service else { return }
        busy = true
        defer { busy = false }
        do {
            try await service.remove(account.id)
            data = await service.snapshot()
            errors[account.id] = nil; failure = nil
            message = "Saved account deleted."
        } catch { failure = friendly(error) }
    }

    private func friendly(_ error: Error) -> String {
        if error is DecodingError { return "The account data could not be read. Sign in and save this account again." }
        if error is APIError { return "This login needs renewing. Open Claude Code on its device, then refresh." }
        return error.localizedDescription
    }

    // MARK: Demo

    private func demoLogin(_ account: SavedAccount) -> ClaudeLogin {
        ClaudeLogin(loggedIn: true, method: "claude.ai", email: account.identity.email,
                    organization: account.identity.organization, plan: account.plan)
    }

    private func demoSwitch(_ account: SavedAccount) async {
        for device in devices where isLive(device) {
            try? await Task.sleep(for: .milliseconds(700))
            statuses[device.id] = DeviceStatus(identity: account.identity, claudePath: "claude", login: demoLogin(account), version: "2.1.303")
            switchProgress?.finished[device.id] = true
        }
    }

    private func seedDemo(mixed: Bool) {
        let now = Date()
        let entries: [(String, String, String, String, Double, Double, Double)] = [
            ("personal", "Personal", "nathan@example.com", "max", 12, 99, 17),
            ("work", "Work", "nathan@work.example", "claude_team", 38, 42, 26)
        ]
        for (id, label, email, plan, session, weekly, fable) in entries {
            let identity = try! AccountIdentity(json: .object(["accountUuid": .string(id), "emailAddress": .string(email)]))
            var account = SavedAccount(id: id, deviceID: "local", label: label, identity: identity,
                usage: UsageSnapshot(windows: [
                    UsageWindow(id: "five_hour", title: "5 hours", used: session, resetsAt: now.addingTimeInterval(7200)),
                    UsageWindow(id: "seven_day", title: "Weekly", used: weekly, resetsAt: now.addingTimeInterval(26340)),
                    UsageWindow(id: "seven_day_fable", title: "Fable", used: fable, resetsAt: now.addingTimeInterval(26340))]))
            account.plan = plan
            data.accounts.append(account)
        }
        let personal = data.accounts[0]
        for device in data.devices {
            statuses[device.id] = DeviceStatus(identity: personal.identity, claudePath: "claude", login: demoLogin(personal), version: "2.1.303")
        }
        if mixed {
            let gpu = Device(id: "gpu-box", name: "gpu-box", sshHost: "gpu-box")
            data.devices.append(gpu)
            data.deviceSelections = [gpu.id: DeviceSelection(identity: personal.identity, login: demoLogin(personal),
                                                              checkedAt: now.addingTimeInterval(-7200))]
            deviceErrors[gpu.id] = "Could not connect to gpu-box. Check that ‘ssh gpu-box’ works without a password and its host key is trusted."
            let research = ClaudeLogin(loggedIn: true, method: "claude.ai", email: "research@lab.org", organization: "lab", plan: "team")
            statuses["amdcluster"] = DeviceStatus(identity: nil, claudePath: "claude", login: research, version: "2.1.303")
        }
        let records: [TokenRecord] = (0..<100).map { (day: Int) -> TokenRecord in
            let timestamp = now.timeIntervalSince1970 - Double(day) * 86400.0
            let input = Int64(1000 + day * 100)
            let cached = Int64(80000 + (day % 7) * 40000)
            return TokenRecord(id: "demo-\(day)", timestamp: timestamp, model: "claude-opus-5-5",
                               input: input, output: 2000, cacheRead: cached, cache1h: 5000)
        }
        let demoHistory = TokenHistory(records: records)
        history.days = demoHistory.daily()
        for period in HistoryPeriod.allCases { history.periods[period] = demoHistory.totals(period: period) }
        history.deviceCount = data.devices.count; history.loaded = true
        lastRefresh = now
    }
}
