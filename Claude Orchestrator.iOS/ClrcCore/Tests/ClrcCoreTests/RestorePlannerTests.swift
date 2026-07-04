import Foundation
import Testing
@testable import ClrcCore

@Suite("RestorePlanner")
struct RestorePlannerTests {

    private func session(_ id: String) -> PersistedSession {
        PersistedSession(id: id, agentID: "agent-1", agentName: "mac",
                         customName: "s-\(id)", projectPath: nil, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("splits persisted sessions into alive and tombstones")
    func splitAliveDead() {
        let persisted = [session("a"), session("b"), session("c")]
        let plan = RestorePlanner.plan(persisted: persisted, liveSessionIDs: ["a", "c", "unrelated"])
        #expect(plan.toAttach.map(\.id) == ["a", "c"])
        #expect(plan.tombstones.map(\.id) == ["b"])
    }

    @Test("no live sessions → everything tombstoned")
    func allDead() {
        let plan = RestorePlanner.plan(persisted: [session("a")], liveSessionIDs: [])
        #expect(plan.toAttach.isEmpty)
        #expect(plan.tombstones.map(\.id) == ["a"])
    }

    @Test("nothing persisted → empty plan")
    func emptyInput() {
        let plan = RestorePlanner.plan(persisted: [], liveSessionIDs: ["x"])
        #expect(plan.toAttach.isEmpty && plan.tombstones.isEmpty)
    }
}
