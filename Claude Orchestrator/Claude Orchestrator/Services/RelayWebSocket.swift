import Foundation
import Combine
import UIKit

/// Used for passing terminal data to a session from the relay.
typealias SessionDataHandler = (String, Data) -> Void

// MARK: - RelayWebSocket

/// Manages the single WebSocket connection to the relay server.
/// Multiplexes multiple PTY sessions over one connection.
@MainActor
final class RelayWebSocket: NSObject, ObservableObject {

    // Published state
    @Published var agents: [Agent] = []
    @Published var connectionState: ConnectionState = .disconnected

    enum ConnectionState {
        case disconnected, connecting, connected
    }

    // Dependencies
    private var relayURL: URL
    private let authService: AuthService

    // Internals
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var sessionHandlers: [String: SessionDataHandler] = [:]

    // Callbacks for control events
    var onSessionReady: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onSessionsList: ((String, [[String: Any]]) -> Void)?  // requestID, sessions
    /// Called each time the WS successfully connects and auth completes.
    var onConnect: (() -> Void)?

    // Pending FS request callbacks — keyed by request_id, consumed once
    private var pendingFSRequests: [String: ([String: Any]) -> Void] = [:]

    // Reconnect / watchdog
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var lastMessageDate = Date()

    init(relayURL: URL, authService: AuthService) {
        self.relayURL = relayURL
        self.authService = authService
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        // Re-connect whenever the app comes to the foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private nonisolated func appDidBecomeActive() {
        Task { @MainActor in
            guard self.authService.isAuthenticated else { return }
            if self.connectionState == .disconnected {
                self.connect()
            } else if self.connectionState == .connected {
                // Verify the connection is alive; a stale socket after sleep won't fail
                // until we actually try to use it — send a ping to find out immediately.
                self.webSocketTask?.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in
                            self?.handleConnectionLoss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connection Lifecycle

    func updateRelayURL(_ url: URL) {
        disconnect()
        relayURL = url
        authService.updateRelayURL(url)
    }

    func connect() {
        guard connectionState == .disconnected else { return }
        connectionState = .connecting

        Task {
            await connectInternal()
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
    }

    private func connectInternal() async {
        // Always try refresh first (access token may be expired), fall back to current, else re-login
        let token: String
        if let refreshed = try? await authService.refreshAccessToken() {
            token = refreshed
        } else if let current = authService.currentAccessToken {
            token = current
        } else {
            authService.logout()
            connectionState = .disconnected
            return
        }

        var wsURL = relayURL.appendingPathComponent("ws/client")
        // Convert http(s) → ws(s)
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http"  { components.scheme = "ws" }
        wsURL = components.url ?? wsURL

        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()

        // Send auth message as first message
        let authPayload: [String: Any] = [
            "type": "auth",
            "payload": ["token": token] as [String: Any]
        ]
        if let authData = try? JSONSerialization.data(withJSONObject: authPayload),
           let authStr = String(data: authData, encoding: .utf8) {
            try? await webSocketTask?.send(.string(authStr))
        }

        connectionState = .connected
        lastMessageDate = Date()
        startPing()
        receiveLoop()
        onConnect?()
    }

    // MARK: - Ping

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.webSocketTask?.sendPing { [weak self] error in
                        guard let self else { return }
                        if let error {
                            // Ping failed → connection is dead (e.g. Mac woke from sleep)
                            print("Ping failed: \(error.localizedDescription) — reconnecting")
                            Task { @MainActor in self.handleConnectionLoss() }
                        }
                    }
                }
            }
        }
    }

