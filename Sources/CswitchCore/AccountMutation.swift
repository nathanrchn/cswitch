import Foundation

public enum AccountMutation {
    public static func secret(configuration: JSONValue, credentials: JSONValue) throws -> AccountSecret {
        guard let identity = configuration["oauthAccount"], let oauth = credentials["claudeAiOauth"] else {
            throw CswitchError.message("Sign in to a Claude Code subscription on this device first.")
        }
        return try AccountSecret(oauth: oauth, identity: identity)
    }

    public static func applying(_ secret: AccountSecret, configuration: JSONValue, credentials: JSONValue) throws -> (configuration: JSONValue, credentials: JSONValue) {
        guard var config = configuration.object, var creds = credentials.object else {
            throw CswitchError.message("Claude Code's configuration is invalid. No changes were made.")
        }
        _ = try AccountSecret(oauth: secret.oauth, identity: secret.identity)
        config["oauthAccount"] = secret.identity
        config.removeValue(forKey: "cachedUsageUtilization")
        creds["claudeAiOauth"] = secret.oauth
        return (.object(config), .object(creds))
    }

    /// If the second store fails, restore the first. Never claim a partially applied switch succeeded.
    public static func commit(newCredentials: Data, oldCredentials: Data,
                              writeCredentials: (Data) throws -> Void,
                              writeConfiguration: () throws -> Void) throws {
        try writeCredentials(newCredentials)
        do { try writeConfiguration() }
        catch {
            do { try writeCredentials(oldCredentials) }
            catch { throw CswitchError.message("The switch could not be rolled back. Sign in again on this device before using Claude Code.") }
            throw CswitchError.message("The switch failed and the original credentials were restored.")
        }
    }
}
