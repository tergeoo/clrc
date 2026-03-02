import Foundation
import Combine

/// Stores and refreshes JWT tokens using URLSession.
@MainActor
final class AuthService: ObservableObject {
    @Published var isAuthenticated: Bool = false

    private var relayURL: URL
    private let keychainKey = "com.claude.terminal.tokens"

    private var accessToken: String?
    private var refreshToken: String?

    private let urlSession: URLSession

    init(relayURL: URL) {
        self.relayURL = relayURL
        self.urlSession = URLSession.shared
        loadFromKeychain()
    }

    var currentAccessToken: String? { accessToken }

    func updateRelayURL(_ url: URL) {
        relayURL = url
    }

    // MARK: - Login

    func login(password: String) async throws {
        let url = relayURL.appendingPathComponent("auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["password": password])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthError.invalidCredentials
        }

        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        self.accessToken = tokens.access_token
        self.refreshToken = tokens.refresh_token
        saveToKeychain()
        isAuthenticated = true
    }

    // MARK: - Token Refresh

    /// Refreshes the access token using the stored refresh token.
    /// Returns the new access token.
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = refreshToken else {
            throw AuthError.noRefreshToken
        }

        let url = relayURL.appendingPathComponent("auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Refresh token expired — require re-login
            logout()
            throw AuthError.sessionExpired
        }

        let result = try JSONDecoder().decode([String: String].self, from: data)
        guard let newToken = result["access_token"] else {
            throw AuthError.invalidResponse
        }
        self.accessToken = newToken
        saveToKeychain()
        return newToken
    }

    // MARK: - Logout

    func logout() {
        accessToken = nil
        refreshToken = nil
        clearKeychain()
        isAuthenticated = false
    }

    // MARK: - Keychain

    private func loadFromKeychain() {
        guard let data = KeychainHelper.load(key: keychainKey),
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return
        }
        accessToken = tokens.access
        refreshToken = tokens.refresh
        isAuthenticated = true
    }

    private func saveToKeychain() {
        let stored = StoredTokens(access: accessToken ?? "", refresh: refreshToken ?? "")
        if let data = try? JSONEncoder().encode(stored) {
            KeychainHelper.save(key: keychainKey, data: data)
        }
    }

    private func clearKeychain() {
        KeychainHelper.delete(key: keychainKey)
    }
}

// MARK: - Supporting types

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
}

private struct StoredTokens: Codable {
    let access: String
    let refresh: String
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case noRefreshToken
    case sessionExpired
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid password"
        case .noRefreshToken: return "No refresh token"
        case .sessionExpired: return "Session expired, please log in again"
        case .invalidResponse: return "Unexpected server response"
        }
    }
}

// MARK: - KeychainHelper

enum KeychainHelper {
    static func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
