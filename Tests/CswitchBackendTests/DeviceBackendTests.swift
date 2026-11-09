@testable import Cswitch
import CswitchCore
import Foundation
import Testing

private final class MemoryKeychain: ClaudeKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var reads: [Bool] = []
    private var writes = 0
    var denied = false
    var writeFailure: Int?
    var afterWrite: (@Sendable (MemoryKeychain) -> Void)?

    init(_ data: Data?) { stored = data }
    var value: Data? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    var readModes: [Bool] { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    func read(interactive: Bool) throws -> Data? {
        try lock.withLock {
            reads.append(interactive)
            if denied { throw CswitchError.message("Keychain access denied") }
            return stored
        }
    }
    func write(_ data: Data) throws {
        try lock.withLock {
            writes += 1
            if denied || writes == writeFailure { throw CswitchError.message("Keychain write denied") }
            stored = data
        }
        afterWrite?(self)
    }
    func remove() throws { value = nil }
}

private struct Fixture {
    let home: URL
    let config: URL
    let credentials: URL
    let settings: URL
    let original: AccountSecret
    let target: AccountSecret
    let fileData: Data
    let keychainData: Data

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cswitch-tests-" + UUID().uuidString)
        let directory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = home.appendingPathComponent(".claude.json")
        credentials = directory.appendingPathComponent(".credentials.json")
        settings = directory.appendingPathComponent("settings.json")
        original = try AccountSecret(oauth: .object(["accessToken": .string("old-access"), "refreshToken": .string("old-refresh"),
            "expiresAt": .number(10), "subscriptionType": .string("max")]), identity: .object([
                "accountUuid": .string("old"), "emailAddress": .string("old@example.com")]))
        target = try AccountSecret(oauth: .object(["accessToken": .string("new-access"), "refreshToken": .string("new-refresh"),
            "expiresAt": .number(20), "subscriptionType": .string("claude_team"), "scopes": .array([.string("user:profile"), .string("user:inference")])]),
            identity: .object(["accountUuid": .string("new"), "emailAddress": .string("new@example.com")]))
        fileData = try JSONValue.object(["claudeAiOauth": original.oauth, "mcpOAuth": .string("file-mcp")]).data()
        keychainData = try JSONValue.object(["claudeAiOauth": original.oauth, "mcpOAuth": .string("keychain-mcp"), "other": .number(42)]).data()
        try JSONValue.object(["oauthAccount": original.identity, "projects": .object(["trusted": .bool(true)]),
            "cachedUsageUtilization": .object(["utilization": .number(100)])]).data().write(to: config)
        try fileData.write(to: credentials)
        try JSONValue.object(["env": .object(["CLAUDE_CODE_OAUTH_TOKEN": .string("legacy-token"), "KEEP": .string("yes")]),
            "model": .string("keep-model")]).data().write(to: settings)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func root(_ url: URL) throws -> JSONValue { try JSONValue.decode(Data(contentsOf: url)) }
}

@Test func fullMacSwitchUpdatesBothStoresAndClearsStaleUsage() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(f.keychainData)
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    let snapshot = try backend.capture(.local, interactive: true)
    try backend.activate(f.target, on: .local, expected: snapshot.fingerprint)
    let stored = try JSONValue.decode(#require(keychain.value))
    #expect(stored["claudeAiOauth"] == f.target.oauth)
    #expect(stored["mcpOAuth"] == .string("keychain-mcp"))
    #expect(stored["other"] == .number(42))
    #expect(try f.root(f.credentials)["claudeAiOauth"] == f.target.oauth)
    #expect(try f.root(f.credentials)["mcpOAuth"] == .string("file-mcp"))
    #expect(try f.root(f.config)["oauthAccount"] == f.target.identity)
    #expect(try f.root(f.config)["cachedUsageUtilization"] == nil)
    #expect(try f.root(f.config)["projects"]?["trusted"] == .bool(true))
    #expect(try f.root(f.settings)["env"]?["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(try f.root(f.settings)["env"]?["KEEP"] == .string("yes"))
    #expect(try backend.capture(.local, interactive: false).secret == f.target)
}

@Test func captureUsesKeychainEvenWhenFallbackHoldsAnotherLogin() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try JSONValue.object(["claudeAiOauth": f.target.oauth]).data().write(to: f.credentials)
    let keychain = MemoryKeychain(f.keychainData)
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    #expect(try backend.capture(.local, interactive: false).secret?.oauth == f.original.oauth)
    #expect(keychain.readModes == [false])
    keychain.denied = true
    #expect(throws: (any Error).self) { try backend.capture(.local, interactive: false) }
    #expect(keychain.writeCount == 0)
}