    /// Tear down the current connection and schedule a reconnect.
    private func handleConnectionLoss() {
        guard connectionState != .disconnected else { return }
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        scheduleReconnect()
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        Task { [weak self] in
            guard let self = self else { return }
            while connectionState == .connected {
                guard let task = webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    await MainActor.run {
                        self.lastMessageDate = Date()
                        self.handle(message: message)
                    }
                } catch {
                    await MainActor.run { self.handleConnectionLoss() }
                    break
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            handleBinaryMessage(data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        let payload = json["payload"] as? [String: Any] ?? [:]

        switch type {
        case "agent_list":
            if let agentsList = payload["agents"] as? [[String: Any]] {
                agents = agentsList.compactMap { dict in
                    guard let id = dict["id"] as? String,
                          let name = dict["name"] as? String else { return nil }
                    return Agent(id: id, name: name, connected: dict["connected"] as? Bool ?? false)
                }
            }

        case "session_ready":
            if let sessionID = payload["session_id"] as? String {
                onSessionReady?(sessionID)
            }

        case "sessions_list":
            if let requestID = payload["request_id"] as? String,
               let sessions = payload["sessions"] as? [[String: Any]] {
                onSessionsList?(requestID, sessions)
            }

        case "fs_list_result", "fs_mkdir_result", "fs_delete_result", "fs_read_result":
            if let requestID = payload["request_id"] as? String {
                pendingFSRequests.removeValue(forKey: requestID)?(payload)
            }

        case "error":
            if let msg = payload["message"] as? String {
                onError?(msg)
            }

        default:
            break
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let (sessionID, payload) = decodeBinaryFrame(data) else { return }
        sessionHandlers[sessionID]?(sessionID, payload)
    }

    // MARK: - Session Management

    func registerSessionHandler(sessionID: String, handler: @escaping SessionDataHandler) {
        sessionHandlers[sessionID] = handler
    }

    func unregisterSessionHandler(sessionID: String) {
        sessionHandlers.removeValue(forKey: sessionID)
    }

    // MARK: - Send API

    func sendConnect(agentID: String, sessionID: String, cols: Int, rows: Int) {
        sendJSON([
            "type": "connect",
            "payload": [
                "agent_id": agentID,
                "session_id": sessionID,
                "cols": cols,
                "rows": rows
            ] as [String: Any]
        ])
    }

    func sendResize(sessionID: String, cols: Int, rows: Int) {
        sendJSON([
            "type": "resize",
            "payload": [
                "session_id": sessionID,
                "cols": cols,
                "rows": rows
            ] as [String: Any]
        ])
    }

    func sendDisconnect(sessionID: String) {
        sendJSON([
            "type": "disconnect",
            "payload": ["session_id": sessionID]
        ])
    }

    func sendInput(sessionID: String, data: Data) {
        let frame = encodeBinaryFrame(sessionID: sessionID, data: data)
        webSocketTask?.send(.data(frame)) { _ in }
    }

    func requestAgentList() {
        sendJSON(["type": "list", "payload": [:] as [String: Any]])
    }

    // MARK: - File System API

    func sendFSList(agentID: String, path: String, requestID: String,
                    completion: @escaping ([[String: Any]], String?, String?) -> Void) {
        pendingFSRequests[requestID] = { payload in
            let entries = payload["entries"] as? [[String: Any]] ?? []
            let resolved = payload["resolved_path"] as? String
            let err = payload["error"] as? String
            completion(entries, resolved, err?.isEmpty == false ? err : nil)
        }
        sendJSON(["type": "fs_list",
                  "payload": ["agent_id": agentID, "request_id": requestID, "path": path] as [String: Any]])
    }

    func sendFSMkdir(agentID: String, path: String, requestID: String,
                     completion: @escaping (String?) -> Void) {
        pendingFSRequests[requestID] = { payload in
            let err = payload["error"] as? String
            completion(err?.isEmpty == false ? err : nil)
        }
        sendJSON(["type": "fs_mkdir",
                  "payload": ["agent_id": agentID, "request_id": requestID, "path": path] as [String: Any]])
    }

    func sendFSDelete(agentID: String, path: String, requestID: String,
                      completion: @escaping (String?) -> Void) {
        pendingFSRequests[requestID] = { payload in
            let err = payload["error"] as? String
            completion(err?.isEmpty == false ? err : nil)
        }
        sendJSON(["type": "fs_delete",
                  "payload": ["agent_id": agentID, "request_id": requestID, "path": path] as [String: Any]])
    }

    func sendFSRead(agentID: String, path: String, requestID: String,
                    completion: @escaping (String?, String?) -> Void) {
        pendingFSRequests[requestID] = { payload in
            let b64 = payload["content"] as? String
            let err = payload["error"] as? String
            let decoded = b64.flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
            completion(decoded, err?.isEmpty == false ? err : nil)
        }
        sendJSON(["type": "fs_read",
                  "payload": ["agent_id": agentID, "request_id": requestID, "path": path] as [String: Any]])
    }

    func requestSessionList(agentID: String, requestID: String) {
        sendJSON([
            "type": "list_sessions",
            "payload": ["agent_id": agentID, "request_id": requestID] as [String: Any]
        ])
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { _ in }
    }

    // MARK: - Binary Framing

    /// [4B: sid_len][sid bytes][data bytes]
    private func encodeBinaryFrame(sessionID: String, data: Data) -> Data {
        let sidBytes = sessionID.data(using: .utf8)!
        var frame = Data()
        var sidLen = UInt32(sidBytes.count).bigEndian
        frame.append(Data(bytes: &sidLen, count: 4))
        frame.append(sidBytes)
        frame.append(data)
        return frame
    }

    private func decodeBinaryFrame(_ frame: Data) -> (String, Data)? {
        guard frame.count >= 4 else { return nil }
        let sidLen = frame.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard frame.count >= Int(4 + sidLen) else { return nil }
        let sidData = frame.subdata(in: 4..<(4 + Int(sidLen)))
        guard let sessionID = String(data: sidData, encoding: .utf8) else { return nil }
        let payload = frame.subdata(in: (4 + Int(sidLen))..<frame.count)
        return (sessionID, payload)
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 2_000_000_000 // 2 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    if self.connectionState == .disconnected {
                        self.connectionState = .connecting
                    }
                }
                await self.connectInternal()
                if await MainActor.run(body: { self.connectionState == .connected }) {
                    break
                }
                delay = min(delay * 2, 60_000_000_000) // max 60s
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayWebSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) { }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            self.connectionState = .disconnected
            // 1008 Policy Violation = invalid/expired token — force re-login
            if closeCode == .policyViolation {
                self.authService.logout()
            } else {
                self.scheduleReconnect()
            }
        }
    }
}

