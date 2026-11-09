import CswitchCore
import Foundation
import Testing

private func json(_ source: String) throws -> JSONValue { try .decode(Data(source.utf8)) }

@Test func fableAndWeeklyStayIndependent() throws {
    let usage = try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":99},"limits":[{"type":"weekly_scoped","percent":17,"scope":{"model":{"display_name":"Fable"}},"resets_at":"2026-10-20T12:00:00.000Z"}]}"#.utf8))
    #expect(usage.windows.map(\.used) == [0, 99, 17])
    #expect(usage.windows.last?.resetsAt != nil)
}

@Test func malformedBucketsDoNotHideValidSiblings() throws {
    let usage = try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":true},"seven_day":{"utilization":42},"limits":[null,{"percent":"17","scope":{"model":{"display_name":"Fable"}}},{"percent":26,"scope":{"model":{"display_name":"Fable"}}}]}"#.utf8))
    #expect(usage.windows.map(\.used) == [42, 26])
    #expect(!usage.windows.contains { $0.id == "five_hour" })
}

@Test func missingUsageNeverBecomesZero() {
    #expect(throws: (any Error).self) { try UsageSnapshot.parse(Data(#"{"five_hour":null,"seven_day":{}}"#.utf8)) }
}

@Test func duplicateFableBucketUsesScopedValue() throws {
    let usage = try UsageSnapshot.parse(Data(#"{"seven_day_fable":{"utilization":10},"limits":[{"percent":20,"scope":{"model":{"display_name":"Fable"}}}]}"#.utf8))
    #expect(usage.windows.count == 1)
    #expect(usage.windows[0].used == 20)
}

@Test func switchPreservesSettingsAndMCPAuthentication() throws {
    let config = try json(#"{"oauthAccount":{"accountUuid":"old","emailAddress":"old@example.com"},"projects":{"/work":{"hasTrustDialogAccepted":true}},"mcpServers":{"github":{"command":"tool"}},"theme":"dark"}"#)
    let credentials = try json(#"{"claudeAiOauth":{"accessToken":"old"},"mcpOAuth":{"server":{"token":"mcp-secret"}},"other":123}"#)
    let secret = try AccountSecret(oauth: json(#"{"accessToken":"new","refreshToken":"new-refresh"}"#),
        identity: json(#"{"accountUuid":"new","emailAddress":"new@example.com"}"#))
    let applied = try AccountMutation.applying(secret, configuration: config, credentials: credentials)
    #expect(applied.configuration["projects"] == config["projects"])
    #expect(applied.configuration["mcpServers"] == config["mcpServers"])
    #expect(applied.configuration["theme"] == config["theme"])
    #expect(applied.credentials["mcpOAuth"] == credentials["mcpOAuth"])
    #expect(applied.credentials["other"] == credentials["other"])
    #expect(applied.credentials["claudeAiOauth"] == secret.oauth)
    #expect(applied.configuration["oauthAccount"] == secret.identity)
}

@Test func credentialWriteRollsBackWhenConfigWriteFails() {
    var writes: [Data] = []
    #expect(throws: (any Error).self) {
        try AccountMutation.commit(newCredentials: Data("new".utf8), oldCredentials: Data("old".utf8),
            writeCredentials: { writes.append($0) },
            writeConfiguration: { throw CswitchError.message("disk full") })
    }
    #expect(writes == [Data("new".utf8), Data("old".utf8)])
}

@Test func failedCredentialWriteDoesNotTouchConfiguration() {
    var touched = false
    #expect(throws: (any Error).self) {
        try AccountMutation.commit(newCredentials: Data(), oldCredentials: Data(),
            writeCredentials: { _ in throw CswitchError.message("keychain locked") },
            writeConfiguration: { touched = true })
    }
    #expect(!touched)
}

@Test func rollbackFailureIsReported() {
    do {
        var calls = 0
        try AccountMutation.commit(newCredentials: Data(), oldCredentials: Data(), writeCredentials: { _ in
            calls += 1
            if calls > 1 { throw CswitchError.message("locked") }
        }, writeConfiguration: { throw CswitchError.message("full") })
        Issue.record("Expected rollback failure")
    } catch { #expect(error.localizedDescription.contains("could not be rolled back")) }
}

@Test func sshHostCannotInjectCommandsOrOptions() {
    #expect(Device.validHost("amdcluster"))
    #expect(Device.validHost("user@server.example"))
    for invalid in ["-oProxyCommand=bad", "host;touch /tmp/test", "host\nwhoami", "$(whoami)", "host name", "", "host'", "host`id`"] {
        #expect(!Device.validHost(invalid))
    }
}

@Test func availabilityDeduplicatesDevicesAndHonorsWeeklyLimit() throws {
    let now = Date()
    let identity = try AccountIdentity(json: json(#"{"accountUuid":"one","emailAddress":"a@example.com"}"#))
    let usage = UsageSnapshot(windows: [UsageWindow(id: "five_hour", title: "5 hours", used: 0),
        UsageWindow(id: "seven_day", title: "Weekly", used: 100), UsageWindow(id: "seven_day_fable", title: "Fable", used: 17)], fetchedAt: now)
    let a = SavedAccount(deviceID: "local", label: "A", identity: identity, usage: usage)
    let b = SavedAccount(deviceID: "server", label: "A", identity: identity, usage: usage)
    let result = Availability.count([a, b], model: "seven_day_fable", at: now)
    #expect(result.total == 1)
    #expect(result.measured == 1)
    #expect(result.available == 0)
}

@Test func staleAndPastResetMeasurementsStayUnknown() throws {
    let now = Date()
    let identity = try AccountIdentity(json: json(#"{"accountUuid":"one","emailAddress":"a@example.com"}"#))
    let usage = UsageSnapshot(windows: [UsageWindow(id: "five_hour", title: "5 hours", used: 0, resetsAt: now.addingTimeInterval(-1)),
        UsageWindow(id: "seven_day", title: "Weekly", used: 0)], fetchedAt: now)
    var account = SavedAccount(deviceID: "local", label: "A", identity: identity, usage: usage)
    #expect(Availability.count([account], at: now).measured == 0)
    account.usage?.fetchedAt = now.addingTimeInterval(-601)
    #expect(Availability.count([account], at: now).measured == 0)
}

@Test func identityIncludesOrganization() throws {
    let a = try AccountIdentity(json: json(#"{"accountUuid":"same","emailAddress":"a@example.com","organizationUuid":"one"}"#))
    let b = try AccountIdentity(json: json(#"{"accountUuid":"same","emailAddress":"a@example.com","organizationUuid":"two"}"#))
    #expect(!a.matches(b))
}

@Test func claudeAuthStatusKeepsOnlyAccountMetadata() throws {
    let login = try #require(ClaudeLogin(status: json(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.com","orgId":"one","orgName":"Org","subscriptionType":"max","accessToken":"secret"}"#)))
    #expect(login == ClaudeLogin(loggedIn: true, method: "claude.ai", email: "a@example.com", organization: "one", organizationName: "Org", plan: "max"))
    #expect(ClaudeLogin(status: try json(#"{"email":"a@example.com"}"#)) == nil)
}

@Test func deviceAccountPrefersClaudeLoginOverConfiguredFiles() throws {
    let personal = SavedAccount(id: "p", deviceID: "local", label: "Personal", identity: try AccountIdentity(json: json(#"{"accountUuid":"1","emailAddress":"a@example.com","organizationUuid":"one"}"#)))
    let team = SavedAccount(id: "t", deviceID: "local", label: "Team", identity: try AccountIdentity(json: json(#"{"accountUuid":"1","emailAddress":"a@example.com","organizationUuid":"two"}"#)))
    let accounts = [personal, team]
    let keychain = ClaudeLogin(loggedIn: true, email: "A@example.com", organization: "two")
    #expect(DeviceAccount.resolve(login: keychain, configured: personal.identity, accounts: accounts) == .saved("t"))
    #expect(DeviceAccount.resolve(login: nil, configured: personal.identity, accounts: accounts) == .saved("p"))
    let other = ClaudeLogin(loggedIn: true, email: "new@example.com", organizationName: "Lab", plan: "team")
    #expect(DeviceAccount.resolve(login: other, configured: nil, accounts: accounts) == .unsaved(email: "new@example.com", organizationName: "Lab", plan: "team"))
    #expect(DeviceAccount.resolve(login: ClaudeLogin(loggedIn: false), configured: personal.identity, accounts: accounts) == .signedOut)
    #expect(DeviceAccount.resolve(login: ClaudeLogin(loggedIn: true, method: "api_key"), configured: nil, accounts: accounts) == .other("API key"))
    #expect(DeviceAccount.resolve(login: nil, configured: nil, accounts: accounts) == .unknown)
}

@Test func keychainLoginThatDiffersFromFilesIsReported() throws {
    let files = try AccountIdentity(json: json(#"{"accountUuid":"1","emailAddress":"a@example.com","organizationUuid":"one"}"#))
    #expect(DeviceStatus(identity: files, login: ClaudeLogin(loggedIn: true, email: "b@example.com")).loginOverridesFiles)
    #expect(!DeviceStatus(identity: files, login: ClaudeLogin(loggedIn: true, email: "a@example.com", organization: "one")).loginOverridesFiles)
    #expect(!DeviceStatus(identity: files).loginOverridesFiles)
}

@Test func matchingLabelsWithDifferentCredentialPlanDoNotClaimSync() throws {
    let identity = try AccountIdentity(json: json(#"{"accountUuid":"1","emailAddress":"work@example.com","organizationUuid":"org"}"#))
    var saved = SavedAccount(id: "work", deviceID: "local", label: "Work", identity: identity)
    saved.plan = "claude_team"
    let stale = ClaudeLogin(loggedIn: true, email: identity.email, organization: "org", plan: "max")
    #expect(!stale.matches(identity, plan: saved.plan))
    #expect(DeviceAccount.resolve(login: stale, configured: identity, accounts: [saved]).savedID == nil)
    #expect(DeviceStatus(identity: identity, login: stale, configuredPlan: saved.plan).loginOverridesFiles)
    let correct = ClaudeLogin(loggedIn: true, email: identity.email, organization: "org", plan: "team")
    #expect(correct.matches(identity, plan: saved.plan))
    #expect(DeviceAccount.resolve(login: correct, configured: identity, accounts: [saved]) == .saved("work"))
}
