import Foundation
import Security
import ClrcCore

/// The GitLab address (UserDefaults) and token (Keychain only).
enum GitLabCredentials {
    static let urlKey = "gitlab_url"
    private static let service = "clrc.gitlab"
    private static let account = "token"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    /// The configured API, or nil when GitLab is not connected.
    static var api: GitLabAPI? {
        guard let token = token() else { return nil }
        return GitLabAPI(baseURL: baseURL, token: token)
    }

    static func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves (replaces) the token, readable only on this device after unlock.
    @discardableResult
    static func save(token: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
