import Foundation
import Testing
@testable import ClrcCore

@Suite("SessionsStore")
struct SessionsStoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clrc-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func session(_ id: String, agentID: String = "agent-1") -> PersistedSession {
        PersistedSession(id: id, agentID: agentID, agentName: "mac",
                         customName: "name-\(id)", projectPath: "/tmp/\(id)",
                         createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test("round-trips sessions across store instances")
    func persistence() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        store.upsert(session("b", agentID: "agent-2"))

        let reloaded = SessionsStore(directory: dir)
        #expect(reloaded.sessions.count == 2)
        #expect(reloaded.sessions(forAgent: "agent-1").map(\.id) == ["a"])
        #expect(reloaded.sessions(forAgent: "agent-2").map(\.id) == ["b"])
    }

    @Test("upsert replaces an existing entry")
    func upsertReplaces() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        var updated = session("a")
        updated.customName = "renamed"
        store.upsert(updated)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].customName == "renamed")
    }

    @Test("remove and rename persist")
    func removeAndRename() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        store.upsert(session("a"))
        store.upsert(session("b"))
        store.remove(id: "a")
        store.rename(id: "b", to: "fancy")

        let reloaded = SessionsStore(directory: dir)
        #expect(reloaded.sessions.map(\.id) == ["b"])
        #expect(reloaded.sessions[0].customName == "fancy")
    }

    @Test("recent projects: MRU order, dedupe, cap of 8")
    func recents() throws {
        let dir = try makeTempDir()
        let store = SessionsStore(directory: dir)
        for i in 1...10 {
            store.addRecentProject("/p/\(i)", agentID: "agent-1")
        }
        store.addRecentProject("/p/5", agentID: "agent-1") // re-use bumps to front

        let recents = store.recentProjects(forAgent: "agent-1")
        #expect(recents.count == 8)
        #expect(recents.first == "/p/5")
        #expect(!recents.contains("/p/1")) // evicted
        #expect(store.recentProjects(forAgent: "other").isEmpty)
    }

    @Test("corrupt store file starts empty instead of crashing")
    func corruptFile() throws {
        let dir = try makeTempDir()
        try Data("{broken json".utf8)
            .write(to: dir.appendingPathComponent("sessions-store.json"))
        let store = SessionsStore(directory: dir)
        #expect(store.sessions.isEmpty)
        store.upsert(session("a")) // and recovers by writing fresh state
        #expect(SessionsStore(directory: dir).sessions.count == 1)
    }
}
