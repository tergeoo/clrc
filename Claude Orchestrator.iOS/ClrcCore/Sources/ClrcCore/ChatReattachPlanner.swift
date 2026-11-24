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

/// A snapshot of one live PTY session's identity, as known to the client —
/// everything needed to re-register it with the relay/agent after a
/// reconnect. Value type, independent of `TerminalSession` (a `@MainActor`
/// reference type in the app target), for the same testability reason as
/// `ChatSessionSnapshot`.
public struct PTYSessionSnapshot: Equatable, Sendable {
    public let id: String
    public let agentID: String
    public let name: String
    public let cols: Int
    public let rows: Int

    public init(id: String, agentID: String, name: String, cols: Int, rows: Int) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.cols = cols
        self.rows = rows
    }
}

/// Every live session the client currently holds, of both kinds — the full
/// inventory a reconnect must account for. See `ReconnectPlanner` for why
/// this is one combined type rather than two separate planner entry points.
public struct SessionInventory: Equatable, Sendable {
    public let ptySessions: [PTYSessionSnapshot]
    public let chatSessions: [ChatSessionSnapshot]

    public init(ptySessions: [PTYSessionSnapshot] = [], chatSessions: [ChatSessionSnapshot] = []) {
        self.ptySessions = ptySessions
        self.chatSessions = chatSessions
    }
}

/// One action to perform against the relay to bring a PTY session back to
/// life after a reconnect: re-send `connect` with its last-known size and
/// name so the agent re-points its output and resizes.
public struct PTYReconnectAction: Equatable, Sendable {
    public let sessionID: String
    public let agentID: String
    public let name: String
    public let cols: Int
    public let rows: Int

    public init(sessionID: String, agentID: String, name: String, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.name = name
        self.cols = cols
        self.rows = rows
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

/// The full set of actions to perform against the relay after a reconnect,
/// covering both session kinds.
public struct ReconnectPlan: Equatable, Sendable {
    public let ptyReconnects: [PTYReconnectAction]
    public let chatReattaches: [ChatReattachAction]

    public init(ptyReconnects: [PTYReconnectAction], chatReattaches: [ChatReattachAction]) {
        self.ptyReconnects = ptyReconnects
        self.chatReattaches = chatReattaches
    }
}

/// Decides what to re-send to the relay, for *every* session the client
/// currently holds — PTY and chat alike — when the WebSocket reconnects.
/// The relay drops every session belonging to a client as soon as that
/// client unregisters, so every live session, of either kind, needs its own
/// reconnect action; a planner that silently skips any of them leaves that
/// session stranded, unreachable from the client that owns it, until the
/// user notices and manually restarts it.
///
/// This takes the *whole* inventory — both session kinds — in one call,
/// rather than exposing one planning function per kind, on purpose: an
/// earlier version of this code had a separate `ChatReattachPlanner.plan`
/// that only ever saw chat sessions, so it was structurally incapable of
/// "forgetting" them — the bug it actually shipped with was in the *caller*
/// (`SessionManager.onConnect` iterating PTY `sessions` directly and never
/// calling into the chat planner at all), and no test of the chat-only
/// planner alone could ever have caught that, because the planner was never
/// the thing holding the omission. Folding both kinds into one inventory
/// and one plan makes "the caller forgot to route a session kind through
/// the planner" impossible by construction: there is only one call to make,
/// and its return value is checked, in the test below, to contain an action
/// for everything that went in.
public enum ReconnectPlanner {
    /// The plan for one agent's sessions only: its connection to the relay
    /// came back, and the relay dropped every route through the old one.
    public static func plan(inventory: SessionInventory, agentID: String) -> ReconnectPlan {
        plan(inventory: SessionInventory(
            ptySessions: inventory.ptySessions.filter { $0.agentID == agentID },
            chatSessions: inventory.chatSessions.filter { $0.agentID == agentID }
        ))
    }

    public static func plan(inventory: SessionInventory) -> ReconnectPlan {
        ReconnectPlan(
            ptyReconnects: inventory.ptySessions.map {
                PTYReconnectAction(sessionID: $0.id, agentID: $0.agentID, name: $0.name, cols: $0.cols, rows: $0.rows)
            },
            chatReattaches: inventory.chatSessions.map {
                ChatReattachAction(sessionID: $0.id, agentID: $0.agentID, cwd: $0.cwd, name: $0.name, afterSeq: $0.lastSeq)
            }
        )
    }
}
