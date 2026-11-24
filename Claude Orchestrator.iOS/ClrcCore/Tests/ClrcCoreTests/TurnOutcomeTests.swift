import Testing
@testable import ClrcCore

private func ev(_ kind: ChatEventKind, _ seq: UInt64, text: String = "", message: String = "",
                stop: String = "", cost: Double = 0, ms: Int = 0) -> ChatEvent {
    ChatEvent(kind: kind, seq: seq, ts: "", text: text, costUSD: cost, durationMS: ms, stopReason: stop, message: message)
}

@Test func interruptedTurn() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.turnEnd, 2, stop: "interrupted")])
    #expect(turn.wasInterrupted)
    #expect(turn.errorMessage == nil)
    #expect(turn.endEvent?.seq == 2)
}

@Test func errorTurn() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.error, 2, message: "a"), ev(.error, 3, message: "b")])
    #expect(turn.errorMessage == "b")
    #expect(!turn.wasInterrupted)
    #expect(turn.endEvent == nil)
}

@Test func assistantTextJoinsTextEvents() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.text, 2, text: "one"),
                                        ChatEvent(kind: .toolUse, seq: 3, ts: "", name: "Read"),
                                        ev(.text, 4, text: "two")])
    #expect(turn.assistantText == "one\n\ntwo")
    #expect(turn.toolEvents.map(\.seq) == [3])
}

@Test func retryTextIsLastUserMessage() {
    let transcript = ChatTranscript().applying([
        ev(.turnStart, 1), ev(.userText, 2, text: "a"),
        ev(.turnStart, 3), ev(.userText, 4, text: "b"), ev(.error, 5, message: "x"),
    ])
    #expect(transcript.lastUserText == "b")
    #expect(ChatTranscript().lastUserText == nil)
}

@Test func costText() {
    #expect(turnCostText(costUSD: 0.42, durationMS: 72_000) == "$0.42 · 1 мин 12 с")
    #expect(turnCostText(costUSD: 0.0123, durationMS: 8_000) == "$0.01 · 8 с")
    #expect(turnCostText(costUSD: 0, durationMS: 8_000) == "8 с")
    #expect(turnCostText(costUSD: 0.42, durationMS: 0) == "$0.42")
    #expect(turnCostText(costUSD: 0, durationMS: 0) == nil)
    #expect(turnCostText(costUSD: 0, durationMS: 120_000) == "2 мин")
}

@Test func turnIsAnsweredOnceUserTextFollowsReport() {
    let report = ChatEvent(kind: .report, seq: 3, ts: "", report: TurnReport(status: .needsInput, questions: ["a"]))
    let open = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.text, 2, text: "?"), report, ev(.turnEnd, 4)])
    #expect(!open.isAnswered)
    let answered = ChatTurn(id: 1, events: open.events + [ev(.userText, 5, text: "1")])
    #expect(answered.isAnswered)
    #expect(!ChatTurn(id: 1, events: [ev(.userText, 1, text: "hi")]).isAnswered)
}

// MARK: - Review fixes: which errors fail a turn, what «Повторить» resends

private func report(_ seq: UInt64, _ status: TurnReportStatus) -> ChatEvent {
    ChatEvent(kind: .report, seq: seq, ts: "", report: TurnReport(status: status))
}

@Test func stderrNoiseAfterSuccessfulTurnIsANoteNotAFailure() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), report(2, .done), ev(.turnEnd, 3),
                                        ev(.error, 4, message: "mcp warning")])
    #expect(turn.failureMessage == nil)
    #expect(turn.noteErrors.map(\.message) == ["mcp warning"])
}

@Test func errorBeforeTurnEndWithoutReportFailsTheTurn() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.error, 2, message: "boom"), ev(.turnEnd, 3, stop: "error")])
    #expect(turn.failureMessage == "boom")
    #expect(turn.noteErrors.isEmpty)
}

@Test func errorWithoutTurnEndFailsTheTurn() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.error, 2, message: "claude exited")])
    #expect(turn.failureMessage == "claude exited")
}

@Test func interruptWinsOverErrors() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), ev(.error, 2, message: "signal"), ev(.turnEnd, 3, stop: "interrupted")])
    #expect(turn.failureMessage == nil)
    #expect(turn.wasInterrupted)
}

@Test func failedReportKeepsTheFailure() {
    let turn = ChatTurn(id: 1, events: [ev(.turnStart, 1), report(2, .failed), ev(.error, 3, message: "x"), ev(.turnEnd, 4)])
    #expect(turn.failureMessage == "x")
}

@Test func retryTextIsTheMessageThatFailed() {
    let t = ChatTranscript().applying([ev(.userText, 1, text: "go"), ev(.turnStart, 2), ev(.error, 3, message: "x")])
    #expect(t.retryText(beforeErrorSeq: 3) == "go")
}

@Test func retryHiddenWhenTheLastMessageAlreadyCompleted() {
    // Turn finished, then the next message failed to start (no user_text echo).
    let t = ChatTranscript().applying([ev(.userText, 1, text: "commit"), ev(.turnStart, 2), report(3, .done),
                                       ev(.turnEnd, 4), ev(.error, 5, message: "could not start claude")])
    #expect(t.retryText(beforeErrorSeq: 5) == nil)
}

@Test func retryNilWithoutAnyMessage() {
    let t = ChatTranscript().applying([ev(.error, 1, message: "x")])
    #expect(t.retryText(beforeErrorSeq: 1) == nil)
}
