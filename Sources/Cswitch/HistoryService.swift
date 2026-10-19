import CswitchCore
import Foundation

private struct HistoryStamp: Codable, Equatable, Sendable {
    var size: Int64
    var modified: Double
}
private struct HistoryFile: Codable, Sendable {
    var stamp: HistoryStamp
    var records: [TokenRecord]
    var unreadable: Int?
}
private struct HistoryDelta: Codable, Sendable {
    var files: [String: HistoryFile]
    var unreadable: Int
}
private struct DeviceHistory: Codable, Sendable {
    var files: [String: HistoryFile] = [:]
    var fetchedAt: Date?
    var unreadable = 0
}

struct HistoryReport: Sendable {
    var days: [Date: TokenTotals] = [:]
    var periods: [HistoryPeriod: TokenTotals] = [:]
    var staleDevices: [String] = []
    var deviceCount = 0
    var unreadable = 0
    var cacheFailure = false
    var loaded = false
    func totals(_ period: HistoryPeriod) -> TokenTotals { periods[period] ?? TokenTotals() }
}

actor HistoryService {
    private var devices: [String: DeviceHistory] = [:]
    private let cacheURL: URL
    private var cacheLoaded = false

    init() {
        cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cswitch/history.json")
    }

    private func loadCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let raw = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: DeviceHistory].self, from: raw) { devices = saved }
    }

    func cached(for configured: [Device]) -> HistoryReport {
        loadCache()
        return report(for: configured, failed: [])
    }

    func refresh(_ configured: [Device], reachable: Set<String>) async -> HistoryReport {
        loadCache()
        let previous = devices
        let results = await withTaskGroup(of: (String, HistoryDelta?).self) { group in
            for device in configured {
                let known = (previous[device.id]?.files ?? [:]).mapValues(\.stamp)
                group.addTask {
                    guard reachable.contains(device.id) else { return (device.id, nil) }
                    do { return (device.id, try HistoryReader.read(device, known: known)) }
                    catch { return (device.id, nil) }
                }
            }
            var result: [(String, HistoryDelta?)] = []
            for await item in group { result.append(item) }
            return result
        }
        var failed: Set<String> = []
        for (id, delta) in results {
            guard let delta else { failed.insert(id); continue }
            var saved = devices[id] ?? DeviceHistory()
            for (path, file) in delta.files {
                // Preserve counters for logs that Claude later cleans up. A
                // streamed record is replaced by its most complete version.
                let old = saved.files[path]?.records ?? []
                saved.files[path] = HistoryFile(stamp: file.stamp,
                    records: Array(TokenRecord.merge(old + file.records).values), unreadable: file.unreadable)
            }
            saved.fetchedAt = Date()
            saved.unreadable = delta.unreadable + saved.files.values.reduce(0) { $0 + ($1.unreadable ?? 0) }
            devices[id] = saved
        }
        var result = report(for: configured, failed: failed)
        do { try privateWrite(JSONEncoder().encode(devices), to: cacheURL) }
        catch { result.cacheFailure = true }
        return result
    }

    private func report(for configured: [Device], failed: Set<String>) -> HistoryReport {
        let records = configured.flatMap { device in devices[device.id]?.files.values.flatMap(\.records) ?? [] }
        let history = TokenHistory(records: records)
        var result = HistoryReport()
        result.days = history.daily()
        for period in HistoryPeriod.allCases { result.periods[period] = history.totals(period: period) }
        result.deviceCount = configured.count
        result.staleDevices = configured.filter {
            failed.contains($0.id) || devices[$0.id]?.fetchedAt.map { Date().timeIntervalSince($0) > 600 } != false
        }.map(\.name)
        result.unreadable = configured.reduce(0) { $0 + (devices[$1.id]?.unreadable ?? 0) }
        result.loaded = configured.contains { devices[$0.id]?.fetchedAt != nil }
        return result
    }
}

private enum HistoryReader {
    static func read(_ device: Device, known: [String: HistoryStamp]) throws -> HistoryDelta {
        if let host = device.sshHost {
            guard Device.validHost(host), let url = Bundle.module.url(forResource: "history", withExtension: "py") else {
                throw CswitchError.message("The history helper is unavailable.")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            struct Request: Encodable { let known: [String: HistoryStamp] }
            let result = try Subprocess.run("/usr/bin/ssh", arguments: ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", host,
                "python3 -c " + shellQuote(script)], input: JSONEncoder().encode(Request(known: known)), timeout: 120)
            struct Envelope: Decodable { let ok: Bool; let result: HistoryDelta? }
            guard result.status == 0, let envelope = try? JSONDecoder().decode(Envelope.self, from: result.output),
                  envelope.ok, let delta = envelope.result else { throw CswitchError.message("History could not be read over SSH.") }
            return delta
        }
        return try local(known: known)
    }

    private static func local(known: [String: HistoryStamp]) throws -> HistoryDelta {
        let manager = FileManager.default
        let root = manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardizedFileURL != root.standardizedFileURL {
            throw CswitchError.message("Custom Claude history profiles are not supported.")
        }
        guard (try? manager.destinationOfSymbolicLink(atPath: root.path)) == nil,
              (try? manager.destinationOfSymbolicLink(atPath: projects.path)) == nil else {
            throw CswitchError.message("Symlinked history directories are not supported.")
        }
        guard manager.fileExists(atPath: projects.path) else { return HistoryDelta(files: [:], unreadable: 0) }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var unreadable = 0
        guard let enumerator = manager.enumerator(at: projects, includingPropertiesForKeys: Array(keys),
              errorHandler: { _, _ in unreadable += 1; return true }) else {
            throw CswitchError.message("Claude history is not readable.")
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        var changed: [String: HistoryFile] = [:]
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            do {
                let info = try file.resourceValues(forKeys: keys)
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard file.pathExtension == "jsonl", info.isRegularFile == true else { continue }
                let relative = String(file.path.dropFirst(projects.path.count + 1))
                let stamp = HistoryStamp(size: Int64(info.fileSize ?? 0), modified: info.contentModificationDate?.timeIntervalSince1970 ?? 0)
                guard known[relative] != stamp else { continue }
                var records: [TokenRecord] = []
                var fileUnreadable = 0
                try lines(file) { line in
                    guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { fileUnreadable += 1; return }
                    if let record = TokenRecord.parse(row, date: { fractional.date(from: $0) ?? ordinary.date(from: $0) }) {
                        records.append(record)
                    } else if row["type"] as? String == "assistant",
                              let message = row["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any],
                              ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].contains(where: {
                                  guard let value = usage[$0] else { return false }
                                  return (value as? NSNumber)?.doubleValue != 0
                              }) {
                        fileUnreadable += 1
                    }
                }
                changed[relative] = HistoryFile(stamp: stamp, records: Array(TokenRecord.merge(records).values), unreadable: fileUnreadable)
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        return HistoryDelta(files: changed, unreadable: unreadable)
    }

    private static func lines(_ url: URL, consume: (Data) -> Void) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var pending = Data()
        let maximum = 32 * 1024 * 1024
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                if !line.isEmpty { consume(Data(line)) }
                pending.removeSubrange(...newline)
            }
            guard pending.count <= maximum else { throw CswitchError.message("A history line is too large.") }
        }
        // An incomplete last line is intentionally retried after the file grows.
        if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil { consume(pending) }
    }
}
