import Testing
@testable import ClrcCore

private func chatSnapshot(_ id: String, agentID: String = "agent-1", cwd: String = "/tmp",
                          name: String = "chat", lastSeq: UInt64 = 0) -> ChatSessionSnapshot {
    ChatSessionSnapshot(id: id, agentID: agentID, cwd: cwd, name: name, lastSeq: lastSeq)
}

private func ptySnapshot(_ id: String, agentID: String = "agent-1", name: String = "term",
                         cols: Int = 80, rows: Int = 24) -> PTYSessionSnapshot {
    PTYSessionSnapshot(id: id, agentID: agentID, name: name, cols: cols, rows: rows)
}

@Suite("ReconnectPlanner")
struct ReconnectPlannerTests {

    // The original C1 bug: `SessionManager.onConnect` iterated PTY sessions
    // directly and never routed chat sessions through any planner at all.
    // `ChatReattachPlanner.plan` alone could never have caught that — every
    // input it was ever given was already all-chat, so it had no way to
    // "forget" a kind. Taking the *whole* inventory in one call and
    // asserting the plan covers both kinds is what makes "silently skip a
    // session kind" a fact this test can observe: a planner that special-
    // cases PTY sessions and returns `chatReattaches: []` regardless of
    // `inventory.chatSessions` fails this test outright.
    @Test("every session in the inventory gets exactly one action, of both kinds")
    func oneActionPerSessionBothKinds() {
        let inventory = SessionInventory(
            ptySessions: [ptySnapshot("p1"), ptySnapshot("p2")],
            chatSessions: [chatSnapshot("c1"), chatSnapshot("c2"), chatSnapshot("c3")]
        )
        let plan = ReconnectPlanner.plan(inventory: inventory)

        #expect(plan.ptyReconnects.count == 2)
        #expect(Set(plan.ptyReconnects.map(\.sessionID)) == ["p1", "p2"])

        #expect(plan.chatReattaches.count == 3)
        #expect(Set(plan.chatReattaches.map(\.sessionID)) == ["c1", "c2", "c3"])
    }

    @Test("chat sessions alone still produce chat actions, with no PTY sessions present")
    func chatOnlyInventory() {
        let inventory = SessionInventory(chatSessions: [chatSnapshot("a"), chatSnapshot("b")])
        let plan = ReconnectPlanner.plan(inventory: inventory)
        #expect(plan.ptyReconnects.isEmpty)
        #expect(plan.chatReattaches.count == 2)
    }

    @Test("PTY sessions alone still produce PTY actions, with no chat sessions present")
    func ptyOnlyInventory() {
        let inventory = SessionInventory(ptySessions: [ptySnapshot("a"), ptySnapshot("b")])
        let plan = ReconnectPlanner.plan(inventory: inventory)
        #expect(plan.ptyReconnects.count == 2)
        #expect(plan.chatReattaches.isEmpty)
    }

    // The explicit history request is what recovers a turn that finished
    // while the client was disconnected — it must resume from *that*
    // session's own last-known seq, not seq 0 or some shared value, or a
    // reattach after a long-lived session would re-fetch its entire history
    // (or, worse, a bug that hardcodes 0 would look correct only for a
    // freshly created session in tests).
    @Test("each chat action carries its own session's lastSeq, not a shared value")
    func chatActionCarriesOwnLastSeq() {
        let inventory = SessionInventory(chatSessions: [
            chatSnapshot("a", lastSeq: 42),
            chatSnapshot("b", lastSeq: 7),
            chatSnapshot("c", lastSeq: 0),
        ])
        let actions = ReconnectPlanner.plan(inventory: inventory).chatReattaches
        let bySessionID = Dictionary(uniqueKeysWithValues: actions.map { ($0.sessionID, $0) })
        #expect(bySessionID["a"]?.afterSeq == 42)
        #expect(bySessionID["b"]?.afterSeq == 7)
        #expect(bySessionID["c"]?.afterSeq == 0)
    }

    @Test("each PTY action carries its own session's size, not a shared value")
    func ptyActionCarriesOwnSize() {
        let inventory = SessionInventory(ptySessions: [
            ptySnapshot("a", cols: 100, rows: 40),
            ptySnapshot("b", cols: 80, rows: 24),
        ])
        let actions = ReconnectPlanner.plan(inventory: inventory).ptyReconnects
        let bySessionID = Dictionary(uniqueKeysWithValues: actions.map { ($0.sessionID, $0) })
        #expect(bySessionID["a"]?.cols == 100 && bySessionID["a"]?.rows == 40)
        #expect(bySessionID["b"]?.cols == 80 && bySessionID["b"]?.rows == 24)
    }

    @Test("carries chat identity — agentID, cwd and name — through unchanged")
    func chatActionCarriesIdentity() {
        let inventory = SessionInventory(chatSessions: [
            chatSnapshot("a", agentID: "mac-mini", cwd: "/Users/g/project", name: "My Chat"),
        ])
        let action = ReconnectPlanner.plan(inventory: inventory).chatReattaches.first
        #expect(action?.agentID == "mac-mini")
        #expect(action?.cwd == "/Users/g/project")
        #expect(action?.name == "My Chat")
    }

    @Test("carries PTY identity — agentID and name — through unchanged")
    func ptyActionCarriesIdentity() {
        let inventory = SessionInventory(ptySessions: [
            ptySnapshot("a", agentID: "mac-mini", name: "My Terminal"),
        ])
        let action = ReconnectPlanner.plan(inventory: inventory).ptyReconnects.first
        #expect(action?.agentID == "mac-mini")
        #expect(action?.name == "My Terminal")
    }

    @Test("empty inventory → empty plan")
    func emptyInput() {
        let plan = ReconnectPlanner.plan(inventory: SessionInventory())
        #expect(plan.ptyReconnects.isEmpty)
        #expect(plan.chatReattaches.isEmpty)
    }
}
