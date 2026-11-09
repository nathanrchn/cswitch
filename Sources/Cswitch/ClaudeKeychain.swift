import CswitchCore
import Foundation
import Security

/// Claude's legacy login Keychain entry, not a separate Cswitch credential vault.
protocol ClaudeKeychainAccess: Sendable {
    func read(interactive: Bool) throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

struct ClaudeKeychain: ClaudeKeychainAccess {
    let service = "Claude Code-credentials"
    let account: String
    private static let lock = NSLock()

    init() {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        account = !user.isEmpty && user.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        } ? user : "claude-code-user"
    }

    func read(interactive: Bool) throws -> Data? {
        try access(interactive: interactive) {
            var result: CFTypeRef?
            var query = self.query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = result as? Data, data.count < 2_097_152 else {
                throw CswitchError.message("Claude Code's Keychain credential is unreadable or unexpectedly large.")
            }
            return data
        }
    }

    func write(_ data: Data) throws {
        try access(interactive: true) {
            // Update the data in place: deleting/recreating the entry would lose
            // Claude's trusted applications and the user's Always Allow grant.
            if let existing = try firstItem() {
                try check(SecItemUpdate(existing as CFDictionary, [kSecValueData as String: data] as CFDictionary))
            } else {
                var attributes = query
                attributes[kSecValueData as String] = data
                // Claude reads this legacy entry through /usr/bin/security.
                // New entries trust only that helper and this application.
                var app: SecTrustedApplication?, helper: SecTrustedApplication?, permissions: SecAccess?
                try check(SecTrustedApplicationCreateFromPath(nil, &app))
                try check(SecTrustedApplicationCreateFromPath("/usr/bin/security", &helper))
                guard let app, let helper else { throw CswitchError.message("Could not set up Claude Code's Keychain access.") }
                try check(SecAccessCreate("Claude Code" as CFString, [app, helper] as CFArray, &permissions))
                guard let permissions else { throw CswitchError.message("Could not set up Claude Code's Keychain access.") }
                attributes[kSecAttrAccess as String] = permissions
                try check(SecItemAdd(attributes as CFDictionary, nil))
            }
        }
    }

    func remove() throws {
        try access(interactive: true) {
            guard let existing = try firstItem() else { return }
            let status = SecItemDelete(existing as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    private func firstItem() throws -> [String: Any]? {
        var search = query
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        search[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let reference = result as? Data else {
            throw CswitchError.message("Could not locate Claude Code's Keychain entry.")
        }
        // Match the same first item Claude reads, even if another keychain in
        // the search list contains an entry with the same service and account.
        return [kSecClass as String: kSecClassGenericPassword,
                kSecMatchItemList as String: [reference],
                kSecUseDataProtectionKeychain as String: false]
    }

    private func access<T>(interactive: Bool, _ body: () throws -> T) throws -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Authentication-UI query flags alone do not suppress prompts for
        // legacy login Keychain items. Serialize the process-wide legacy flag
        // and restore it, so background refresh never asks for permission.
        var allowed: DarwinBoolean = true
        try check(SecKeychainGetUserInteractionAllowed(&allowed))
        if !interactive { try check(SecKeychainSetUserInteractionAllowed(false)) }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
        return try body()
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            throw CswitchError.message("macOS did not allow access to Claude Code's Keychain login. Allow Cswitch in the Keychain prompt and retry.")
        case errSecInteractionNotAllowed:
            throw CswitchError.message("Claude Code's Keychain login is locked or needs permission. Click Switch to allow Cswitch, then retry.")
        default:
            throw CswitchError.message("Could not access Claude Code's Keychain login (macOS error \(status)).")
        }
    }
}
