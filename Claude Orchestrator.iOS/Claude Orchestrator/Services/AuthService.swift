import Foundation
import Combine
import ClrcCore

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
    /// The relay base URL (for HTTP calls such as /chat/reply).
    var currentRelayURL: URL { relayURL }

    /// Points this service at a different relay. Tokens stored in the
    /// Keychain are not scoped per relay — there is one fixed
    /// `keychainKey` — so a token minted by relay A is otherwise
    /// indistinguishable from one minted by relay B and would be presented
    /// to B as if it were valid. Without clearing here, switching relays
    /// (or the app's default relay URL itself changing between releases,
    /// with old tokens still sitting in the Keychain from before) makes
    /// `loadFromKeychain()` report `isAuthenticated = true` for a token the
    /// new relay will reject on the first authenticated call — which reads
    /// to the user as the app failing, rather than as "please sign in
    /// again".
    ///
    /// Guarded on an actual change: `login()` re-applies the current URL on
    /// every sign-in attempt, and this must not log the user out of a
    /// freshly-completed login just because that call re-states the same
    /// relay it already knows about.
    func updateRelayURL(_ url: URL) {
        guard url.absoluteString != relayURL.absoluteString else { return }
        relayURL = url
        logout()
    }

    /// A short, non-sensitive description of the current relay for error
    /// messages — the host when there is one, else the full URL. Never
    /// includes credentials or tokens.
    private var relayHostDescription: String {
        relayURL.host ?? relayURL.absoluteString
    }

    // MARK: - Login

    func login(password: String) async throws {
        let url = relayURL.appendingPathComponent("auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["password": password])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // No HTTP response at all: dead host, wrong URL, connection
            // refused, timeout, etc. The relay was never reached — this is
            // NOT a credentials problem, so don't say it is.
            throw AuthError.unreachable(host: relayHostDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.unreachable(host: relayHostDescription)
        }
        guard httpResponse.statusCode == 200 else {
            throw AuthError.forLogin(statusCode: httpResponse.statusCode)
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
    ///
    /// Behaviour is unchanged from before: any failure — rejected token,
    /// unreachable server, or anything else — logs the user out and
    /// requires a fresh sign-in. Only the thrown error differs, so the
    /// reason is diagnosable after the fact.
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = refreshToken else {
            throw AuthError.noRefreshToken
        }

        let url = relayURL.appendingPathComponent("auth/refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            logout()
            throw AuthError.refreshUnreachable(host: relayHostDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logout()
            throw AuthError.refreshUnreachable(host: relayHostDescription)
        }
        guard httpResponse.statusCode == 200 else {
            logout()
            throw AuthError.forRefresh(statusCode: httpResponse.statusCode)
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

/// Login/refresh failures, reported honestly rather than collapsed into a
/// single "invalid password" message. The relay can reject a request for
/// several unrelated reasons (wrong password, rate limiting, being
/// unreachable at all) and only one of those is actually a credentials
/// problem — telling the user the wrong one sends them down the wrong path
/// (e.g. re-typing a password that was correct all along, when the real
/// issue was a stale server URL).
enum AuthError: LocalizedError {
    // MARK: Login failures
    /// 401 on /auth/login — the password itself was wrong.
    case wrongPassword
    /// 429 on /auth/login — the relay's per-IP login limiter kicked in.
    case rateLimited
    /// Any other non-200 on /auth/login — the server responded but with an error.
    case loginServerError(statusCode: Int)
    /// No HTTP response at all on /auth/login — the relay was never reached.
    case unreachable(host: String)

    // MARK: Refresh failures
    case noRefreshToken
    /// 401 on /auth/refresh — the refresh token itself was rejected.
    case sessionExpired
    /// No HTTP response at all on /auth/refresh — the relay was never reached.
    case refreshUnreachable(host: String)
    /// Any other non-200 on /auth/refresh — the server responded but with an error.
    case refreshServerError(statusCode: Int)

    case invalidResponse

    /// Maps a login response's HTTP status code to the specific failure it represents.
    static func forLogin(statusCode: Int) -> AuthError {
        switch AuthFailureReason(statusCode: statusCode) {
        case .unauthorized: return .wrongPassword
        case .rateLimited: return .rateLimited
        case .serverError(let code): return .loginServerError(statusCode: code)
        }
    }

    /// Maps a refresh response's HTTP status code to the specific failure it represents.
    static func forRefresh(statusCode: Int) -> AuthError {
        switch AuthFailureReason(statusCode: statusCode) {
        case .unauthorized: return .sessionExpired
        case .rateLimited, .serverError: return .refreshServerError(statusCode: statusCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return "Неверный пароль."
        case .rateLimited:
            return "Слишком много попыток. Подождите минуту."
        case .loginServerError(let code):
            return "Ошибка сервера (\(code)). Попробуйте чуть позже."
        case .unreachable(let host):
            return "Не удаётся связаться с \(host). Проверьте адрес."
        case .noRefreshToken:
            return "Нужно войти снова."
        case .sessionExpired:
            return "Сессия истекла, войдите снова."
        case .refreshUnreachable(let host):
            return "Пропала связь с \(host). Войдите снова, когда он будет доступен."
        case .refreshServerError(let code):
            return "Ошибка сервера (\(code)) при продлении сессии. Войдите снова."
        case .invalidResponse:
            return "Неожиданный ответ сервера."
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
