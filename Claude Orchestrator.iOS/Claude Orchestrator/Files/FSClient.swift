import Foundation
import ClrcCore

enum FSClientError: LocalizedError {
    case timeout
    case agent(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Мак не ответил. Проверьте, что он в сети."
        case .agent(let message): return message
        }
    }
}

/// async/await over the relay's callback file-system API, with a timeout
/// so an offline Mac cannot leave a screen loading forever.
@MainActor
struct FSClient {
    static let timeout: Duration = .seconds(10)

    let relay: RelayWebSocket

    func list(agentID: String, path: String) async throws -> (items: [FSItem], resolvedPath: String?) {
        try await request { id, done in
            relay.sendFSList(agentID: agentID, path: path, requestID: id) { entries, resolved, error in
                done(error.map { .failure(FSClientError.agent($0)) }
                     ?? .success((FSListing.sorted(entries.compactMap(FSItem.init(dict:))), resolved)))
            }
        }
    }

    func read(agentID: String, path: String) async throws -> FileText {
        try await request { id, done in
            relay.sendFSRead(agentID: agentID, path: path, requestID: id) { data, error in
                done(error.map { .failure(FSClientError.agent($0)) } ?? .success(FileText(data: data ?? Data())))
            }
        }
    }

    func mkdir(agentID: String, path: String) async throws {
        try await request { id, done in
            relay.sendFSMkdir(agentID: agentID, path: path, requestID: id) { error in
                done(error.map { .failure(FSClientError.agent($0)) } ?? .success(()))
            }
        }
    }

    func delete(agentID: String, path: String) async throws {
        try await request { id, done in
            relay.sendFSDelete(agentID: agentID, path: path, requestID: id) { error in
                done(error.map { .failure(FSClientError.agent($0)) } ?? .success(()))
            }
        }
    }

    private func request<T>(_ send: (String, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await RelayRequest.perform(relay: relay, timeout: Self.timeout, send)
    }
}

/// One correlated relay request: resumes exactly once, with the reply or
/// `FSClientError.timeout`, and forgets the request on timeout.
@MainActor
enum RelayRequest {
    static func perform<T>(relay: RelayWebSocket, timeout: Duration,
                           _ send: (String, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            send(id) { once.resume($0) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                relay.cancelFSRequest(id)
                once.resume(.failure(FSClientError.timeout))
            }
        }
    }
}

@MainActor
private final class ResumeOnce<T> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
