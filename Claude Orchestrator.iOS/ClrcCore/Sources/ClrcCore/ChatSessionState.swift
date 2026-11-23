/// Derived UI state for a chat session: whether the composer should show a
/// stop button (`isWorking`) and the sticky error banner text, if any.
public struct ChatSessionState: Equatable, Sendable {
    public let isWorking: Bool
    public let lastError: String?

    public init(isWorking: Bool = false, lastError: String? = nil) {
        self.isWorking = isWorking
        self.lastError = lastError
    }
}

/// Pure derivation of `ChatSessionState` from a batch of events, folded onto
/// a starting state. Used identically on the live path (one event at a
/// time) and the replay path (a whole batch at once) — a `turn_end` that
/// only ever arrives via replay must still clear `isWorking`, so both paths
/// route through this one function.
public enum ChatStateDeriver {
    /// Folds `events` (sorted by `seq`, independent of input order — replay
    /// batches are not guaranteed to arrive pre-sorted) onto `state`.
    ///
    /// - `turnStart` sets `isWorking = true` and clears `lastError` (M5: a
    ///   new turn starting is the signal that the previous error is stale).
    /// - `turnEnd` sets `isWorking = false`, regardless of `stopReason` —
    ///   this is what makes the synthetic `turn_end` the agent publishes
    ///   after an interrupt (`stop_reason: "interrupted"`) unlock the
    ///   composer exactly like a normal completion.
    /// - `error` replaces `lastError` with the event's message.
    /// - every other kind (`text`, `userText`, `toolUse`, `toolResult`,
    ///   `report`, `unknown`) leaves both fields untouched.
    public static func deriving(_ events: [ChatEvent], from state: ChatSessionState) -> ChatSessionState {
        var isWorking = state.isWorking
        var lastError = state.lastError

        for event in events.sorted(by: { $0.seq < $1.seq }) {
            switch event.kind {
            case .turnStart:
                isWorking = true
                lastError = nil
            case .turnEnd:
                isWorking = false
            case .error:
                lastError = event.message
            case .text, .userText, .toolUse, .toolResult, .report, .unknown:
                break
            }
        }

        return ChatSessionState(isWorking: isWorking, lastError: lastError)
    }
}
