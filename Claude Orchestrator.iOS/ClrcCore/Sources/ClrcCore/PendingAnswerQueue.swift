import Foundation

/// An inbox answer waiting out its undo window before it is sent.
public struct PendingAnswer: Sendable, Equatable {
    public let sessionID: String
    public let agentID: String
    public let text: String
    public let dueAt: Date
}

/// Answers given from the inbox are held for `undoWindow` seconds so
/// «Отменить» can still stop them: a `chat_send` cannot be recalled. The
/// clock is passed in, so the queue is deterministic in tests.
public struct PendingAnswerQueue: Sendable, Equatable {
    public static let undoWindow: TimeInterval = 3

    public private(set) var items: [PendingAnswer] = []

    public init() {}

    public var sessionIDs: Set<String> { Set(items.map(\.sessionID)) }

    /// Holds an answer; a newer answer for the same session replaces the older one.
    public mutating func enqueue(sessionID: String, agentID: String, text: String, now: Date) {
        items.removeAll { $0.sessionID == sessionID }
        items.append(PendingAnswer(sessionID: sessionID, agentID: agentID, text: text,
                                   dueAt: now.addingTimeInterval(Self.undoWindow)))
    }

    @discardableResult
    public mutating func cancel(sessionID: String) -> PendingAnswer? {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return items.remove(at: index)
    }

    /// Takes out every answer that is due: those whose Mac is online go to
    /// `send`, the rest to `dropped` so the user is told they were not sent.
    public mutating func drain(now: Date, onlineAgentIDs: Set<String>) -> (send: [PendingAnswer], dropped: [PendingAnswer]) {
        let due = items.filter { $0.dueAt <= now }
        items.removeAll { $0.dueAt <= now }
        let send = due.filter { onlineAgentIDs.contains($0.agentID) }
        let dropped = due.filter { !onlineAgentIDs.contains($0.agentID) }
        return (send, dropped)
    }
}
