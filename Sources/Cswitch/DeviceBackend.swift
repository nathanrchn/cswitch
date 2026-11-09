import CswitchCore
import CryptoKit
import Darwin
import Foundation

struct Capture: Sendable {
    var secret: AccountSecret?
    var fingerprint: String
}

struct DeviceBackend {
    let home: URL
    let keychain: any ClaudeKeychainAccess
    let writeFile: @Sendable (Data, URL) throws -> Void
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         keychain: any ClaudeKeychainAccess = ClaudeKeychain(),
         writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try privateWrite($0, to: $1) }) {
        self.home = home; self.keychain = keychain; self.writeFile = writeFile
    }
    var directory: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var credentialFile: URL { directory.appendingPathComponent(".credentials.json") }
    var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    var config: URL {
        let standard = home.appendingPathComponent(".claude.json")
        let legacy = directory.appendingPathComponent(".claude.json")
        return !FileManager.default.fileExists(atPath: standard.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : standard
    }

    func status(_ device: Device) throws -> DeviceStatus {
        if device.sshHost != nil {
            let result = try remote(device, request: .object(["operation": .string("status")]))
            return DeviceStatus(identity: result["identity"].flatMap { try? AccountIdentity(json: $0) }, claudePath: result["claudePath"]?.string,
                                login: result["login"].flatMap { ClaudeLogin(status: $0) }, version: result["version"]?.string)
        }
        let configuration = try JSONValue.decode(readFile(config))
        let credentials = try? JSONValue.decode(readFile(credentialFile))
        let settings = try JSONValue.decode(readFile(settingsFile))
        // Configured identity is display metadata, not proof of token ownership.
        let tokenOverride = settings["env"]?["CLAUDE_CODE_OAUTH_TOKEN"]
        let secret = credentials.flatMap { try? AccountMutation.secret(configuration: configuration, credentials: $0) }
        let identity = tokenOverride == nil ? try secret?.account : nil
        let configuredIdentity = tokenOverride == nil ? configuration["oauthAccount"].flatMap { try? AccountIdentity(json: $0) } : nil
        let path = findClaude()
        let probe = path.map(ClaudeCLI.probe)
        return DeviceStatus(identity: identity, claudePath: path, configuredIdentity: configuredIdentity,
                            login: probe?.login, version: probe?.version,
                            configuredPlan: secret?.oauth["subscriptionType"]?.string)
    }

    func capture(_ device: Device, interactive: Bool) throws -> Capture {
        if device.sshHost != nil {
            let response = try remote(device, request: .object(["operation": .string("capture")]))
            guard let fingerprint = response["fingerprint"]?.string else { throw malformed() }
            let value = response["secret"]
            let secret: AccountSecret?
            if let value, value != .null { secret = try JSONDecoder().decode(AccountSecret.self, from: value.data()) }
            else { secret = nil }
            return Capture(secret: secret, fingerprint: fingerprint)
        }
        try requireDefaultProfile()
        return try withLocalLocks {
            let configData = try readFile(config)
            let credentialData = try readFile(credentialFile)
            let settingsData = try readFile(settingsFile)
            let keychainData = try keychain.read(interactive: interactive)
            let root = try credentialRoot(keychainData ?? credentialData)
            let secret: AccountSecret?
            if root["claudeAiOauth"] == nil || root["claudeAiOauth"] == .null { secret = nil }
            else { secret = try AccountMutation.secret(configuration: .decode(configData), credentials: root) }
            return Capture(secret: secret,
                           fingerprint: fingerprint(configData, credentialData, settingsData, keychainData))
        }
    }

    func activate(_ secret: AccountSecret, on device: Device, expected: String) throws {
        if device.sshHost != nil {
            let value = try JSONValue.decode(JSONEncoder().encode(secret))
            _ = try remote(device, request: .object(["operation": .string("activate"), "secret": value, "expectedFingerprint": .string(expected)]))
            return
        }
        try requireDefaultProfile()
        try withLocalLocks {
            let oldConfig = try readFile(config)
            let oldCredentials = try readFile(credentialFile)
            let oldSettings = try readFile(settingsFile)
            let oldKeychain = try keychain.read(interactive: true)
            guard fingerprint(oldConfig, oldCredentials, oldSettings, oldKeychain) == expected else {
                throw CswitchError.message("Claude changed its login while switching. Nothing was changed; retry.")
            }
            let updated = try AccountMutation.applying(secret, configuration: .decode(oldConfig), credentials: .decode(oldCredentials))
            let updatedKeychain = try AccountMutation.applying(secret, configuration: .decode(oldConfig),
                credentials: credentialRoot(oldKeychain ?? oldCredentials)).credentials.data()
            guard var settings = try JSONValue.decode(oldSettings).object else { throw CswitchError.message("Claude settings must be a JSON object.") }
            if let env = settings["env"], env != .null, env.object == nil {
                throw CswitchError.message("Claude's env settings are invalid. No changes were made.")
            }
            var env = settings["env"]?.object ?? [:]
            var changes: [(URL, Data, Data)] = [
                (credentialFile, oldCredentials, try updated.credentials.data())
            ]
            // Migrate the previous Cswitch token mode only on an explicit local
            // switch. Keep all other settings and avoid rewriting settings.json
            // at all when there is no token override to remove.
            if env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN") != nil {
                if env.isEmpty { settings.removeValue(forKey: "env") }
                else { settings["env"] = .object(env) }
                changes.append((settingsFile, oldSettings, try JSONValue.object(settings).data()))
            }
            changes.append((config, oldConfig, try updated.configuration.data()))
            var appliedChanges: [(URL, Data?)] = []
            var keychainWritten = false
            do {
                // Fail before touching any files if macOS denies Keychain access.
                try keychain.write(updatedKeychain)
                keychainWritten = true
                for (url, old, new) in changes {
                    let original = FileManager.default.fileExists(atPath: url.path) ? old : nil
                    try writeFile(new, url)
                    appliedChanges.append((url, original))
                }
                // A matching email in auth status is insufficient: verify the
                // full login actually stored in Keychain and the fallback file.
                let appliedKeychain = try keychain.read(interactive: true)
                guard let appliedKeychain,
                      try AccountMutation.secret(configuration: .decode(readFile(config)),
                          credentials: credentialRoot(appliedKeychain)) == secret,
                      try AccountMutation.secret(configuration: .decode(readFile(config)),
                          credentials: .decode(readFile(credentialFile))) == secret,
                      try JSONValue.decode(readFile(settingsFile))["env"]?["CLAUDE_CODE_OAUTH_TOKEN"] == nil else {
                    throw CswitchError.message("The selected login could not be verified in Keychain and Claude's files.")
                }
            } catch {
                var rollbackFailed = false
                for (url, original) in appliedChanges.reversed() {
                    do {
                        if let original { try writeFile(original, url) }
                        else { try FileManager.default.removeItem(at: url) }
                    } catch { rollbackFailed = true }
                }
                if keychainWritten {
                    do {
                        let current = try keychain.read(interactive: true)
                        if current != oldKeychain {
                            guard current == updatedKeychain else {
                                throw CswitchError.message("Claude changed its Keychain login during rollback.")
                            }
                            if let oldKeychain { try keychain.write(oldKeychain) }
                            else { try keychain.remove() }
                        }
                    } catch { rollbackFailed = true }
                }
                if rollbackFailed {
                    throw CswitchError.message("The switch could not be rolled back completely. Reapply the saved account before using Claude Code.")
                }
                if !keychainWritten { throw error }
                throw CswitchError.message("The switch failed; the original Keychain login and files were restored.")
            }
        }
    }

    private func readFile(_ path: URL) throws -> Data {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            throw CswitchError.message("Symlinked Claude state files are not supported.")
        }
        if !FileManager.default.fileExists(atPath: path.path) { return Data("{}".utf8) }
        let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw CswitchError.message("Symlinked Claude state files are not supported.") }
        guard (values.fileSize ?? 0) < 2_097_152 else { throw CswitchError.message("Claude state file is unexpectedly large.") }
        return try Data(contentsOf: path)
    }

    private func credentialRoot(_ data: Data) throws -> JSONValue {
        let root = try JSONValue.decode(data)
        guard root.object != nil else { throw CswitchError.message("Claude Code's credential storage is invalid. No changes were made.") }
        return root
    }

    private func requireDefaultProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        // Custom directories use a different Keychain service name. Never write
        // the default entry when the CLI would actually read another profile.
        guard environment["CLAUDE_CONFIG_DIR"].map({ $0.isEmpty }) ?? true,
              environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"].map({ $0.isEmpty }) ?? true else {
            throw CswitchError.message("Cswitch currently supports Claude's default Mac profile. Unset CLAUDE_CONFIG_DIR and CLAUDE_SECURESTORAGE_CONFIG_DIR before switching.")
        }
    }

    private func fingerprint(_ config: Data, _ credentials: Data, _ settings: Data, _ keychain: Data?) -> String {
        let state = [config, credentials, settings].map { $0.base64EncodedString() } + [keychain?.base64EncodedString() ?? "missing"]
        return SHA256.hash(data: Data(state.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func withLocalLocks<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let locks = [directory.appendingPathComponent(".oauth_refresh.lock"),
                     URL(fileURLWithPath: directory.path + ".lock"), URL(fileURLWithPath: config.path + ".lock")]
        var held: [URL] = []
        let deadline = Date().addingTimeInterval(6)
        defer { for lock in held.reversed() { try? FileManager.default.removeItem(at: lock) } }
        for lock in locks {
            while mkdir(lock.path, 0o700) != 0 {
                guard errno == EEXIST, Date() < deadline else { throw CswitchError.message("Claude is updating its credentials. Wait a few seconds and retry.") }
                Thread.sleep(forTimeInterval: 0.15)
            }
            held.append(lock)
        }
        let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let lockPaths = held.map(\.path)
        heartbeat.schedule(deadline: .now() + 2, repeating: 2)
        heartbeat.setEventHandler { for path in lockPaths { utimes(path, nil) } }
        heartbeat.resume()
        defer { heartbeat.cancel() }
        return try body()
    }

    private func remote(_ device: Device, request: JSONValue) throws -> JSONValue {
        guard let host = device.sshHost, Device.validHost(host),
              let url = Bundle.module.url(forResource: "remote", withExtension: "py") else { throw malformed() }
        let script = try String(contentsOf: url, encoding: .utf8)
        let result = try Subprocess.run("/usr/bin/ssh", arguments: ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", host,
            "python3 -c " + shellQuote(script)], input: request.data(), timeout: 25)
        guard result.status == 0 else {
            // stderr may include shell hooks or banners; keep credentials out of UI and diagnostics.
            throw CswitchError.message("Could not connect to \(host). Check that ‘ssh \(host)’ works without a password and its host key is trusted.")
        }
        guard let envelope = try? JSONValue.decode(result.output) else { throw CswitchError.message("The SSH device returned an unexpected response. Python 3 and a quiet non-interactive shell are required.") }
        if envelope["ok"] != .bool(true) { throw CswitchError.message(envelope["error"]?.string ?? "The remote operation failed.") }
        guard let response = envelope["result"] else { throw malformed() }
        return response
    }

    private func malformed() -> Error { CswitchError.message("Could not read the saved device or account.") }
}

