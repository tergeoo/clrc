import Foundation
import ClrcCore

enum ChatReplyError: LocalizedError {
    case notSignedIn
    case agentOffline
    case chatGone
    case failed(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Войдите в приложение, чтобы отвечать из уведомлений"
        case .agentOffline: return "Мак не в сети — ответ не отправлен"
        case .chatGone: return "Этого чата на Маке уже нет — ответ не отправлен"
        case .failed(let code): return "Ответ не отправлен (\(code))"
        case .unreachable: return "Relay не отвечает — ответ не отправлен"
        }
    }
}

/// Answers a chat from a notification over HTTP (`POST /chat/reply`):
/// there is no socket while the app is in the background.
@MainActor
struct ChatReplyClient {
    static let timeout: TimeInterval = 15

    let auth: AuthService

    func send(_ text: String, to target: PushTarget) async throws {
        guard auth.currentAccessToken != nil else { throw ChatReplyError.notSignedIn }
        var status = try await post(text, to: target)
        if status == 401 {
            // The access token expired while the app slept: renew once.
            _ = try? await auth.refreshAccessToken()
            status = try await post(text, to: target)
        }
        switch status {
        case 200: return
        case 401: throw ChatReplyError.notSignedIn
        case 404: throw ChatReplyError.agentOffline
        case 409: throw ChatReplyError.chatGone
        default: throw ChatReplyError.failed(status)
        }
    }

    private func post(_ text: String, to target: PushTarget) async throws -> Int {
        guard let token = auth.currentAccessToken else { throw ChatReplyError.notSignedIn }
        var request = URLRequest(url: auth.currentRelayURL.appendingPathComponent("chat/reply"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "agent_id": target.agentID, "session_id": target.sessionID, "text": text,
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw ChatReplyError.unreachable
        }
    }
}
