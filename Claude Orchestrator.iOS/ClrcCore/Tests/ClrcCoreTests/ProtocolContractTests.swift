import Testing
import Foundation
@testable import ClrcCore

/// Golden messages shared with relay/ and agent/ (see protocol/README.md).
private func fixturePayload(_ name: String) throws -> [String: Any] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ClrcCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ClrcCore
        .deletingLastPathComponent() // Claude Orchestrator.iOS
        .deletingLastPathComponent()
    let url = repoRoot.appendingPathComponent("protocol/fixtures/\(name)")
    let data = try Data(contentsOf: url)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(json["payload"] as? [String: Any])
}

@Test func agentListFixtureDecodesEveryField() throws {
    let agents = AgentSummary.list(fromAgentListPayload: try fixturePayload("agent_list.json"))
    #expect(agents == [AgentSummary(id: "3f2b8c1e-9a4d-4e6f-8b7a-1c2d3e4f5a6b",
                                    name: "MacBook Pro", connected: true, version: "2.1.0")])
}

@Test func agentListWithoutVersionStillDecodes() {
    let agents = AgentSummary.list(fromAgentListPayload: [
        "agents": [["id": "a", "name": "Old Mac", "connected": true]],
    ])
    #expect(agents == [AgentSummary(id: "a", name: "Old Mac", connected: true, version: nil)])
}

@Test func agentListSkipsEntriesWithoutIdentity() {
    let agents = AgentSummary.list(fromAgentListPayload: [
        "agents": [["name": "no id"], ["id": "b"], ["id": "c", "name": "ok"]],
    ])
    #expect(agents.map(\.id) == ["c"])
}

@Test func sessionsListFixtureDecodesEveryField() throws {
    let payload = try fixturePayload("sessions_list.json")
    let raw = try #require(payload["sessions"] as? [[String: Any]])
    let info = try #require(raw.compactMap(RemoteSessionInfo.init(dict:)).first)
    #expect(info.id == "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f")
    #expect(info.cols == 120 && info.rows == 40)
    #expect(info.name == "clrc refactor")
    #expect(info.command == "claude")
    #expect(info.started == ISO8601DateFormatter().date(from: "2026-11-25T10:00:00Z"))
}

@Test(arguments: [
    (nil, true),            // agent older than 2.1 reports nothing
    ("", true),
    ("1.2.0", true),
    ("2.0.0", false),       // == minimumSupported
    ("2.1.0", false),
    ("10.0.0", false),      // numeric, not lexicographic
    ("2.0.0-5-gc23f7d5-dirty", false), // local `git describe` build
    ("dev", false),         // local build without tags: never nag
    ("garbage", false),
] as [(String?, Bool)])
func agentVersionOutdated(reported: String?, outdated: Bool) {
    #expect(AgentVersion.isOutdated(reported) == outdated)
}