func privateWrite(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temp = directory.appendingPathComponent(".cswitch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw CswitchError.message("Could not save the account index.")
    }
    let handle = try FileHandle(forWritingTo: temp)
    try handle.synchronize()
    try handle.close()
    guard rename(temp.path, url.path) == 0 else { throw CswitchError.message("Could not save the configuration.") }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func findClaude() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Asks the installed Claude Code which login it uses. Claude reads its own
/// credential store (including the macOS Keychain); Cswitch receives only
/// account metadata from `claude auth status`, never a token.
enum ClaudeCLI {
    struct Probe { var login: ClaudeLogin?; var version: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var supportsStatus: [String: Bool] = [:]

    static func probe(_ path: String) -> Probe {
        let version = run(path, ["--version"], timeout: 5)
            .flatMap { $0.split(separator: " ").first.map(String.init) }
            .flatMap { $0.first?.isNumber == true ? $0 : nil }
        // Older releases have no auth command and would treat it as a prompt.
        let key = path + "@" + (version ?? "?")
        let cached = lock.withLock { supportsStatus[key] }
        let supported = cached ?? (run(path, ["auth", "status", "--help"], timeout: 5)?.contains("auth status") == true)
        if cached == nil { lock.withLock { supportsStatus[key] = supported } }
        guard supported, let output = run(path, ["auth", "status", "--json"], timeout: 8),
              let json = try? JSONValue.decode(Data(output.utf8)) else { return Probe(login: nil, version: version) }
        return Probe(login: ClaudeLogin(status: json), version: version)
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ([home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] +
            [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["NO_COLOR"] = "1"
        guard let result = try? Subprocess.run(path, arguments: arguments, environment: environment, timeout: timeout),
              result.output.count < 65_536 else { return nil }
        return String(data: result.output, encoding: .utf8)
    }
}

enum Subprocess {
    struct Result { var output: Data; var status: Int32 }
    static func run(_ path: String, arguments: [String], input: Data = Data(), environment: [String: String]? = nil,
                    timeout: TimeInterval) throws -> Result {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdin; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // A large embedded helper or token payload must not block stdout drainage.
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let hardStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: hardStop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = ended.wait(timeout: .now() + 3)
        watchdog.cancel(); hardStop.cancel()
        guard !process.isRunning else { throw CswitchError.message("The device did not respond in time.") }
        return Result(output: data, status: process.terminationStatus)
    }
}
