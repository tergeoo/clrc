import Testing
@testable import ClrcCore

private func event(_ kind: ChatEventKind, _ seq: UInt64, text: String = "") -> ChatEvent {
    ChatEvent(kind: kind, seq: seq, ts: "t", text: text)
}

@Test("Applying events advances lastSeq")
func advancesLastSeq() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 2, text: "hi")])
    #expect(transcript.lastSeq == 2)
}

@Test("Duplicate seq is ignored")
func ignoresDuplicates() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 2, text: "hi")])
        .applying([event(.text, 2, text: "hi")])
    #expect(transcript.lastSeq == 2)
    #expect(transcript.turns.first?.events.count == 2)
}

@Test("Out-of-order arrival does not rewind lastSeq")
func ignoresStaleEvents() {
    let transcript = ChatTranscript()
        .applying([event(.turnStart, 1), event(.text, 5, text: "late")])
        .applying([event(.text, 3, text: "stale")])
    #expect(transcript.lastSeq == 5)
}

@Test("A gap is detectable so the client can request replay")
func detectsGap() {
    let transcript = ChatTranscript().applying([event(.turnStart, 1)])
    #expect(transcript.hasGap(before: 5))
    #expect(!transcript.hasGap(before: 2))
}

@Test("turn_start opens a new turn")
func groupsIntoTurns() {
    let transcript = ChatTranscript().applying([
        event(.turnStart, 1), event(.text, 2, text: "a"), event(.turnEnd, 3),
        event(.turnStart, 4), event(.text, 5, text: "b"),
    ])
    #expect(transcript.turns.count == 2)
    #expect(transcript.turns[1].events.contains { $0.text == "b" })
}

@Test("Events before any turn_start still land in a turn")
func toleratesMissingTurnStart() {
    let transcript = ChatTranscript().applying([event(.text, 1, text: "orphan")])
    #expect(transcript.turns.count == 1)
    #expect(transcript.turns[0].events.count == 1)
}

// Defect 3 regression: an agent restart resets the in-memory seq counter to
// 1. A reattached client holding a stale, higher lastSeq must detect that
// from the reply's next_seq coming back lower than its own lastSeq — not
// treat it as just another caught-up reply — or the tab freezes forever
// with every future event silently dropped as "already seen".

@Test("A next_seq lower than lastSeq signals a buffer reset")
func detectsBufferReset() {
    let transcript = ChatTranscript().applying([event(.turnStart, 1), event(.text, 50, text: "x")])
    #expect(transcript.lastSeq == 50)
    #expect(transcript.isBehindBufferReset(replyNextSeq: 2))
    #expect(transcript.isBehindBufferReset(replyNextSeq: 0))
}

@Test("A next_seq at or ahead of lastSeq is not a reset")
func doesNotFalselyDetectResetWhenCaughtUpOrAhead() {
    let transcript = ChatTranscript().applying([event(.turnStart, 1), event(.text, 50, text: "x")])
    #expect(!transcript.isBehindBufferReset(replyNextSeq: 50)) // exactly caught up
    #expect(!transcript.isBehindBufferReset(replyNextSeq: 51)) // new events arrived normally
}

@Test("A fresh transcript is never seen as behind a reset")
func freshTranscriptNeverLooksReset() {
    let transcript = ChatTranscript()
    #expect(!transcript.isBehindBufferReset(replyNextSeq: 0))
    #expect(!transcript.isBehindBufferReset(replyNextSeq: 5))
}

@Test func progressSeqTracksTurnStartsAndErrorsOnly() {
    let transcript = ChatTranscript().applying([
        ChatEvent(kind: .turnStart, seq: 1, ts: ""),
        ChatEvent(kind: .text, seq: 2, ts: ""),
        ChatEvent(kind: .turnEnd, seq: 3, ts: ""),
        ChatEvent(kind: .userText, seq: 4, ts: ""),
    ])
    #expect(transcript.lastProgressSeq == 1)
    let failed = transcript.applying([ChatEvent(kind: .error, seq: 5, ts: "", message: "x")])
    #expect(failed.lastProgressSeq == 5)
    #expect(ChatTranscript().lastProgressSeq == 0)
}
