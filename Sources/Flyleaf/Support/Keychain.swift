import Foundation
import Security

// Generic password storage. Falls back to a chmod 600 file if the keychain
// rejects us (can happen with re-signed dev builds) so a rebuild never
// silently signs the user out.
enum Keychain {
    private static let service = "com.thomasjohnell.flyleaf"

    static func set(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log(.auth, .warn, "Keychain write failed (\(status)) for \(account), using file fallback")
            fileSet(value, account: account)
        } else {
            fileDelete(account: account)
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        return fileGet(account: account)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        fileDelete(account: account)
    }

    private static func fileURL(_ account: String) -> URL {
        AppPaths.supportDir.appendingPathComponent("secret-\(account)")
    }

    private static func fileSet(_ value: String, account: String) {
        let url = fileURL(account)
        try? value.data(using: .utf8)?.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fileGet(account: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(account)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fileDelete(account: String) {
        try? FileManager.default.removeItem(at: fileURL(account))
    }
}

enum SecretAccount {
    static let anthropicKey = "anthropic-api-key"
    static let openRouterKey = "openrouter-api-key"
}
