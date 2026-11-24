import Foundation
import Combine
import ClrcCore

/// Live Inbox state: turns sessions and relay state into `InboxContent`
/// through `InboxBuilder`, and holds one-tap answers for their undo window
/// before sending them (`PendingAnswerQueue`).
@MainActor
final class InboxModel: ObservableObject {
    static let maxRecents = 5
    static let toastDuration: TimeInterval = 3
    static let tickInterval: TimeInterval = 1

    @Published private(set) var content = InboxContent.empty

    private let sessionManager: SessionManager
    private let relay: RelayWebSocket
    private var queue = PendingAnswerQueue()
    private var lastAnsweredSessionID: String?
    private var toast: Toast?
    private var toastHideAt: Date?
    private var lastSync: Date?
    private var cancellables = Set<AnyCancellable>()

    init(sessionManager: SessionManager, relay: RelayWebSocket) {
        self.sessionManager = sessionManager
        self.relay = relay

        // objectWillChange fires before the change lands: hop to the next
        // run loop turn so the rebuild sees the new values.
        let chatChanges = sessionManager.$chatSessions
            .map { Publishers.MergeMany($0.map(\.objectWillChange)) }
            .switchToLatest()
        let terminalChanges = sessionManager.$sessions
            .map { Publishers.MergeMany($0.map(\.objectWillChange)) }
            .switchToLatest()
        sessionManager.objectWillChange
            .merge(with: relay.objectWillChange, chatChanges, terminalChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        Timer.publish(every: Self.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in self?.tick(now: now) }
            .store(in: &cancellables)

        rebuild()
    }

    // MARK: - Actions

    /// Holds the answer for `PendingAnswerQueue.undoWindow` seconds; the
    /// card moves to «Работает» at once.
    func answer(_ card: InboxCard, questionIndex: Int) {
        guard let text = card.snapshot.report?.answerDraft(forQuestionAt: questionIndex), !text.isEmpty else { return }
        let now = Date()
        queue.enqueue(sessionID: card.id, agentID: card.snapshot.agentID, text: text, now: now)
        lastAnsweredSessionID = card.id
        show(Toast(text: "Ответ отправлен", canUndo: true), now: now)
        rebuild(now: now)
    }

    func undo() {
        if let id = lastAnsweredSessionID { queue.cancel(sessionID: id) }
        lastAnsweredSessionID = nil
        toast = nil
        rebuild()
    }

    func retryConnection() {
        relay.connect()
    }

    // MARK: - Clock

    private func tick(now: Date) {
        let (send, dropped) = queue.drain(now: now, onlineAgentIDs: onlineAgentIDs())
        for answer in send {
            relay.sendChatMessage(sessionID: answer.sessionID, text: answer.text)
        }
        if let first = dropped.first {
            let mac = relay.agents.first { $0.id == first.agentID }?.name ?? "Мак"
            show(Toast(text: "Не отправлено: \(mac) не в сети", canUndo: false), now: now)
        }
        if let hideAt = toastHideAt, now >= hideAt {
            toast = nil
            toastHideAt = nil
        }
        rebuild(now: now)
    }

    private func show(_ toast: Toast, now: Date) {
        self.toast = toast
        toastHideAt = now.addingTimeInterval(Self.toastDuration)
    }

    // MARK: - Snapshot

    /// Answers can only go out while the relay itself is connected.
    private func onlineAgentIDs() -> Set<String> {
        guard relay.connectionState == .connected else { return [] }
        return Set(relay.agents.filter(\.connected).map(\.id))
    }

    private func rebuild(now: Date = Date()) {
        let online = onlineAgentIDs()
        let relayConnected = relay.connectionState == .connected
        if relayConnected { lastSync = now }

        let chats = sessionManager.chatSessions.map { snapshot(of: $0, online: online) }
        let terminals = sessionManager.sessions.map { session -> InboxTerminalSnapshot in
            var working = false
            if case .working = session.claudeState { working = true }
            return InboxTerminalSnapshot(id: session.id, name: session.customName, agentName: session.agent.name,
                                         isWorking: working, agentOnline: online.contains(session.agent.id))
        }
        let ended = sessionManager.tombstones.map {
            InboxEndedSnapshot(id: $0.id, name: $0.customName, agentName: $0.agentName, projectPath: $0.projectPath)
        }

        var content = InboxContent()
        content.sections = InboxBuilder.build(chats: chats, terminals: terminals, ended: ended,
                                              pendingAnswerIDs: queue.sessionIDs)
        content.relayConnected = relayConnected
        content.pill = InboxBuilder.connectionPill(relayConnected: relayConnected,
                                                   onlineMacs: relay.agents.filter(\.connected).count)
        content.isLoading = relay.connectionState == .connecting && relay.agents.isEmpty && content.sections.isEmpty
        content.lastSyncText = relayConnected ? nil : lastSync.map {
            "Показаны данные на " + $0.formatted(date: .omitted, time: .shortened)
        }
        content.toast = toast
        content.now = now
        content.recents = recents()
        if content != self.content { self.content = content }
    }

    private func snapshot(of chat: ChatSession, online: Set<String>) -> InboxChatSnapshot {
        let lastTurn = chat.transcript.turns.last
        let lastEventTime = lastTurn?.events.last.flatMap { parseEventTimestamp($0.ts) }
        return InboxChatSnapshot(
            id: chat.id, name: chat.customName, agentID: chat.agent.id, agentName: chat.agent.name,
            project: chat.cwd == "~" ? "домашняя папка" : (chat.cwd as NSString).lastPathComponent,
            status: SessionStatus.derive(isWorking: chat.isWorking, lastError: chat.lastError,
                                         report: chat.transcript.latestReport),
            report: chat.transcript.latestReport,
            currentTool: lastTurn?.currentTool,
            turnStartedAt: lastTurn?.startedAt,
            updatedAt: lastEventTime ?? chat.createdAt,
            agentOnline: online.contains(chat.agent.id))
    }

    private func recents() -> [RecentProject] {
        relay.agents.filter(\.connected).flatMap { agent in
            sessionManager.recentProjects(for: agent).map {
                RecentProject(agentID: agent.id, agentName: agent.name, path: $0)
            }
        }
        .prefix(Self.maxRecents)
        .map { $0 }
    }
}
