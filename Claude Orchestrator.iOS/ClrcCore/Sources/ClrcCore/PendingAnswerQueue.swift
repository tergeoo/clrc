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
    /// How long a sent answer may wait for its turn to start before the
    /// user is told it did not get through (covers a cold `claude` spawn).
    public static let confirmWindow: TimeInterval = 20

    public private(set) var items: [PendingAnswer] = []
    /// Sent, waiting for the agent to start a turn (or report an error).
    public private(set) var awaiting: [SentAnswer] = []

    public init() {}

    /// Sessions whose card shows as working: held or sent but unconfirmed.
    public var sessionIDs: Set<String> { Set(items.map(\.sessionID) + awaiting.map(\.sessionID)) }

    /// Holds an answer; a newer answer for the same session replaces the older one.
    public mutating func enqueue(sessionID: String, agentID: String, text: String, now: Date) {
        items.removeAll { $0.sessionID == sessionID }
        awaiting.removeAll { $0.sessionID == sessionID }
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

    /// Records that `answer` went out while the session's progress seq was
    /// `afterSeq`; the card stays working until `confirm` sees progress.
    public mutating func markSent(_ answer: PendingAnswer, afterSeq: UInt64, now: Date) {
        awaiting.removeAll { $0.sessionID == answer.sessionID }
        awaiting.append(SentAnswer(sessionID: answer.sessionID, agentID: answer.agentID, text: answer.text,
                                   afterSeq: afterSeq, deadline: now.addingTimeInterval(Self.confirmWindow)))
    }

    /// Clears sent answers whose session moved past their `afterSeq`
    /// (`progress`: session id → `ChatTranscript.lastProgressSeq`).
    public mutating func confirm(progress: [String: UInt64]) {
        awaiting.removeAll { (progress[$0.sessionID] ?? 0) > $0.afterSeq }
    }

    /// Removes and returns sent answers that were never confirmed in time.
    public mutating func expire(now: Date) -> [SentAnswer] {
        let expired = awaiting.filter { $0.deadline <= now }
        awaiting.removeAll { $0.deadline <= now }
        return expired
    }
}

/// An answer that was sent and is waiting for the agent to take it up.
public struct SentAnswer: Sendable, Equatable {
    public let sessionID: String
    public let agentID: String
    public let text: String
    public let afterSeq: UInt64
    public let deadline: Date
}
