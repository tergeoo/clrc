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
