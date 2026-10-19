import Foundation

/// Lossless-enough JSON editing without decoding or discarding unrelated Claude fields.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct Device: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sshHost: String?
    public static let local = Device(id: "local", name: "This Mac", sshHost: nil)
    public init(id: String = UUID().uuidString, name: String, sshHost: String?) {
        self.id = id; self.name = name; self.sshHost = sshHost
    }
    public static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.count < 255 &&
        host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@:-").contains($0) }
    }
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public let uuid: String
    public let email: String
    public let organization: String?
    public init(json: JSONValue) throws {
        guard let uuid = json["accountUuid"]?.string, !uuid.isEmpty,
              let email = json["emailAddress"]?.string, !email.isEmpty else {
            throw CswitchError.message("No Claude Code subscription login found. Sign in on this device first.")
        }
        self.uuid = uuid; self.email = email
        organization = json["organizationUuid"]?.string
    }
    public func matches(_ other: AccountIdentity) -> Bool {
        uuid == other.uuid && organization == other.organization
    }
}

/// Kept in the private credential files. Never include this type in the account index or logs.
public struct AccountSecret: Codable, Equatable, Sendable {
    public var oauth: JSONValue
    public var identity: JSONValue
    public init(oauth: JSONValue, identity: JSONValue) throws {
        guard let token = oauth["accessToken"]?.string, !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
            throw CswitchError.message("Claude Code has no usable subscription credential on this device.")
        }
        _ = try AccountIdentity(json: identity)
        self.oauth = oauth; self.identity = identity
    }
    public var accessToken: String { oauth["accessToken"]?.string ?? "" }
    public var expiresSoon: Bool {
        guard let ms = oauth["expiresAt"]?.number else { return false }
        return ms / 1000 < Date().timeIntervalSince1970 + 300
    }
    public var account: AccountIdentity { get throws { try AccountIdentity(json: identity) } }
}

public struct SavedAccount: Codable, Identifiable, Sendable {
    public var id: String
    /// Original import device, retained for migration; accounts are globally scoped.
    public var deviceID: String
    public var label: String
    public var identity: AccountIdentity
    public var usage: UsageSnapshot?
    public var sharedDeviceIDs: [String]?
    public var legacySecretIDs: [String]?
    public var knownDeviceIDs: [String] { Array(Set([deviceID] + (sharedDeviceIDs ?? []))).sorted() }
    public init(id: String = UUID().uuidString, deviceID: String, label: String, identity: AccountIdentity, usage: UsageSnapshot? = nil) {
        self.id = id; self.deviceID = deviceID; self.label = label; self.identity = identity; self.usage = usage
    }

    public static func mergingDeviceCopies(_ accounts: [SavedAccount]) -> [SavedAccount] {
        var result: [SavedAccount] = []
        for account in accounts {
            if let index = result.firstIndex(where: { $0.identity.matches(account.identity) }) {
                var existing = result[index]
                existing.sharedDeviceIDs = Array(Set(existing.knownDeviceIDs + account.knownDeviceIDs)).sorted()
                existing.legacySecretIDs = Array(Set((existing.legacySecretIDs ?? []) + [account.id] + (account.legacySecretIDs ?? []))).filter { $0 != existing.id }.sorted()
                if existing.label == existing.identity.email && account.label != account.identity.email { existing.label = account.label }
                if let usage = account.usage, usage.fetchedAt > (existing.usage?.fetchedAt ?? .distantPast) { existing.usage = usage }
                result[index] = existing
            } else { result.append(account) }
        }
        return result
    }
}

public struct DeviceStatus: Sendable {
    /// The account configured on the device. It does not inspect running Claude
    /// sessions; on macOS it cannot establish which Keychain entry Claude uses.
    public var identity: AccountIdentity?
    /// Account metadata for display, even when macOS keeps the token outside the
    /// fallback file. Never use this field to validate or replace credentials.
    public var configuredIdentity: AccountIdentity?
    public var claudePath: String?
    public init(identity: AccountIdentity?, claudePath: String? = nil, configuredIdentity: AccountIdentity? = nil) {
        self.identity = identity; self.claudePath = claudePath
        self.configuredIdentity = configuredIdentity ?? identity
    }
}

public enum CswitchError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
