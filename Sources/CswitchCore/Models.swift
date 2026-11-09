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
    /// Subscription type reported with the login, for display only.
    public var plan: String?
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
    /// The account in the device's credential files. It does not inspect running
    /// Claude sessions; on macOS a Keychain login can take precedence over it.
    public var identity: AccountIdentity?
    /// Account metadata for display, even when macOS keeps the token outside the
    /// fallback file. Never use this field to validate or replace credentials.
    public var configuredIdentity: AccountIdentity?
    /// Claude's CLI report can combine configured account labels with a
    /// different credential's plan. Never use it to validate token ownership.
    public var login: ClaudeLogin?
    public var configuredPlan: String?
    public var claudePath: String?
    public var version: String?
    public init(identity: AccountIdentity?, claudePath: String? = nil, configuredIdentity: AccountIdentity? = nil,
                login: ClaudeLogin? = nil, version: String? = nil, configuredPlan: String? = nil) {
        self.identity = identity; self.claudePath = claudePath
        self.configuredIdentity = configuredIdentity ?? identity
        self.login = login; self.version = version; self.configuredPlan = configuredPlan
    }

    /// Claude Code reports a different login than the one in its credential files.
    public var loginOverridesFiles: Bool {
        guard let login, let configuredIdentity, login.email != nil else { return false }
        return !login.matches(configuredIdentity, plan: configuredPlan)
    }
}

/// The subset of `claude auth status --json` Cswitch keeps. It never holds tokens.
public struct ClaudeLogin: Codable, Equatable, Sendable {
    public var loggedIn: Bool
    public var method: String?
    public var email: String?
    public var organization: String?
    public var organizationName: String?
    public var plan: String?

    public init(loggedIn: Bool, method: String? = nil, email: String? = nil, organization: String? = nil,
                organizationName: String? = nil, plan: String? = nil) {
        self.loggedIn = loggedIn; self.method = method; self.email = email
        self.organization = organization; self.organizationName = organizationName; self.plan = plan
    }

    public init?(status json: JSONValue) {
        guard case .bool(let loggedIn)? = json["loggedIn"] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = json[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(loggedIn: loggedIn, method: text("authMethod"), email: text("email"), organization: text("orgId"),
                  organizationName: text("orgName"), plan: text("subscriptionType"))
    }

    public func matches(_ identity: AccountIdentity, plan expectedPlan: String? = nil) -> Bool {
        guard loggedIn, let email, email.caseInsensitiveCompare(identity.email) == .orderedSame else { return false }
        if let expectedPlan, let plan,
           Self.normalizedPlan(expectedPlan) != Self.normalizedPlan(plan) { return false }
        guard let organization, let saved = identity.organization, !saved.isEmpty else { return true }
        return organization == saved
    }

    private static func normalizedPlan(_ plan: String) -> String {
        let value = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("claude_") ? String(value.dropFirst(7)) : value
    }
}

/// The account a device uses, resolved against the saved accounts.
public enum DeviceAccount: Equatable, Sendable {
    case saved(String)
    case unsaved(email: String, organizationName: String?, plan: String?)
    case signedOut
    case other(String)
    case unknown

    public var savedID: String? { if case .saved(let id) = self { return id }; return nil }

    /// Prefers Claude Code's own report and falls back to the configured files.
    public static func resolve(login: ClaudeLogin?, configured: AccountIdentity?, accounts: [SavedAccount]) -> DeviceAccount {
        if let login {
            guard login.loggedIn else { return .signedOut }
            guard let email = login.email else {
                return .other(login.method?.localizedCaseInsensitiveContains("api") == true ? "API key" : (login.method ?? "Other login"))
            }
            let candidates = accounts.filter { login.matches($0.identity, plan: $0.plan) }
            if let organization = login.organization,
               let exact = candidates.first(where: { $0.identity.organization == organization }) { return .saved(exact.id) }
            if candidates.count == 1 { return .saved(candidates[0].id) }
            if let configured, let preferred = candidates.first(where: { $0.identity.matches(configured) }) { return .saved(preferred.id) }
            if accounts.contains(where: { login.matches($0.identity) }) { return .other("Account and subscription differ") }
            return .unsaved(email: email, organizationName: login.organizationName, plan: login.plan)
        }
        guard let identity = configured else { return .unknown }
        let candidates = accounts.filter { $0.identity.uuid == identity.uuid }
        if let organization = identity.organization, !organization.isEmpty,
           let exact = candidates.first(where: { $0.identity.organization == organization }) { return .saved(exact.id) }
        // Some Claude versions omit organizationUuid from display metadata.
        // Resolve only an unambiguous UUID; credential matching stays strict.
        if candidates.count == 1, let candidate = candidates.first {
            let actual = identity.organization ?? "", saved = candidate.identity.organization ?? ""
            if actual.isEmpty || saved.isEmpty || actual == saved { return .saved(candidate.id) }
        }
        return .unsaved(email: identity.email, organizationName: nil, plan: nil)
    }
}

public enum CswitchError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
