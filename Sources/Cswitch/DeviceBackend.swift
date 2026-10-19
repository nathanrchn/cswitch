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
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
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
            return DeviceStatus(identity: result["identity"].flatMap { try? AccountIdentity(json: $0) }, claudePath: result["claudePath"]?.string)
        }
        let configuration = try JSONValue.decode(readFile(config))
        let credentials = try? JSONValue.decode(readFile(credentialFile))
        let settings = try JSONValue.decode(readFile(settingsFile))
        // This is the account selected in the credential files, not a probe of a
        // running CLI or Keychain. An old token override needs an explicit switch
        // before we can report that the file login has been selected.
        let tokenOverride = settings["env"]?["CLAUDE_CODE_OAUTH_TOKEN"]
        let secret = credentials.flatMap { try? AccountMutation.secret(configuration: configuration, credentials: $0) }
        let identity = tokenOverride == nil ? try secret?.account : nil
        let configuredIdentity = tokenOverride == nil ? configuration["oauthAccount"].flatMap { try? AccountIdentity(json: $0) } : nil
        return DeviceStatus(identity: identity, claudePath: findClaude(), configuredIdentity: configuredIdentity)
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
        return try withLocalLocks {
            let configData = try readFile(config)
            let credentialData = try readFile(credentialFile)
            let settingsData = try readFile(settingsFile)
            let root = try JSONValue.decode(credentialData)
            let secret: AccountSecret?
            if root["claudeAiOauth"] == nil || root["claudeAiOauth"] == .null { secret = nil }
            else { secret = try AccountMutation.secret(configuration: .decode(configData), credentials: root) }
            return Capture(secret: secret,
                           fingerprint: fingerprint(configData, credentialData, settingsData))
        }
    }

    func activate(_ secret: AccountSecret, on device: Device, expected: String) throws {
        if device.sshHost != nil {
            let value = try JSONValue.decode(JSONEncoder().encode(secret))
            _ = try remote(device, request: .object(["operation": .string("activate"), "secret": value, "expectedFingerprint": .string(expected)]))
            return
        }
        try withLocalLocks {
            let oldConfig = try readFile(config)
            let oldCredentials = try readFile(credentialFile)
            let oldSettings = try readFile(settingsFile)
            guard fingerprint(oldConfig, oldCredentials, oldSettings) == expected else {
                throw CswitchError.message("Claude changed its login while switching. Nothing was changed; retry.")
            }
            let updated = try AccountMutation.applying(secret, configuration: .decode(oldConfig), credentials: .decode(oldCredentials))
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
            do {
                for (url, old, new) in changes {
                    let original = FileManager.default.fileExists(atPath: url.path) ? old : nil
                    try privateWrite(new, to: url)
                    appliedChanges.append((url, original))
                }
            } catch {
                var rollbackFailed = false
                for (url, original) in appliedChanges.reversed() {
                    do {
                        if let original { try privateWrite(original, to: url) }
                        else { try FileManager.default.removeItem(at: url) }
                    } catch { rollbackFailed = true }
                }
                throw CswitchError.message(rollbackFailed ? "The file switch could not be rolled back. Reapply the saved account before using Claude Code." : "The switch failed; the original files were restored.")
            }
            let applied = try AccountMutation.secret(configuration: .decode(readFile(config)), credentials: .decode(readFile(credentialFile)))
            let appliedSettings = try JSONValue.decode(readFile(settingsFile))
            guard applied == secret, appliedSettings["env"]?["CLAUDE_CODE_OAUTH_TOKEN"] == nil else {
                throw CswitchError.message("The credential files could not be verified. Reapply the saved login and check Claude Code's account.")
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

    private func fingerprint(_ config: Data, _ credentials: Data, _ settings: Data) -> String {
        SHA256.hash(data: config + Data([0]) + credentials + Data([0]) + settings).map { String(format: "%02x", $0) }.joined()
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
    return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

enum Subprocess {
    struct Result { var output: Data; var status: Int32 }
    static func run(_ path: String, arguments: [String], input: Data = Data(), timeout: TimeInterval) throws -> Result {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
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
