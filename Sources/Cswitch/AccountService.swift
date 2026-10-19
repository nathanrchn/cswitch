import CswitchCore
import Foundation

struct DeviceSelection: Codable {
    var identity: AccountIdentity?
    var checkedAt: Date
}

struct AppData: Codable {
    var devices: [Device] = [.local, Device(id: "amdcluster", name: "amdcluster", sshHost: "amdcluster")]
    var accounts: [SavedAccount] = []
    var selectedDeviceID = "local"
    /// Display metadata only; refreshed from each reachable device at launch.
    var deviceSelections: [String: DeviceSelection]?
}

struct DeviceOutcome: Sendable {
    let device: Device
    var status: DeviceStatus?
    var failure: String?
}

struct SwitchReport: Sendable {
    var outcomes: [DeviceOutcome]
    var saveFailure: String?
}

private struct PreparedDevice: Sendable {
    let device: Device
    let status: DeviceStatus
    let capture: Capture
}

actor AccountService {
    private var data: AppData
    private let indexURL: URL
    private let backend = DeviceBackend()
    private let secrets = SecretStore()
    private let network = ClaudeAPI()
    private var nextUsageAttempt: [String: Date] = [:]

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        indexURL = root.appendingPathComponent("Cswitch/accounts.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do { data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: indexURL)) }
            catch { throw CswitchError.message("The Cswitch account index could not be read. Your saved credentials have not been changed.") }
        } else { data = AppData() }
        // Merge earlier per-device records without accessing any credential store at launch.
        data.accounts = SavedAccount.mergingDeviceCopies(data.accounts)
    }

    func snapshot() -> AppData { data }
    func status(_ device: Device) throws -> DeviceStatus { try backend.status(device) }

    func inspectDevices() async -> [DeviceOutcome] {
        let devices = data.devices, backend = self.backend
        let result = await withTaskGroup(of: DeviceOutcome.self) { group in
            for device in devices {
                group.addTask {
                    do { return DeviceOutcome(device: device, status: try backend.status(device)) }
                    catch { return DeviceOutcome(device: device, failure: error.localizedDescription) }
                }
            }
            var result: [DeviceOutcome] = []
            for await outcome in group { result.append(outcome) }
            return result
        }
        rememberSelections(result)
        // A read-only inspection still succeeds if its display cache cannot be saved.
        try? persist()
        return result
    }

    func select(_ device: Device) throws { data.selectedDeviceID = device.id; try persist() }

    func addDevice(name: String, host: String) throws -> Device {
        guard Device.validHost(host) else { throw CswitchError.message("Enter an SSH alias or user@hostname, without spaces or command-line options.") }
        if let existing = data.devices.first(where: { $0.sshHost == host }) { return existing }
        let device = Device(name: name.isEmpty ? host : name, sshHost: host)
        _ = try backend.status(device)
        data.devices.append(device); data.selectedDeviceID = device.id
        try persist()
        return device
    }

    func importCurrent(on device: Device, label: String) async throws -> SavedAccount {
        let capture = try backend.capture(device, interactive: true)
        guard let secret = capture.secret else { throw CswitchError.message("Sign in to Claude Code on one device first, then save the account here.") }
        try await network.verify(secret)
        return try save(secret, device: device, label: label)
    }

    func finishLogin(code: String, verifier: String, state: String, label: String) async throws -> SavedAccount {
        let value = try await network.login(code: code, verifier: verifier, state: state)
        try Task.checkCancellation()
        return try save(value, device: .local, label: label)
    }

    func rename(_ id: String, label: String) throws {
        guard let index = data.accounts.firstIndex(where: { $0.id == id }) else { return }
        data.accounts[index].label = label.isEmpty ? data.accounts[index].identity.email : label
        try persist()
    }

    func remove(_ id: String) throws {
        // Removing a saved backup must never log the user out of Claude Code.
        if let account = data.accounts.first(where: { $0.id == id }) {
            for legacy in account.legacySecretIDs ?? [] { try secrets.remove(legacy) }
        }
        try secrets.remove(id)
        data.accounts.removeAll { $0.id == id }
        try persist()
    }

    func switchEverywhere(_ account: SavedAccount, force: Bool = false) async throws -> SwitchReport {
        let devices = data.devices, backend = self.backend
        // Read every target first. Preserve outgoing token generations and choose
        // one verified target login before any device's credential is replaced.
        let preparation = await withTaskGroup(of: (PreparedDevice?, DeviceOutcome?).self) { group in
            for device in devices {
                group.addTask {
                    do {
                        let status = try backend.status(device)
                        guard status.claudePath != nil else { throw CswitchError.message("Claude Code is not installed.") }
                        let capture = try backend.capture(device, interactive: true)
                        return (PreparedDevice(device: device, status: status, capture: capture), nil)
                    } catch { return (nil, DeviceOutcome(device: device, failure: error.localizedDescription)) }
                }
            }
            var ready: [PreparedDevice] = [], failed: [DeviceOutcome] = []
            for await (prepared, failure) in group {
                if let prepared { ready.append(prepared) }
                if let failure { failed.append(failure) }
            }
            return (ready, failed)
        }
        guard !preparation.0.isEmpty else { return SwitchReport(outcomes: preparation.1) }
        for prepared in preparation.0 {
            if let secret = prepared.capture.secret {
                // A Mac CLI may have changed oauthAccount while leaving an old
                // fallback token in place. Never save that mismatched pair over
                // a good account backup. Expired outgoing logins need no renewal.
                do { try await network.verify(secret) }
                catch { continue }
                _ = try save(secret, device: prepared.device, label: "")
            }
        }
        guard var target = try savedSecret(account, interactive: true) else {
            throw CswitchError.message("This account has no saved login. Sign in and save it again.")
        }
        if target.expiresSoon {
            let selected = preparation.0.filter { (try? $0.capture.secret?.account.matches(account.identity)) == true }
            guard selected.isEmpty, preparation.1.isEmpty else {
                throw CswitchError.message("The shared login needs renewing. Open Claude Code on a device where this account works, then refresh Cswitch; reconnect offline devices before trying again.")
            }
            target = try await network.renew(target)
            try writeSecret(target, id: account.id)
        }
        try await network.verify(target)
        let verifiedTarget = target
        let applied = await withTaskGroup(of: DeviceOutcome.self) { group in
            for prepared in preparation.0 {
                group.addTask {
                    do {
                        if force || prepared.status.identity?.matches(account.identity) != true ||
                            prepared.capture.secret?.accessToken != verifiedTarget.accessToken {
                            try backend.activate(verifiedTarget, on: prepared.device, expected: prepared.capture.fingerprint)
                        }
                        let status = try backend.status(prepared.device)
                        guard status.identity?.matches(account.identity) == true else {
                            throw CswitchError.message("The credential files did not confirm the selected account.")
                        }
                        return DeviceOutcome(device: prepared.device, status: status)
                    } catch { return DeviceOutcome(device: prepared.device, failure: error.localizedDescription) }
                }
            }
            var result: [DeviceOutcome] = []
            for await outcome in group { result.append(outcome) }
            return result
        }
        let outcomes = preparation.1 + applied
        rememberSelections(outcomes)
        if let index = data.accounts.firstIndex(where: { $0.id == account.id }) {
            let successfulIDs = outcomes.filter { $0.status != nil }.map { $0.device.id }
            data.accounts[index].sharedDeviceIDs = Array(Set(data.accounts[index].knownDeviceIDs + successfulIDs)).sorted()
        }
        var report = SwitchReport(outcomes: outcomes)
        do { try persist() }
        catch { report.saveFailure = "Device results are shown, but Cswitch could not save their associations. Refresh before continuing." }
        return report
    }

    func refresh(_ account: SavedAccount, on device: Device, status: DeviceStatus?, interactive: Bool) async throws -> UsageSnapshot {
        if let next = nextUsageAttempt[account.id], next > Date() {
            throw CswitchError.message("Usage is temporarily rate limited. Try again after \(next.formatted(date: .omitted, time: .shortened)).")
        }
        let value: AccountSecret
        let active = status?.identity?.matches(account.identity) == true
        if active {
            let current = try backend.capture(device, interactive: interactive)
            guard let secret = current.secret, try secret.account.matches(account.identity) else {
                throw CswitchError.message("The device changed accounts. Refresh its status.")
            }
            try await network.verify(secret)
            _ = try save(secret, device: device, label: "", interactive: interactive)
            // Another device may already have renewed a newer generation of this login.
            value = try await usableSecret(account, on: device, status: status, interactive: interactive, discover: false)
        } else {
            value = try await usableSecret(account, on: device, status: status, interactive: interactive, discover: false)
        }
        do {
            let usage = try await network.usage(value.accessToken)
            if let index = data.accounts.firstIndex(where: { $0.id == account.id }) {
                data.accounts[index].usage = usage; try persist()
            }
            nextUsageAttempt[account.id] = nil
            return usage
        } catch APIError.rateLimited(let retry) {
            nextUsageAttempt[account.id] = Date().addingTimeInterval(max(180, retry))
            throw CswitchError.message("Claude limited usage checks. Saved usage is shown; Cswitch will retry later.")
        } catch APIError.unauthorized {
            throw CswitchError.message("This shared login was rejected. Refresh from a device where it still works, or sign in once and save it again.")
        }
    }

    private func save(_ value: AccountSecret, device: Device, label: String, interactive: Bool = true) throws -> SavedAccount {
        let identity = try value.account
        let existing = data.accounts.firstIndex { $0.identity.matches(identity) }
        var account = existing.map { data.accounts[$0] } ?? SavedAccount(deviceID: device.id, label: identity.email, identity: identity)
        if !label.isEmpty { account.label = label }
        account.sharedDeviceIDs = Array(Set(account.knownDeviceIDs + [device.id])).sorted()
        // A stale replica must not replace a newer credential already held in the vault.
        if let old = try savedSecret(account, interactive: interactive), generation(old) > generation(value) {
            try writeSecret(old, id: account.id)
        } else { try writeSecret(value, id: account.id) }
        if let existing { data.accounts[existing] = account } else { data.accounts.append(account) }
        try persist()
        return account
    }

    private func savedSecret(_ account: SavedAccount, interactive: Bool) throws -> AccountSecret? {
        var newest: AccountSecret?
        for id in [account.id] + (account.legacySecretIDs ?? []) {
            guard let validated = try secrets.read(id) else { continue }
            guard try validated.account.matches(account.identity) else {
                throw CswitchError.message("A saved credential does not match this account. Sign in once and save the account again.")
            }
            if newest == nil || generation(validated) > generation(newest!) { newest = validated }
        }
        return newest
    }

    private func generation(_ secret: AccountSecret) -> Double { secret.oauth["expiresAt"]?.number ?? 0 }

    /// Recover newer tokens from known replicas. This is best-effort coordination;
    /// independent CLI processes on different devices cannot share a distributed lock.
    private func usableSecret(_ supplied: SavedAccount, on device: Device, status: DeviceStatus?, interactive: Bool, discover: Bool) async throws -> AccountSecret {
        let account = data.accounts.first(where: { $0.id == supplied.id }) ?? supplied
        guard var newest = try savedSecret(account, interactive: interactive) else {
            throw CswitchError.message("This account has no file-based saved login. Sign in once to save it without accessing the previous credential store.")
        }
        var activeDevices: [String] = []
        var unavailableDevices: [String] = []
        if discover || newest.expiresSoon {
            for id in account.knownDeviceIDs {
                guard let source = data.devices.first(where: { $0.id == id }) else {
                    unavailableDevices.append(id)
                    continue
                }
                do {
                    let live: DeviceStatus
                    if id == device.id, let status { live = status }
                    else { live = try backend.status(source) }
                    if live.identity?.matches(account.identity) == true {
                        let capture = try backend.capture(source, interactive: interactive)
                        guard let value = capture.secret, try value.account.matches(account.identity) else {
                            throw CswitchError.message("The device changed its login.")
                        }
                        try await network.verify(value)
                        activeDevices.append(source.name)
                        if generation(value) > generation(newest) { newest = value }
                    }
                } catch { unavailableDevices.append(source.name) }
            }
            try writeSecret(newest, id: account.id)
        }
        if newest.expiresSoon {
            if !activeDevices.isEmpty {
                throw CswitchError.message("Open Claude Code on \(activeDevices.joined(separator: ", ")) to renew the shared login, then refresh. If it was revoked, sign in once and save it again.")
            }
            if !unavailableDevices.isEmpty {
                throw CswitchError.message("Reconnect \(unavailableDevices.joined(separator: ", ")) before renewing this shared login, so a newer credential is not overwritten.")
            }
            newest = try await network.renew(newest)
            try writeSecret(newest, id: account.id)
        }
        // Claude owns renewal of selected file logins on both Mac and Linux.
        // Usage refresh may save a newer backup but must never rewrite the Mac's
        // selected credential files or settings as a background side effect.
        return newest
    }

    private func writeSecret(_ value: AccountSecret, id: String) throws {
        try secrets.write(value, id: id)
    }

    private func rememberSelections(_ outcomes: [DeviceOutcome]) {
        var selections = data.deviceSelections ?? [:]
        for outcome in outcomes {
            guard let status = outcome.status else { continue }
            selections[outcome.device.id] = DeviceSelection(identity: status.configuredIdentity, checkedAt: Date())
        }
        data.deviceSelections = selections
    }

    private func persist() throws { try privateWrite(JSONEncoder().encode(data), to: indexURL) }
}

