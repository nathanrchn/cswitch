import CoreFoundation
import Foundation

/// Usage metadata only. Transcript text and tool arguments never enter this type.
public struct TokenRecord: Codable, Sendable {
    public let id: String
    public let timestamp: Double
    public let model: String
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cache5m: Int64
    public let cache1h: Int64
    public let cacheUnknown: Int64
    public let fast: Bool
    public var total: Int64 { input + output + cacheRead + cache5m + cache1h + cacheUnknown }

    public init(id: String, timestamp: Double, model: String, input: Int64, output: Int64,
                cacheRead: Int64 = 0, cache5m: Int64 = 0, cache1h: Int64 = 0, cacheUnknown: Int64 = 0,
                fast: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cache5m = cache5m; self.cache1h = cache1h; self.cacheUnknown = cacheUnknown; self.fast = fast
    }

    public static func parse(_ row: [String: Any], date: (String) -> Date?) -> TokenRecord? {
        guard row["type"] as? String == "assistant", let message = row["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = row["timestamp"] as? String, let timestamp = date(time),
              let model = message["model"] as? String, !model.isEmpty else { return nil }
        let id = (message["id"] as? String).flatMap { $0.isEmpty ? nil : "m:" + $0 } ??
            (row["requestId"] as? String).flatMap { $0.isEmpty ? nil : "r:" + $0 }
        guard let id, id.count > 2 else { return nil }
        func count(_ value: Any?) -> Int64? {
            guard let value else { return 0 }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1e12,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.int64Value
        }
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]),
              let read = count(usage["cache_read_input_tokens"]), let write = count(usage["cache_creation_input_tokens"]),
              let five = count(creation["ephemeral_5m_input_tokens"]),
              let hour = count(creation["ephemeral_1h_input_tokens"]) else { return nil }
        let result = TokenRecord(id: id, timestamp: timestamp.timeIntervalSince1970, model: model,
                                 input: input, output: output, cacheRead: read, cache5m: five, cache1h: hour,
                                 cacheUnknown: max(0, write - five - hour), fast: usage["speed"] as? String == "fast")
        return result.total > 0 ? result : nil
    }

    /// Streamed updates and copied transcripts identify the same API response.
    public static func merge(_ records: some Sequence<TokenRecord>) -> [String: TokenRecord] {
        var result: [String: TokenRecord] = [:]
        for record in records {
            if let old = result[record.id], old.total > record.total ||
                (old.total == record.total && old.output > record.output) ||
                (old.total == record.total && old.output == record.output && old.cacheUnknown <= record.cacheUnknown) { continue }
            result[record.id] = record
        }
        return result
    }
}

public enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "7 days", month = "30 days", all = "All time"
    public var id: String { rawValue }
    public func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        case .all: return .distantPast
        }
    }
}

public struct TokenTotals: Sendable {
    public var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
    public var costLow: Double = 0, costHigh: Double = 0
    public var requests = 0, pricedRequests = 0
    public var unknownModels: Set<String> = []
    public var total: Int64 { input + output + cacheRead + cacheWrite }
    public init() {}
    public mutating func add(_ record: TokenRecord) {
        input += record.input; output += record.output; cacheRead += record.cacheRead
        cacheWrite += record.cache5m + record.cache1h + record.cacheUnknown
        requests += 1
        if let price = ModelPricing.cost(record) {
            costLow += price.lowerBound; costHigh += price.upperBound; pricedRequests += 1
        } else { unknownModels.insert(record.model) }
    }
}

public struct TokenHistory: Sendable {
    public let records: [TokenRecord]
    public init(records: [TokenRecord] = []) { self.records = Array(TokenRecord.merge(records).values) }
    public func totals(period: HistoryPeriod, now: Date = Date()) -> TokenTotals {
        let start = period.start(now: now).timeIntervalSince1970
        return records.filter { $0.timestamp >= start && $0.timestamp <= now.timeIntervalSince1970 }
            .reduce(into: TokenTotals()) { $0.add($1) }
    }
    public func daily(calendar: Calendar = .current) -> [Date: TokenTotals] {
        records.reduce(into: [:]) { days, record in
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: record.timestamp))
            days[day, default: TokenTotals()].add(record)
        }
    }
}

/// Standard first-party API list prices in USD per million tokens, checked on
/// 2026-10-19: https://platform.claude.com/docs/en/about-claude/pricing
/// Historical usage is valued at these rates, not reconstructed invoice rates.
public enum ModelPricing {
    public static let checked = "2026-10-19"
    private struct Rate {
        let input: Double, output: Double, read: Double
        init(_ input: Double, _ output: Double, read: Double? = nil) {
            self.input = input; self.output = output; self.read = read ?? input * 0.1
        }
    }
    private static let rates: [String: Rate] = [
        "claude-fable-5-1": Rate(10, 50, read: 0.25), "claude-fable-5": Rate(10, 50),
        "claude-mythos-5-1": Rate(10, 50, read: 0.25), "claude-mythos-5": Rate(10, 50),
        "claude-opus-5-5": Rate(4, 20, read: 0.2), "claude-opus-5": Rate(5, 25),
        "claude-opus-4-8": Rate(5, 25), "claude-opus-4-7": Rate(5, 25),
        "claude-opus-4-6": Rate(5, 25), "claude-opus-4-5": Rate(5, 25),
        "claude-opus-4-1": Rate(15, 75), "claude-opus-4": Rate(15, 75),
        "claude-sonnet-5-5": Rate(2, 10, read: 0.1), "claude-sonnet-5": Rate(2, 10),
        "claude-sonnet-4-6": Rate(3, 15), "claude-sonnet-4-5": Rate(3, 15), "claude-sonnet-4": Rate(3, 15),
        "claude-haiku-5-5": Rate(0.1, 0.5), "claude-haiku-4-5": Rate(1, 5),
        "claude-3-5-haiku": Rate(0.8, 4)
    ]
    public static func cost(_ record: TokenRecord) -> ClosedRange<Double>? {
        let model = record.model.lowercased().replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-latest$", with: "", options: .regularExpression)
        guard var rate = rates[model] else { return nil }
        let prompt = record.input + record.cacheRead + record.cache5m + record.cache1h + record.cacheUnknown
        if model == "claude-haiku-5-5", prompt > 100_000 { rate = Rate(0.5, 2.5) }
        let fast = record.fast && ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains(model) ? 2.0 : 1.0
        let base = (Double(record.input) * rate.input + Double(record.output) * rate.output +
                    Double(record.cacheRead) * rate.read + Double(record.cache5m) * rate.input * 1.25 +
                    Double(record.cache1h) * rate.input * 2) * fast / 1_000_000
        let unknown = Double(record.cacheUnknown) * rate.input * fast / 1_000_000
        return (base + unknown * 1.25)...(base + unknown * 2)
    }
}
