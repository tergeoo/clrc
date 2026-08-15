import Testing
@testable import ClrcCore

private func event(_ kind: ChatEventKind, _ seq: UInt64, message: String = "",
                   stopReason: String = "") -> ChatEvent {
    ChatEvent(kind: kind, seq: seq, ts: "t", stopReason: stopReason, message: message)
}

@Suite("ChatStateDeriver")
struct ChatStateDeriverTests {

    @Test("turn_start sets isWorking true")
    func turnStartStartsWorking() {
        let state = ChatStateDeriver.deriving([event(.turnStart, 1)], from: ChatSessionState())
        #expect(state.isWorking)
    }

    // C2 regression: the agent's fix for Interrupt is a synthetic turn_end
    // carrying stop_reason "interrupted". A deriver that only recognises a
    // normal completion (e.g. by checking stopReason.isEmpty, or matching a
    // specific stop reason string) fails this test and leaves the composer
    // permanently locked after Stop.
    @Test("turn_end with stop_reason interrupted clears isWorking")
    func interruptedTurnEndClearsWorking() {
        let start = ChatSessionState(isWorking: true, lastError: nil)
        let state = ChatStateDeriver.deriving(
            [event(.turnEnd, 2, stopReason: "interrupted")],
            from: start
        )
        #expect(!state.isWorking)
    }

    @Test("turn_end with normal completion also clears isWorking")
    func normalTurnEndClearsWorking() {
        let start = ChatSessionState(isWorking: true, lastError: nil)
        let state = ChatStateDeriver.deriving([event(.turnEnd, 2)], from: start)
        #expect(!state.isWorking)
    }

    // A replay batch that starts a turn but has not yet reached its
    // turn_end (Claude is still mid-turn at the moment the replay was
    // requested) must leave the spinner on — the last kind seen wins.
    @Test("batch with turn_start and no turn_end leaves isWorking true")
    func openTurnLeavesWorkingTrue() {
        let state = ChatStateDeriver.deriving(
            [event(.turnStart, 1), event(.text, 2)],
            from: ChatSessionState()
        )
        #expect(state.isWorking)
    }

    @Test("user_text does not change isWorking or lastError")
    func userTextIsInert() {
        let start = ChatSessionState(isWorking: true, lastError: "boom")
        let state = ChatStateDeriver.deriving([event(.userText, 5)], from: start)
        #expect(state.isWorking)
        #expect(state.lastError == "boom")
    }

    @Test("plain text does not change isWorking or lastError")
    func textIsInert() {
        let start = ChatSessionState(isWorking: true, lastError: "boom")
        let state = ChatStateDeriver.deriving([event(.text, 5)], from: start)
        #expect(state.isWorking)
        #expect(state.lastError == "boom")
    }

    @Test("error sets lastError")
    func errorSetsLastError() {
        let state = ChatStateDeriver.deriving([event(.error, 1, message: "process exited 1")], from: ChatSessionState())
        #expect(state.lastError == "process exited 1")
    }

    // M5 regression: without this, the red banner is sticky for the whole
    // session's life once any error has occurred.
    @Test("turn_start clears a previous lastError")
    func turnStartClearsPreviousError() {
        let start = ChatSessionState(isWorking: false, lastError: "stale error")
        let state = ChatStateDeriver.deriving([event(.turnStart, 3)], from: start)
        #expect(state.lastError == nil)
    }

    @Test("events are folded in seq order regardless of input order")
    func foldsInSeqOrder() {
        // turn_end (seq 2) then turn_start (seq 3) passed in reverse order —
        // must still land as "turn ended, then a new one started" (working).
        let state = ChatStateDeriver.deriving(
            [event(.turnStart, 3), event(.turnEnd, 2)],
            from: ChatSessionState(isWorking: true, lastError: nil)
        )
        #expect(state.isWorking)
    }
}
