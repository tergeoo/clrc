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
                    self.reattachLive(agentID: agent.id)
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
            self?.handleReconnect()
        }
    }

    // MARK: - Reconnect (C1)

    /// The relay drops every session belonging to a client as soon as that
    /// client unregisters — which happens on *any* reconnect (backgrounding,
    /// Wi-Fi → cellular, a failed ping, a relay restart). Every live
    /// session, PTY or chat, needs its own reconnect action; both kinds are
    /// routed through one call to `ReconnectPlanner.plan` over the *full*
    /// inventory, on purpose — see that type's doc comment for why this
    /// shape, rather than a separate planning call per kind, is what turns
    /// "forgot to reattach a session kind" into a planner bug a unit test
    /// can catch, instead of a wiring bug that only shows up live. (This
    /// method itself — that it runs at all on reconnect, and that it is the
    /// thing wired to `relay.onConnect` — is exactly the wiring half that
    /// remains untestable without an Xcode test target; only the planner's
    /// decision is covered by `ReconnectPlannerTests`.)
    ///
    /// Unlike PTY sessions, a chat session that isn't re-`connect`ed has no
    /// way to ever hear from its agent again, and no live event will arrive
    /// to trigger the gap-triggered replay either — so the history request
    /// here is not an optimization, it's required to notice a turn that
    /// finished while the app was away.
    ///
    /// The agent list the relay sends right after auth then counts every
    /// online agent as a new arrival, and `reattachLive` re-sends the
    /// connects for its sessions. The same path covers an *agent* that
    /// reconnects on its own (sleep/wake, network change): the relay drops
    /// every route through the agent's old connection too.
    private func handleReconnect() {
        knownAgentIDs.removeAll()
    }

    /// Re-`connect`s every in-memory session of one agent, PTY and chat,
    /// and replays chat history from each session's last seen event.
    private func reattachLive(agentID: String) {
        let inventory = SessionInventory(
            ptySessions: sessions.map {
                PTYSessionSnapshot(id: $0.id, agentID: $0.agent.id, name: $0.customName,
                                   cols: $0.lastCols, rows: $0.lastRows)
            },
            chatSessions: chatSessions.map {
                ChatSessionSnapshot(id: $0.id, agentID: $0.agent.id, cwd: $0.cwd,
                                    name: $0.customName, lastSeq: $0.transcript.lastSeq)
            }
        )
        let plan = ReconnectPlanner.plan(inventory: inventory, agentID: agentID)

        for action in plan.ptyReconnects {
            relay.sendConnect(agentID: action.agentID, sessionID: action.sessionID,
                              cols: action.cols, rows: action.rows, name: action.name)
        }
        for action in plan.chatReattaches {
            let options = chatConnectOptions()
            relay.sendChatConnect(agentID: action.agentID, sessionID: action.sessionID,
                                  cwd: action.cwd, name: action.name,
                                  style: options.style, profile: options.profile)
            if let session = chatSessions.first(where: { $0.id == action.sessionID }) {
                startChatReplay(for: session)
            }
        }
    }

    /// Requests the tail of a chat session's history and folds it in,
    /// paging through as many requests as needed to fully drain it. The
    /// agent pages `chat_history_result` by a byte budget and reports
    /// `next_seq`; a backlog from a couple of tool-heavy turns can span
    /// several pages, and on the exact path this replay exists for — the
    /// app was away, the turn finished while it was gone, now it reconnects
    /// — no live event will ever arrive to trigger a follow-up request, so
    /// stopping after one page would leave the transcript truncated
    /// mid-turn with the spinner stuck forever. See `fetchChatReplayPage`.
    ///
    /// Also the mechanism behind M9: while `isReplaying` is true, live
    /// events that turn out to be gapped are recorded (not dropped) via
    /// `highWaterSeqDuringReplay`; once the whole paged replay lands, if
    /// that high-water mark is still ahead of `transcript.lastSeq`, another
    /// replay is started immediately rather than waiting for some later
    /// event to happen to trigger one.
    private func startChatReplay(for session: ChatSession) {
        session.isReplaying = true
        session.highWaterSeqDuringReplay = 0
        fetchChatReplayPage(for: session, afterSeq: session.transcript.lastSeq)
    }

    /// Fetches one page of a chat replay and recurses for the next page
    /// while `next_seq` reports forward progress, so `startChatReplay`'s
    /// `isReplaying` window covers the *whole* paged fetch, not just the
    /// first page.
    ///
    /// `next_seq > afterSeq` is the sole continue/stop signal, and it is
    /// also the guard against a non-advancing token: a caught-up or
    /// malformed reply reports `next_seq <= afterSeq` and this stops
    /// immediately rather than re-requesting the same page forever.
    ///
    /// Before applying anything, checks for a buffer reset (Defect 3): if
    /// `next_seq` comes back *behind* this session's own `lastSeq`, the
    /// agent's in-memory seq counter has restarted (e.g. an agent reboot or
    /// `clrc restart`) and our accumulated `lastSeq` belongs to a buffer
    /// that no longer exists. Comparing anything against it from here on
    /// would make every future event look "already seen" and silently drop
    /// it — freezing the tab forever with no error — so the transcript is
    /// discarded and the replay restarts from scratch against the new
    /// counter.
    private func fetchChatReplayPage(for session: ChatSession, afterSeq: UInt64) {
        relay.requestChatHistory(
            agentID: session.agent.id,
            sessionID: session.id,
            afterSeq: afterSeq
        ) { [weak self, weak session] events, nextSeq in
            Task { @MainActor in
                guard let self, let session else { return }

                if session.transcript.isBehindBufferReset(replyNextSeq: nextSeq) {
                    session.resetTranscript()
                    self.fetchChatReplayPage(for: session, afterSeq: 0)
                    return
                }

                session.apply(history: events)

                if nextSeq > afterSeq {
                    self.fetchChatReplayPage(for: session, afterSeq: nextSeq)
                    return
                }

                session.isReplaying = false
                if session.highWaterSeqDuringReplay > session.transcript.lastSeq {
                    self.startChatReplay(for: session)
                }
            }
        }
    }

    // MARK: - Restore

    /// Match persisted sessions against the agent's live PTYs:
    /// reattach the alive ones, tombstone the dead ones. Nothing is created
    /// automatically: new sessions start from the New Session sheet, where the
    /// user picks chat, brief or terminal.
    private func reconcile(_ agent: Agent) {
        let liveChats = Set(chatSessions.map(\.id))
        for entry in store.chatSessions(forAgent: agent.id) where !liveChats.contains(entry.id) {
            restoreChat(entry, agent: agent)
        }

        let alreadyLive = Set(sessions.map(\.id))
        let persisted = store.ptySessions(forAgent: agent.id).filter { !alreadyLive.contains($0.id) }

        guard !persisted.isEmpty else { return }

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

    /// Starts Claude in `cwd` the way the user last chose in the New Session
    /// sheet: a chat session (chat or brief display) or `claude` in a terminal.
    func startClaude(for agent: Agent, cwd: String?, name: String?) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SessionLaunchMode.terminalStorageKey) {
            createSession(for: agent, initialCommand: SessionLaunchMode.terminalCommand(cwd: cwd))
            if let name, !name.isEmpty, let created = sessions.last { rename(created, to: name) }
            return
        }
        let fallback = cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        createChatSession(for: agent, cwd: cwd ?? "~", name: (name?.isEmpty == false ? name : nil) ?? fallback)
    }

    func createChatSession(for agent: Agent, cwd: String, name: String) {
        let session = ChatSession(agent: agent, cwd: cwd, customName: name)
        store.upsert(PersistedSession(
            id: session.id, agentID: agent.id, agentName: agent.name,
            customName: name, projectPath: cwd == "~" ? nil : cwd,
            kind: .chat, cwd: cwd
        ))
        if cwd != "~" {
            store.addRecentProject(cwd, agentID: agent.id)
        }
        attachChat(session)
    }

    /// Brings back a chat session saved by an earlier launch. The agent keeps
    /// chat sessions until they are closed, so the `connect` reattaches and a
    /// full replay rebuilds the transcript.
    private func restoreChat(_ entry: PersistedSession, agent: Agent) {
        let session = ChatSession(agentID: agent.id, agentName: agent.name, sessionID: entry.id,
                                  cwd: entry.cwd ?? "~", customName: entry.customName)
        attachChat(session)
        startChatReplay(for: session)
    }

    /// Adds a chat session to the UI, routes its events and sends `connect`.
    private func attachChat(_ session: ChatSession) {
        chatSessions.append(session)

        relay.registerChatHandler(sessionID: session.id) { [weak self, weak session] event in
            Task { @MainActor in
                guard let self, let session else { return }
                guard session.receive(event) else { return }
                guard !session.isReplaying else {
                    // A replay for an earlier gap is already in flight; this
                    // event would otherwise be dropped silently (M9).
                    // Remember how far ahead we are so the completion
                    // handler in `startChatReplay` can chain another
                    // request instead of leaving the transcript stuck.
                    session.highWaterSeqDuringReplay = max(session.highWaterSeqDuringReplay, event.seq)
                    return
                }
                self.startChatReplay(for: session)
            }
        }

        let options = chatConnectOptions()
        relay.sendChatConnect(agentID: session.agent.id, sessionID: session.id,
                              cwd: session.cwd, name: session.customName,
                              style: options.style, profile: options.profile)
    }

    /// The output style for the selected display mode and the optional
    /// Claude profile, both from Settings. The agent applies them only when
    /// it spawns a session, so a reattach to a live session is unaffected.
    private func chatConnectOptions() -> (style: String, profile: String?) {
        let defaults = UserDefaults.standard
        let style = ChatDisplayMode.stored(in: defaults).outputStyle
        let profile = normalizedProfile(defaults.string(forKey: ChatDisplayMode.profileStorageKey) ?? "")
        return (style, profile)
    }

    /// Interrupts the running turn of a chat session.
    func stop(_ session: ChatSession) {
        relay.sendChatInterrupt(sessionID: session.id)
    }

    func closeChat(_ session: ChatSession) {
        relay.unregisterChatHandler(sessionID: session.id)
        relay.sendDisconnect(sessionID: session.id)
        chatSessions.removeAll { $0.id == session.id }
        store.remove(id: session.id)
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

    /// Restarts an ended session by its id, if it is still listed.
    func restart(endedID: String) {
        guard let tombstone = tombstones.first(where: { $0.id == endedID }) else { return }
        restartTombstone(tombstone)
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
