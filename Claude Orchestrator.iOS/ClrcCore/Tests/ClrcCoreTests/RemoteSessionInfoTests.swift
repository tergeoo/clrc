import Foundation
import Testing
@testable import ClrcCore

@Suite("RemoteSessionInfo")
struct RemoteSessionInfoTests {

    @Test("parses a full agent entry")
    func fullEntry() {
        let dict: [String: Any] = [
            "id": "abc", "cols": 100, "rows": 30,
            "name": "drops.iOS", "command": "claude",
            "started": "2026-07-04T10:30:00Z",
        ]
        let info = RemoteSessionInfo(dict: dict)
        #expect(info?.id == "abc")
        #expect(info?.cols == 100)
        #expect(info?.rows == 30)
        #expect(info?.name == "drops.iOS")
        #expect(info?.command == "claude")
        #expect(info?.started == ISO8601DateFormatter().date(from: "2026-07-04T10:30:00Z"))
    }

    @Test("parses a legacy entry without metadata")
    func legacyEntry() {
        let info = RemoteSessionInfo(dict: ["id": "abc", "cols": 80, "rows": 24])
        #expect(info?.name == nil)
        #expect(info?.command == nil)
        #expect(info?.started == nil)
    }

    @Test("empty name is normalized to nil")
    func emptyName() {
        let info = RemoteSessionInfo(dict: ["id": "abc", "cols": 80, "rows": 24, "name": ""])
        #expect(info?.name == nil)
    }

    @Test("missing id → nil")
    func missingID() {
        #expect(RemoteSessionInfo(dict: ["cols": 80]) == nil)
        #expect(RemoteSessionInfo(dict: ["id": "", "cols": 80]) == nil)
    }
}
