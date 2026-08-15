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
