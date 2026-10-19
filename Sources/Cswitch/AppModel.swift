import AppKit
import CswitchCore
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var data = AppData()
    @Published var statuses: [String: DeviceStatus] = [:]
    @Published var deviceErrors: [String: String] = [:]
    @Published var errors: [String: String] = [:]
    @Published var message: String?
    @Published var failure: String?
    @Published var busy = false
    @Published var connected = false
    @Published var loginURL: URL?
    @Published var isSigningIn = false
    @Published var history = HistoryReport()
    @Published var historyLoading = false
    let demo: Bool
    private var service: AccountService?
    private var lastRefresh: Date?
    private var oauthLogin: OAuthLogin?
    private var loginTask: Task<Bool, Never>?
    private var signInWindow: SignInWindow?
    private let historyService = HistoryService()
    private var historyTask: Task<Void, Never>?

    var device: Device { data.devices.first { $0.id == data.selectedDeviceID } ?? .local }
    var accounts: [SavedAccount] { data.accounts }
    var onlineCount: Int { data.devices.filter { statuses[$0.id] != nil }.count }
    func isSelectedEverywhere(_ account: SavedAccount) -> Bool {
        !data.devices.isEmpty && selectedDeviceCount(account) == data.devices.count
    }

    func selectedDeviceCount(_ account: SavedAccount) -> Int {
        data.devices.filter { selectedAccount(on: $0)?.id == account.id }.count
    }

    var selectionIsCurrentEverywhere: Bool { data.devices.allSatisfy { statuses[$0.id] != nil } }

    func selectionIsCached(on device: Device) -> Bool {
        statuses[device.id] == nil && data.deviceSelections?[device.id] != nil
    }

    private func configuredIdentity(on device: Device) -> AccountIdentity? {
        if let status = statuses[device.id] { return status.configuredIdentity }
        return data.deviceSelections?[device.id]?.identity
    }

    func selectedAccount(on device: Device) -> SavedAccount? {
        guard let identity = configuredIdentity(on: device) else { return nil }
        let candidates = accounts.filter { $0.identity.uuid == identity.uuid }
        if let organization = identity.organization, !organization.isEmpty,
           let exact = candidates.first(where: { $0.identity.organization == organization }) { return exact }
        // Some Claude versions omit organizationUuid from display metadata.
        // Resolve only an unambiguous UUID; credential matching stays strict.
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        if let actual = identity.organization, !actual.isEmpty,
           let saved = candidate.identity.organization, !saved.isEmpty, actual != saved { return nil }
        return candidate
    }

    func configuredAccountName(on device: Device) -> String {
        selectedAccount(on: device)?.label ?? configuredIdentity(on: device)?.email ?? "Not detected"
    }

    func selectionDetails() -> String {
        let devices = data.devices.map { device in
            var description = "\(device.name): \(configuredAccountName(on: device))"
            if selectionIsCached(on: device), let checked = data.deviceSelections?[device.id]?.checkedAt {
                description += " (last checked \(checked.formatted(date: .abbreviated, time: .shortened)))"
            }
            return description
        }.joined(separator: "\n")
        return devices + "\nConfigured accounts are shown. Restart running Claude sessions to apply a switch. An existing Mac Keychain login may still take precedence."
    }

    init(demo: Bool) {
        self.demo = demo
        if demo { seedDemo(); return }
        do { service = try AccountService() }
        catch { failure = error.localizedDescription }
    }

    func load() async {
        guard !demo, let service else { return }
        data = await service.snapshot()
        if !history.loaded { history = await historyService.cached(for: data.devices) }
    }

    func appeared() async {
        await load()
        if lastRefresh.map({ Date().timeIntervalSince($0) < 60 }) != true { await refresh(interactive: false) }
    }

    func select(_ id: String) async {
        guard !busy, let selected = data.devices.first(where: { $0.id == id }) else { return }
        data.selectedDeviceID = id; connected = false; lastRefresh = nil
        if !demo, let service {
            do { try await service.select(selected) } catch { failure = error.localizedDescription }
        }
        await refresh(interactive: false)
    }

    func refresh(interactive: Bool = true) async {
        guard !busy else { return }
        if demo { connected = true; return }
        guard let service else { return }
        busy = true; failure = nil
        defer { busy = false }
        let selected = device
        for result in await service.inspectDevices() {
            statuses[result.device.id] = result.status
            deviceErrors[result.device.id] = result.failure
        }
        connected = statuses[selected.id] != nil
        let status = statuses[selected.id]
        refreshHistory()
        for account in accounts {
            do {
                _ = try await service.refresh(account, on: selected, status: status, interactive: interactive)
                errors[account.id] = nil
            } catch { errors[account.id] = friendly(error) }
        }
        data = await service.snapshot(); lastRefresh = Date()
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

    func saveCurrent(label: String) async -> Bool {
        guard !busy else { return false }
        if demo { message = "Demo account saved for all devices."; return true }
        guard let service else { return false }
        busy = true; failure = nil
        do {
            _ = try await service.importCurrent(on: device, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
            data = await service.snapshot()
            statuses[device.id] = try await service.status(device); connected = true
            busy = false
            await refresh()
            return true
        } catch { busy = false; failure = friendly(error); return false }
    }

    func switchTo(_ account: SavedAccount, force: Bool = false) async {
        guard !busy, force || !isSelectedEverywhere(account) else { return }
        if demo {
            for device in data.devices { statuses[device.id] = DeviceStatus(identity: account.identity) }
            return
        }
        guard let service else { return }
        busy = true; failure = nil; message = nil
        defer { busy = false }
        do {
            let report = try await service.switchEverywhere(account, force: force)
            for result in report.outcomes {
                statuses[result.device.id] = result.status
                deviceErrors[result.device.id] = result.failure
            }
            data = await service.snapshot(); connected = statuses[device.id] != nil
            let failed = report.outcomes.filter { $0.failure != nil }
            if !failed.isEmpty {
                let succeeded = report.outcomes.count - failed.count
                failure = "Applied on \(succeeded)/\(report.outcomes.count) devices. Retry for " +
                    failed.map { $0.device.name }.joined(separator: ", ") + ". See All devices for details."
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
            let added = try await service.addDevice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines))
            data = await service.snapshot(); statuses[added.id] = try await service.status(added)
            connected = true; busy = false
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

    private func seedDemo() {
        data.selectedDeviceID = "amdcluster"
        let now = Date()
        let entries: [(String, String, String, Double, Double, Double)] = [
            ("personal", "Personal", "nathan@example.com", 12, 99, 17),
            ("work", "Work", "nathan@work.example", 38, 42, 26)
        ]
        for (id, label, email, session, weekly, fable) in entries {
            let identity = try! AccountIdentity(json: .object(["accountUuid": .string(id), "emailAddress": .string(email)]))
            data.accounts.append(SavedAccount(id: id, deviceID: "local", label: label, identity: identity,
                usage: UsageSnapshot(windows: [
                    UsageWindow(id: "five_hour", title: "5 hours", used: session, resetsAt: now.addingTimeInterval(7200)),
                    UsageWindow(id: "seven_day", title: "Weekly", used: weekly, resetsAt: now.addingTimeInterval(26340)),
                    UsageWindow(id: "seven_day_fable", title: "Fable", used: fable, resetsAt: now.addingTimeInterval(26340))])))
        }
        for device in data.devices { statuses[device.id] = DeviceStatus(identity: data.accounts[0].identity) }
        let records: [TokenRecord] = (0..<100).map { (day: Int) -> TokenRecord in
            let timestamp = now.timeIntervalSince1970 - Double(day) * 86400.0
            let input = Int64(1000 + day * 100)
            let cached = Int64(80000 + day * 1000)
            return TokenRecord(id: "demo-\(day)", timestamp: timestamp, model: "claude-opus-5-5",
                               input: input, output: 2000, cacheRead: cached, cache1h: 5000)
        }
        let demoHistory = TokenHistory(records: records)
        history.days = demoHistory.daily()
        for period in HistoryPeriod.allCases { history.periods[period] = demoHistory.totals(period: period) }
        history.deviceCount = data.devices.count; history.loaded = true
        connected = true
    }
}