@Test func deniedKeychainWriteLeavesEveryFileUnchanged() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let config = try Data(contentsOf: f.config), settings = try Data(contentsOf: f.settings)
    let keychain = MemoryKeychain(f.keychainData)
    keychain.writeFailure = 1
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    let snapshot = try backend.capture(.local, interactive: true)
    #expect(throws: (any Error).self) { try backend.activate(f.target, on: .local, expected: snapshot.fingerprint) }
    #expect(keychain.value == f.keychainData)
    #expect(try Data(contentsOf: f.credentials) == f.fileData)
    #expect(try Data(contentsOf: f.config) == config)
    #expect(try Data(contentsOf: f.settings) == settings)
}

@Test func laterFileFailureRestoresKeychainAndEarlierFiles() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let config = try Data(contentsOf: f.config), settings = try Data(contentsOf: f.settings)
    let keychain = MemoryKeychain(f.keychainData)
    let backend = DeviceBackend(home: f.home, keychain: keychain, writeFile: { data, url in
        if url == f.config { throw CswitchError.message("disk full") }
        try privateWrite(data, to: url)
    })
    let snapshot = try backend.capture(.local, interactive: true)
    #expect(throws: (any Error).self) { try backend.activate(f.target, on: .local, expected: snapshot.fingerprint) }
    #expect(keychain.value == f.keychainData)
    #expect(try Data(contentsOf: f.credentials) == f.fileData)
    #expect(try Data(contentsOf: f.config) == config)
    #expect(try Data(contentsOf: f.settings) == settings)
}

@Test func concurrentKeychainRenewalInvalidatesPreparedSwitch() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(f.keychainData)
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    let snapshot = try backend.capture(.local, interactive: true)
    let renewed = try JSONValue.object(["claudeAiOauth": .object(["accessToken": .string("renewed")])]).data()
    keychain.value = renewed
    #expect(throws: (any Error).self) { try backend.activate(f.target, on: .local, expected: snapshot.fingerprint) }
    #expect(keychain.value == renewed)
    #expect(keychain.writeCount == 0)
    #expect(try Data(contentsOf: f.credentials) == f.fileData)
}

@Test func missingKeychainEntryIsCreatedAndRemovedOnRollback() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(nil)
    let backend = DeviceBackend(home: f.home, keychain: keychain, writeFile: { _, _ in throw CswitchError.message("disk full") })
    let snapshot = try backend.capture(.local, interactive: true)
    #expect(snapshot.secret == f.original)
    #expect(throws: (any Error).self) { try backend.activate(f.target, on: .local, expected: snapshot.fingerprint) }
    #expect(keychain.value == nil)
    #expect(try Data(contentsOf: f.credentials) == f.fileData)
}

@Test func creatingKeychainLoginRetainsFallbackMCPState() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(nil)
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    let snapshot = try backend.capture(.local, interactive: true)
    try backend.activate(f.target, on: .local, expected: snapshot.fingerprint)
    let stored = try JSONValue.decode(#require(keychain.value))
    #expect(stored["claudeAiOauth"] == f.target.oauth)
    #expect(stored["mcpOAuth"] == .string("file-mcp"))
}

@Test func rollbackFailureIsVisibleAndConcurrentLoginIsNotOverwritten() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(f.keychainData)
    let concurrent = Data(#"{"claudeAiOauth":{"accessToken":"concurrent-refresh"}}"#.utf8)
    keychain.afterWrite = { store in store.value = concurrent }
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    let snapshot = try backend.capture(.local, interactive: true)
    do {
        try backend.activate(f.target, on: .local, expected: snapshot.fingerprint)
        Issue.record("Expected verification and rollback failure")
    } catch { #expect(error.localizedDescription.contains("could not be rolled back completely")) }
    #expect(keychain.value == concurrent)
    #expect(try Data(contentsOf: f.credentials) == f.fileData)
}

@Test func invalidKeychainJSONDoesNotFallBackToAnotherLogin() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let keychain = MemoryKeychain(Data("not-json".utf8))
    let backend = DeviceBackend(home: f.home, keychain: keychain)
    #expect(throws: (any Error).self) { try backend.capture(.local, interactive: true) }
    #expect(keychain.writeCount == 0)
}
