import Foundation
import Testing
@testable import ClrcCore

@Suite("Chat session persistence and per-agent reattach")
struct ChatPersistenceTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clrc-chat-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("entries saved before chat persistence decode as terminal sessions")
    func legacyEntryIsTerminal() throws {
        let json = #"{"id":"a","agentID":"m","agentName":"mac","customName":"x","createdAt":0}"#
        let entry = try JSONDecoder().decode(PersistedSession.self, from: Data(json.utf8))
        #expect(entry.kind == .pty)
        #expect(entry.cwd == nil)
    }

    @Test("chat sessions round-trip with their cwd and stay out of the PTY list")
    func chatRoundTrip() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(PersistedSession(id: "t", agentID: "m", agentName: "mac", customName: "term"))
        store.upsert(PersistedSession(id: "c", agentID: "m", agentName: "mac", customName: "api",
                                      kind: .chat, cwd: "/Users/me/api"))
        store.upsert(PersistedSession(id: "o", agentID: "other", agentName: "mac2", customName: "x",
                                      kind: .chat, cwd: "~"))

        let reloaded = SessionsStore(directory: dir)
        #expect(reloaded.ptySessions(forAgent: "m").map(\.id) == ["t"])
        let chats = reloaded.chatSessions(forAgent: "m")
        #expect(chats.map(\.id) == ["c"])
        #expect(chats.first?.cwd == "/Users/me/api")
        #expect(chats.first?.kind == .chat)
    }

    @Test("an agent's return replans only that agent's sessions, of both kinds")
    func planForOneAgent() {
        let inventory = SessionInventory(
            ptySessions: [
                PTYSessionSnapshot(id: "p1", agentID: "m", name: "t", cols: 80, rows: 24),
                PTYSessionSnapshot(id: "p2", agentID: "other", name: "t", cols: 80, rows: 24),
            ],
            chatSessions: [
                ChatSessionSnapshot(id: "c1", agentID: "m", cwd: "/tmp", name: "c", lastSeq: 7),
                ChatSessionSnapshot(id: "c2", agentID: "other", cwd: "/tmp", name: "c", lastSeq: 1),
            ]
        )
        let plan = ReconnectPlanner.plan(inventory: inventory, agentID: "m")
        #expect(plan.ptyReconnects.map(\.sessionID) == ["p1"])
        #expect(plan.chatReattaches.map(\.sessionID) == ["c1"])
        #expect(plan.chatReattaches.first?.afterSeq == 7)
    }
}
