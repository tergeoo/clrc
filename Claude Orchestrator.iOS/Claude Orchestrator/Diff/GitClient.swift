import Foundation
import ClrcCore

enum GitClientError: LocalizedError {
    case notARepository
    case agent(String)

    var errorDescription: String? {
        switch self {
        case .notARepository: return "Не git-репозиторий"
        case .agent(let message): return message
        }
    }
}

/// A project's diff as the agent sent it.
struct ProjectDiff {
    let files: [DiffFile]
    let truncated: Bool
}

/// async git requests to a Mac (`git_status`, `git_diff`).
@MainActor
struct GitClient {
    static let statusTimeout: Duration = .seconds(10)
    static let diffTimeout: Duration = .seconds(20)

    let relay: RelayWebSocket

    func status(agentID: String, path: String) async throws -> GitStatusInfo {
        try await RelayRequest.perform(relay: relay, timeout: Self.statusTimeout) { id, done in
            relay.sendGitStatus(agentID: agentID, path: path, requestID: id) { payload in
                if let info = GitStatusInfo(payload: payload) {
                    done(.success(info))
                } else {
                    done(.failure(Self.error(payload)))
                }
            }
        }
    }

    func diff(agentID: String, path: String, files: [String]?) async throws -> ProjectDiff {
        try await RelayRequest.perform(relay: relay, timeout: Self.diffTimeout) { id, done in
            relay.sendGitDiff(agentID: agentID, path: path, files: files, requestID: id) { payload in
                if let message = payload["error"] as? String, !message.isEmpty {
                    done(.failure(Self.error(payload)))
                    return
                }
                let text = payload["diff"] as? String ?? ""
                done(.success(ProjectDiff(files: UnifiedDiff.parse(text),
                                          truncated: payload["truncated"] as? Bool ?? false)))
            }
        }
    }

    private static func error(_ payload: [String: Any]) -> GitClientError {
        let message = payload["error"] as? String ?? ""
        return message.contains("not a git repository") ? .notARepository : .agent(message)
    }
}
