/// A snapshot of one live chat session's identity, as known to the client —
/// everything needed to re-register it with the relay/agent after a
/// reconnect. Deliberately a value type independent of `ChatSession` (a
/// `@MainActor` reference type in the app target) so the reattach decision
/// can be tested without SwiftUI/Combine.
public struct ChatSessionSnapshot: Equatable, Sendable {
    public let id: String
    public let agentID: String
    public let cwd: String
    public let name: String
    public let lastSeq: UInt64

    public init(id: String, agentID: String, cwd: String, name: String, lastSeq: UInt64) {
        self.id = id
        self.agentID = agentID
        self.cwd = cwd
        self.name = name
        self.lastSeq = lastSeq
    }
}

/// One action to perform against the relay to bring a chat session back to
/// life after a reconnect: re-send `connect` (the agent's `handleChatConnect`
/// reattaches idempotently) and re-request history from the session's own
/// last-known seq, so a turn that finished while the client was away is not
/// lost.
public struct ChatReattachAction: Equatable, Sendable {
    public let sessionID: String
    public let agentID: String
    public let cwd: String
    public let name: String
    public let afterSeq: UInt64

    public init(sessionID: String, agentID: String, cwd: String, name: String, afterSeq: UInt64) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.cwd = cwd
        self.name = name
        self.afterSeq = afterSeq
    }
}

/// Decides what to re-send to the relay, for every chat session the client
/// currently holds, when the WebSocket reconnects. The relay drops every
/// session belonging to a client as soon as that client unregisters, so
/// every chat session — with no exceptions — needs its own reattach action;
/// a planner that silently skips any of them leaves that session stranded
/// with a `claude` process the client can never reach again.
public enum ChatReattachPlanner {
    public static func plan(chatSessions: [ChatSessionSnapshot]) -> [ChatReattachAction] {
        chatSessions.map { session in
            ChatReattachAction(
                sessionID: session.id,
                agentID: session.agentID,
                cwd: session.cwd,
                name: session.name,
                afterSeq: session.lastSeq
            )
        }
    }
}
