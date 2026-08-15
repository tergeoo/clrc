import Testing
@testable import ClrcCore

private func snapshot(_ id: String, agentID: String = "agent-1", cwd: String = "/tmp",
                      name: String = "chat", lastSeq: UInt64 = 0) -> ChatSessionSnapshot {
    ChatSessionSnapshot(id: id, agentID: agentID, cwd: cwd, name: name, lastSeq: lastSeq)
}

@Suite("ChatReattachPlanner")
struct ChatReattachPlannerTests {

    // C1 regression: a planner that returns nothing for chat sessions (the
    // original bug — `onConnect` only iterated PTY `sessions`) must fail
    // this test. Every chat session needs its own reattach action, with no
    // exceptions, because the relay drops all of a client's sessions on
    // unregister.
    @Test("every chat session gets exactly one reattach action")
    func oneActionPerSession() {
        let sessions = [snapshot("a"), snapshot("b"), snapshot("c")]
        let actions = ChatReattachPlanner.plan(chatSessions: sessions)
        #expect(actions.count == 3)
        #expect(Set(actions.map(\.sessionID)) == ["a", "b", "c"])
    }

    // The explicit history request is what recovers a turn that finished
    // while the client was disconnected — it must resume from *that*
    // session's own last-known seq, not seq 0 or some shared value, or a
    // reattach after a long-lived session would re-fetch its entire history
    // (or, worse, a bug that hardcodes 0 would look correct only for a
    // freshly created session in tests).
    @Test("each action carries its own session's lastSeq, not a shared value")
    func carriesOwnLastSeq() {
        let sessions = [
            snapshot("a", lastSeq: 42),
            snapshot("b", lastSeq: 7),
            snapshot("c", lastSeq: 0),
        ]
        let actions = ChatReattachPlanner.plan(chatSessions: sessions)
        let bySessionID = Dictionary(uniqueKeysWithValues: actions.map { ($0.sessionID, $0) })
        #expect(bySessionID["a"]?.afterSeq == 42)
        #expect(bySessionID["b"]?.afterSeq == 7)
        #expect(bySessionID["c"]?.afterSeq == 0)
    }

    @Test("carries agentID, cwd and name through unchanged")
    func carriesIdentity() {
        let sessions = [snapshot("a", agentID: "mac-mini", cwd: "/Users/g/project", name: "My Chat")]
        let action = ChatReattachPlanner.plan(chatSessions: sessions).first
        #expect(action?.agentID == "mac-mini")
        #expect(action?.cwd == "/Users/g/project")
        #expect(action?.name == "My Chat")
    }

    @Test("no chat sessions → no actions")
    func emptyInput() {
        #expect(ChatReattachPlanner.plan(chatSessions: []).isEmpty)
    }
}
