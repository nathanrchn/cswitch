import CswitchCore
import Foundation

/// Plain local files, owned by the current user. No Keychain APIs or automatic
/// migration from older credential stores: importing those would prompt again.
struct SecretStore {
    private var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cswitch/secrets", isDirectory: true)
    }

    private func url(_ id: String) throws -> URL {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw CswitchError.message("Invalid saved account identifier.")
        }
        return directory.appendingPathComponent(id + ".json")
    }

    func read(_ id: String) throws -> AccountSecret? {
        let path = try url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) < 1_048_576 else {
            throw CswitchError.message("The saved credential file is invalid.")
        }
        let value = try JSONDecoder().decode(AccountSecret.self, from: Data(contentsOf: path))
        return try AccountSecret(oauth: value.oauth, identity: value.identity)
    }

    func write(_ value: AccountSecret, id: String) throws {
        let path = try url(id)
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CswitchError.message("The secret storage directory must not be a symlink.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try privateWrite(JSONEncoder().encode(value), to: path)
    }

    func remove(_ id: String) throws {
        let path = try url(id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