enum APIError: Error { case unauthorized, rateLimited(TimeInterval) }

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class ClaudeAPI {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 18
        config.httpShouldSetCookies = false; config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func usage(_ token: String) async throws -> UsageSnapshot {
        let response = try await request("https://api.anthropic.com/api/oauth/usage", token: token)
        return try UsageSnapshot.parse(response)
    }

    func login(code: String, verifier: String, state: String) async throws -> AccountSecret {
        let body = try JSONValue.object([
            "grant_type": .string("authorization_code"), "code": .string(code),
            "client_id": .string(OAuthLogin.clientID), "redirect_uri": .string(OAuthLogin.redirectURI),
            "code_verifier": .string(verifier), "state": .string(state)
        ]).data()
        let response = try await request("https://platform.claude.com/v1/oauth/token", body: body)
        let token = try JSONValue.decode(response)
        guard let access = token["access_token"]?.string, !access.isEmpty,
              let lifetime = token["expires_in"]?.number, lifetime > 0 else {
            throw CswitchError.message("Claude returned an unexpected sign-in response. Start a new sign-in.")
        }
        let profileBytes = try await request("https://api.anthropic.com/api/oauth/profile", token: access)
        let profile = try JSONValue.decode(profileBytes)
        guard let uuid = profile["account"]?["uuid"]?.string,
              let email = profile["account"]?["email"]?.string ?? profile["account"]?["email_address"]?.string,
              !uuid.isEmpty, !email.isEmpty else {
            throw CswitchError.message("Claude did not return this account's identity. Start a new sign-in.")
        }
        var identity: [String: JSONValue] = ["accountUuid": .string(uuid), "emailAddress": .string(email)]
        if let org = profile["organization"]?["uuid"]?.string { identity["organizationUuid"] = .string(org) }
        if let name = profile["organization"]?["name"]?.string { identity["organizationName"] = .string(name) }
        var oauth: [String: JSONValue] = [
            "accessToken": .string(access), "expiresAt": .number((Date().timeIntervalSince1970 + lifetime) * 1000),
            "scopes": .array((token["scope"]?.string ?? "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
                .split(separator: " ").map { .string(String($0)) })
        ]
        if let refresh = token["refresh_token"]?.string { oauth["refreshToken"] = .string(refresh) }
        if let plan = profile["organization"]?["organization_type"]?.string { oauth["subscriptionType"] = .string(plan) }
        if let tier = profile["organization"]?["rate_limit_tier"]?.string { oauth["rateLimitTier"] = .string(tier) }
        return try AccountSecret(oauth: .object(oauth), identity: .object(identity))
    }

    func verify(_ secret: AccountSecret) async throws {
        let bytes = try await request("https://api.anthropic.com/api/oauth/profile", token: secret.accessToken)
        let profile = try JSONValue.decode(bytes)
        let expected = try secret.account
        guard profile["account"]?["uuid"]?.string == expected.uuid else {
            throw CswitchError.message("Claude's credential and account identity do not match. Sign in on this device and try again.")
        }
        if let organization = profile["organization"]?["uuid"]?.string, let expectedOrg = expected.organization, organization != expectedOrg {
            throw CswitchError.message("Claude's credential belongs to a different organization. Sign in and save this account again.")
        }
    }

    func renew(_ secret: AccountSecret) async throws -> AccountSecret {
        guard let refresh = secret.oauth["refreshToken"]?.string, !refresh.isEmpty else {
            throw CswitchError.message("Sign in to this account on its device and save it again.")
        }
        let body = try JSONValue.object(["grant_type": .string("refresh_token"), "refresh_token": .string(refresh),
            "client_id": .string("9d1c250a-e61b-44d9-88ed-5944d1962f5e")]).data()
        let response: Data
        do { response = try await request("https://platform.claude.com/v1/oauth/token", body: body) }
        catch APIError.unauthorized { throw CswitchError.message("The saved login expired. Sign in on this device and save it again.") }
        let json = try JSONValue.decode(response)
        guard let token = json["access_token"]?.string, let lifetime = json["expires_in"]?.number, lifetime > 0,
              var oauth = secret.oauth.object else { throw CswitchError.message("Claude returned an unexpected login response.") }
        oauth["accessToken"] = .string(token)
        oauth["expiresAt"] = .number((Date().timeIntervalSince1970 + lifetime) * 1000)
        if let refresh = json["refresh_token"]?.string { oauth["refreshToken"] = .string(refresh) }
        if let scope = json["scope"]?.string { oauth["scopes"] = .array(scope.split(separator: " ").map { .string(String($0)) }) }
        return try AccountSecret(oauth: .object(oauth), identity: secret.identity)
    }

    private func request(_ url: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Cswitch/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = body }
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CswitchError.message("Claude did not return a valid response.") }
        switch response.statusCode {
        case 200..<300: return bytes
        case 401: throw APIError.unauthorized
        case 400 where body != nil: throw APIError.unauthorized
        case 403: throw CswitchError.message("Claude denied this request. Check this account's subscription login and usage access.")
        case 429: throw APIError.rateLimited(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 180)
        default: throw CswitchError.message("Claude is unavailable (HTTP \(response.statusCode)). Try again later.")
        }
    }
}
