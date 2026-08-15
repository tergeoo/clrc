import Foundation
import Combine
import ClrcCore

/// Manages creation, persistence, restore and lifecycle of terminal sessions.
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var chatSessions: [ChatSession] = []
    /// Persisted sessions whose PTY is gone — shown as "Ended" with a restart option.
    @Published var tombstones: [PersistedSession] = []

    private let relay: RelayWebSocket
    private let store: SessionsStore
    private var sessionCounter = 0
    private var cancellables = Set<AnyCancellable>()
    /// IDs of agents currently known to be online — detects new arrivals vs list refreshes.
    private var knownAgentIDs = Set<String>()

    static func defaultStore() -> SessionsStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clrc", isDirectory: true)
        return SessionsStore(directory: dir)
    }

    init(relay: RelayWebSocket, store: SessionsStore) {
        self.relay = relay
        self.store = store

        // Reconcile persisted sessions whenever an agent (re)appears.
        relay.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                guard let self else { return }
                let connectedIDs = Set(agents.filter { $0.connected }.map { $0.id })
                let newIDs = connectedIDs.subtracting(self.knownAgentIDs)
                self.knownAgentIDs = connectedIDs
                for agent in agents where newIDs.contains(agent.id) {
                    self.reconcile(agent)
                }
            }
            .store(in: &cancellables)

        relay.onSessionReady = { [weak self] sessionID in
            guard let self else { return }
            if let session = self.sessions.first(where: { $0.id == sessionID }) {
                guard !session.isReady else { return } // already sent initialCommand, skip on reconnect
                session.isReady = true
                if let cmd = session.initialCommand {
                    self.relay.sendInput(sessionID: sessionID, data: Data((cmd + "\n").utf8))
                }
            }
        }

        // After every reconnect, re-register all live sessions with the relay.
        relay.onConnect = { [weak self] in
            guard let self else { return }
            // Force a fresh reconcile pass when the agent list arrives after reconnect
            self.knownAgentIDs.removeAll()
            for session in self.sessions {
                self.relay.sendConnect(
                    agentID: session.agent.id,
                    sessionID: session.id,
                    cols: session.lastCols,
                    rows: session.lastRows,
                    name: session.customName
                )
            }
        }
    }

    // MARK: - Restore

    /// Match persisted sessions against the agent's live PTYs:
    /// reattach the alive ones, tombstone the dead ones,
    /// auto-create a first tab only when there is nothing to restore.
    private func reconcile(_ agent: Agent) {
        let alreadyLive = Set(sessions.map(\.id))
        let persisted = store.sessions(forAgent: agent.id).filter { !alreadyLive.contains($0.id) }

        guard !persisted.isEmpty else {
            autoCreateIfEmpty(for: agent)
            return
        }

        relay.requestSessionList(agentID: agent.id) { [weak self] remote in
            guard let self else { return }
            guard let remote else {
                // Timeout — unknown state. Keep persisted entries, retry on next arrival.
                return
            }
            let plan = RestorePlanner.plan(
                persisted: persisted,
                liveSessionIDs: Set(remote.map(\.id))
            )
            for entry in plan.toAttach {
                self.attachSession(
                    agentID: entry.agentID,
                    sessionID: entry.id,
                    agentName: entry.agentName,
                    customName: entry.customName
                )
            }
            let known = Set(self.tombstones.map(\.id))
            self.tombstones += plan.tombstones.filter { !known.contains($0.id) }
            self.autoCreateIfEmpty(for: agent)
        }
    }

    private func autoCreateIfEmpty(for agent: Agent) {
        let hasAny = sessions.contains { $0.agent.id == agent.id }
            || !tombstones.filter { $0.agentID == agent.id }.isEmpty
        if !hasAny {
            createSession(for: agent)
        }
    }

    // MARK: - Create / attach

    func createSession(for agent: Agent, initialCommand: String? = nil) {
        sessionCounter += 1
        let name = SessionNaming.autoName(for: initialCommand, index: sessionCounter)
        let session = TerminalSession(agent: agent, customName: name, initialCommand: initialCommand)
        sessions.append(session)

        let projectPath = SessionNaming.projectPath(from: initialCommand)
        store.upsert(PersistedSession(
            id: session.id,
            agentID: agent.id,
            agentName: agent.name,
            customName: name,
            projectPath: projectPath
        ))
        if let projectPath {
            store.addRecentProject(projectPath, agentID: agent.id)
        }
        relay.sendConnect(agentID: agent.id, sessionID: session.id, cols: 80, rows: 24, name: name)
    }

    func createChatSession(for agent: Agent, cwd: String, name: String) {
        let session = ChatSession(agent: agent, cwd: cwd, customName: name)
        chatSessions.append(session)

        relay.registerChatHandler(sessionID: session.id) { [weak self, weak session] event in
            Task { @MainActor in
                guard let self, let session else { return }
                guard session.receive(event) else { return }
                guard !session.isReplaying else { return } // a replay for this gap is already in flight
                session.isReplaying = true
                self.relay.requestChatHistory(
                    agentID: session.agent.id,
                    sessionID: session.id,
                    afterSeq: session.transcript.lastSeq
                ) { events, _ in
                    Task { @MainActor in
                        session.apply(history: events)
                        session.isReplaying = false
                    }
                }
            }
        }

        relay.sendChatConnect(agentID: agent.id, sessionID: session.id,
                              cwd: cwd, name: name)
    }

    func closeChat(_ session: ChatSession) {
        relay.unregisterChatHandler(sessionID: session.id)
        relay.sendDisconnect(sessionID: session.id)
        chatSessions.removeAll { $0.id == session.id }
    }

    /// Attach to an existing PTY session on the agent (session_id already known).
    func attachSession(agentID: String, sessionID: String, agentName: String, customName: String? = nil) {
        guard !sessions.contains(where: { $0.id == sessionID }) else { return }
        sessionCounter += 1
        let name = customName ?? "Session \(sessionCounter)"
        let session = TerminalSession(
            agentID: agentID,
            agentName: agentName,
            sessionID: sessionID,
            customName: name
        )
        sessions.append(session)
        tombstones.removeAll { $0.id == sessionID }

        // Preserve an existing store entry's projectPath if we have one.
        let existing = store.sessions.first { $0.id == sessionID }
        store.upsert(PersistedSession(
            id: sessionID,
            agentID: agentID,
            agentName: agentName,
            customName: name,
            projectPath: existing?.projectPath,
            createdAt: existing?.createdAt ?? Date()
        ))
        relay.sendConnect(agentID: agentID, sessionID: sessionID, cols: 80, rows: 24, name: name)
    }

    // MARK: - Rename / close

    func rename(_ session: TerminalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.customName = trimmed
        store.rename(id: session.id, to: trimmed)
        // Re-connect is a reattach on the agent side: it re-points output and stores the new name.
        relay.sendConnect(
            agentID: session.agent.id,
            sessionID: session.id,
            cols: session.lastCols,
            rows: session.lastRows,
            name: trimmed
        )
    }

    /// Explicitly close a session: kills the PTY on the Mac and forgets it.
    func close(_ session: TerminalSession) {
        relay.sendDisconnect(sessionID: session.id)
        relay.unregisterSessionHandler(sessionID: session.id)
        store.remove(id: session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() {
        for session in sessions {
            close(session)
        }
    }

    // MARK: - Tombstones

    /// Start a fresh session in the dead session's project folder.
    func restartTombstone(_ tombstone: PersistedSession) {
        guard let agent = agentFor(id: tombstone.agentID) else { return } // offline: keep the tombstone
        removeTombstone(id: tombstone.id)
        if let path = tombstone.projectPath {
            createSession(for: agent, initialCommand: "cd \"\(path)\" && claude")
        } else {
            createSession(for: agent)
        }
    }

    func removeTombstone(id: String) {
        tombstones.removeAll { $0.id == id }
        store.remove(id: id)
    }

    // MARK: - Recents

    func recentProjects(for agent: Agent) -> [String] {
        store.recentProjects(forAgent: agent.id)
    }

    private func agentFor(id: String) -> Agent? {
        relay.agents.first { $0.id == id && $0.connected }
    }
}
