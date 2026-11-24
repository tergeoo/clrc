import Foundation
import ClrcCore

enum GitLabError: LocalizedError {
    case notConfigured
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case actionRefused(String)
    case server(Int, String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "GitLab не подключён"
        case .unauthorized: return "Токен GitLab не подходит — обновите его в Настройках"
        case .forbidden: return "Нет прав на это действие в GitLab"
        case .notFound: return "Не найдено в GitLab"
        case .conflict: return "MR обновился — обновите страницу и проверьте изменения"
        case .actionRefused(let message): return message.isEmpty ? "GitLab не разрешил это действие" : "GitLab: \(message)"
        case .server(let code, let message): return message.isEmpty ? "Ошибка GitLab (\(code))" : message
        case .unreachable: return "GitLab не отвечает"
        }
    }
}

/// Sends `GitLabAPI` requests over URLSession and decodes the replies.
struct GitLabClient {
    static let timeout: TimeInterval = 20

    let api: GitLabAPI

    init?(api: GitLabAPI? = GitLabCredentials.api) {
        guard let api else { return nil }
        self.api = api
    }

    func send<T: Decodable>(_ endpoint: GitLabEndpoint, as type: T.Type) async throws -> T {
        let data = try await raw(endpoint, isAction: endpoint.isAction)
        return try GitLabJSON.decoder.decode(T.self, from: data)
    }

    func send(_ endpoint: GitLabEndpoint) async throws {
        _ = try await raw(endpoint, isAction: endpoint.isAction)
    }

    private func raw(_ endpoint: GitLabEndpoint, isAction: Bool) async throws -> Data {
        var request = api.request(endpoint)
        request.timeoutInterval = Self.timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitLabError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw GitLabError.unreachable }
        switch http.statusCode {
        case 200..<300: return data
        // On actions GitLab answers 401/403 for "not allowed / already
        // approved" too: show its message instead of blaming the token.
        case 401 where isAction, 403 where isAction: throw GitLabError.actionRefused(Self.message(from: data))
        case 401: throw GitLabError.unauthorized
        case 403: throw GitLabError.forbidden
        case 404: throw GitLabError.notFound
        case 409, 406: throw GitLabError.conflict
        default: throw GitLabError.server(http.statusCode, Self.message(from: data))
        }
    }

    /// GitLab error bodies: {"message": "…"} or {"message": {"field": ["…"]}} or {"error": "…"}.
    private static func message(from data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if let text = object["message"] as? String { return text }
        if let fields = object["message"] as? [String: [String]] { return fields.values.flatMap { $0 }.joined(separator: "; ") }
        return object["error"] as? String ?? ""
    }
}
