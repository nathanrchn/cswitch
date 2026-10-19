import Foundation

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var used: Double
    public var resetsAt: Date?
    public init(id: String, title: String, used: Double, resetsAt: Date? = nil) {
        self.id = id; self.title = title; self.used = used; self.resetsAt = resetsAt
    }
    public func isPastReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public init(windows: [UsageWindow], fetchedAt: Date = Date()) { self.windows = windows; self.fetchedAt = fetchedAt }
    public func isFresh(at now: Date = Date()) -> Bool { now.timeIntervalSince(fetchedAt) < 600 }

    public static func parse(_ data: Data, at now: Date = Date()) throws -> Self {
        let root = try JSONValue.decode(data)
        guard root.object != nil else { throw CswitchError.message("Claude returned an unexpected usage response.") }
        var result: [UsageWindow] = []
        for (key, title) in [("five_hour", "5 hours"), ("seven_day", "Weekly"), ("seven_day_fable", "Fable")] {
            if let window = parseWindow(root[key], key: key, title: title, percentKey: "utilization") { result.append(window) }
        }
        for entry in root["limits"]?.array ?? [] {
            let kind = entry["type"]?.string ?? entry["kind"]?.string
            guard kind == nil || kind == "weekly_scoped" else { continue }
            guard let name = entry["scope"]?["model"]?["display_name"]?.string,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if name.lowercased() == "all models" { continue }
            let key = name.lowercased().contains("fable") ? "seven_day_fable" : "model-" + name.lowercased()
            guard let window = parseWindow(entry, key: key, title: name, percentKey: "percent") else { continue }
            if let existing = result.firstIndex(where: { $0.id == key }) { result[existing] = window }
            else { result.append(window) }
        }
        // Missing buckets remain unknown; a missing response must never imply unused quota.
        guard !result.isEmpty else { throw CswitchError.message("This account does not currently expose numeric usage limits.") }
        return Self(windows: result, fetchedAt: now)
    }

    private static func parseWindow(_ json: JSONValue?, key: String, title: String, percentKey: String) -> UsageWindow? {
        guard let percent = json?[percentKey]?.number, percent.isFinite, percent >= 0 else { return nil }
        let dateString = json?["resets_at"]?.string
        let date = dateString.flatMap { text -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return UsageWindow(id: key, title: title, used: percent, resetsAt: date)
    }
}

public struct Availability: Sendable {
    public var available: Int
    public var measured: Int
    public var total: Int
    public static func count(_ accounts: [SavedAccount], model: String? = nil, at now: Date = Date()) -> Self {
        // The same subscription enrolled on multiple devices must only be counted once.
        let groups = Dictionary(grouping: accounts, by: { $0.identity.uuid + ":" + ($0.identity.organization ?? "") })
        var measured = 0, available = 0
        for group in groups.values {
            guard let snapshot = group.compactMap(\.usage).max(by: { $0.fetchedAt < $1.fetchedAt }), snapshot.isFresh(at: now) else { continue }
            var keys = ["five_hour", "seven_day"]
            if let model { keys.append(model) }
            let windows = keys.compactMap { key in snapshot.windows.first { $0.id == key } }
            guard windows.count == keys.count, !windows.contains(where: { $0.isPastReset(at: now) }) else { continue }
            measured += 1
            if windows.allSatisfy({ $0.used < 100 }) { available += 1 }
        }
        return Self(available: available, measured: measured, total: groups.count)
    }
}
