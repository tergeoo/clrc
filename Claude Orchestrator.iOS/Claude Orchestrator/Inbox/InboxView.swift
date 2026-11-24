import SwiftUI
import UIKit
import ClrcCore

/// The Inbox tab: wires the live `InboxModel` to `InboxScreen`.
struct InboxView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var relay: RelayWebSocket

    @State private var showNewTask = false

    var body: some View {
        InboxModelHost(sessionManager: sessionManager, relay: relay) { model in
            InboxScreen(content: model.content, actions: actions(model))
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(onLaunched: { route in path.append(route) })
                .environmentObject(relay)
                .environmentObject(sessionManager)
        }
    }

    private func actions(_ model: InboxModel) -> InboxActions {
        InboxActions(
            open: { path.append($0) },
            answer: { card, index in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.answer(card, questionIndex: index)
            },
            undo: model.undo,
            retry: model.retryConnection,
            newTask: { showNewTask = true },
            launchRecent: { project in
                let request = NewTaskPlanner.request(
                    agentID: project.agentID, cwd: project.path,
                    mode: SessionLaunchMode(displayMode: ChatDisplayMode.stored(in: .standard),
                                            inTerminal: UserDefaults.standard.bool(forKey: SessionLaunchMode.terminalStorageKey)),
                    prompt: "", customName: "", model: "", profile: UserDefaults.standard.string(forKey: ChatDisplayMode.profileStorageKey) ?? "")
                if let route = sessionManager.launch(request) { path.append(route) }
            },
            stop: { id in
                if let chat = sessionManager.chatSessions.first(where: { $0.id == id }) { sessionManager.stop(chat) }
            },
            close: { route in
                switch route {
                case .chat(let id):
                    if let chat = sessionManager.chatSessions.first(where: { $0.id == id }) { sessionManager.closeChat(chat) }
                case .terminal(let id):
                    if let term = sessionManager.sessions.first(where: { $0.id == id }) { sessionManager.close(term) }
                }
            },
            restart: sessionManager.restart(endedID:),
            removeEnded: sessionManager.removeTombstone(id:)
        )
    }
}

/// Owns the model's lifetime as a `@StateObject` (its dependencies come
/// from the environment, which a `@StateObject` initializer cannot read).
private struct InboxModelHost<Content: View>: View {
    @StateObject private var model: InboxModel
    let content: (InboxModel) -> Content

    init(sessionManager: SessionManager, relay: RelayWebSocket, @ViewBuilder content: @escaping (InboxModel) -> Content) {
        _model = StateObject(wrappedValue: InboxModel(sessionManager: sessionManager, relay: relay))
        self.content = content
    }

    var body: some View { content(model) }
}

/// The Inbox, variant 1a (by urgency). Pure: draws `content`, reports taps.
struct InboxScreen: View {
    let content: InboxContent
    let actions: InboxActions

    @State private var showEnded = false
    @State private var pendingClose: SessionRoute?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if !content.relayConnected && !content.isLoading {
                        OfflineBanner(lastSyncText: content.lastSyncText, retry: actions.retry)
                    }
                    if content.isLoading {
                        InboxSkeleton()
                    } else if content.sections.isEmpty {
                        InboxEmptyState(recents: content.recents, newTask: actions.newTask,
                                        launch: actions.launchRecent)
                    } else {
                        sections
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .background(Palette.bg)

            VStack(alignment: .trailing, spacing: 12) {
                if let toast = content.toast {
                    ToastView(text: toast.text, actionTitle: toast.canUndo ? "Отменить" : nil, action: actions.undo)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                NewTaskButton(action: actions.newTask)
            }
            .padding(16)
            .animation(.easeOut(duration: Metrics.transition), value: content.toast)
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Закрыть сессию?", isPresented: closeDialogShown, titleVisibility: .visible) {
            Button("Закрыть", role: .destructive) {
                if let route = pendingClose { actions.close(route) }
            }
        } message: {
            Text("Процесс на Маке будет остановлен.")
        }
    }

    private var closeDialogShown: Binding<Bool> {
        Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Входящие")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
                if !content.isLoading {
                    ConnectionPill(text: content.pill, online: content.relayConnected && content.pill != "нет Маков")
                }
            }
            Text(content.isLoading ? "Подключение…" : content.sections.summaryLine)
                .font(.system(size: 15))
                .foregroundStyle(Palette.sec)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var sections: some View {
        let s = content.sections
        if !s.waiting.isEmpty {
            SectionHeader(title: "Ждёт вас", count: s.waiting.count)
            ForEach(s.waiting) { card in
                WaitingCard(card: card, now: content.now, relayConnected: content.relayConnected,
                            open: { actions.open(.chat(id: card.id)) },
                            answer: { actions.answer(card, $0) })
                    .contextMenu { chatMenu(card, working: false) }
            }
        }
        if !s.working.isEmpty {
            SectionHeader(title: "Работает", count: s.working.count)
            VStack(spacing: 0) {
                ForEach(s.working) { card in
                    WorkingRow(card: card, now: content.now)
                        .onTapGesture { actions.open(.chat(id: card.id)) }
                        .contextMenu { chatMenu(card, working: true) }
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        if !s.done.isEmpty {
            SectionHeader(title: "Готово", count: s.done.count)
            VStack(spacing: 0) {
                ForEach(s.done) { card in
                    DoneRow(card: card, now: content.now)
                        .onTapGesture { actions.open(.chat(id: card.id)) }
                        .contextMenu { chatMenu(card, working: false) }
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        if !s.terminals.isEmpty {
            SectionHeader(title: "Терминалы", count: s.terminals.count)
            VStack(spacing: 0) {
                ForEach(s.terminals) { terminal in
                    TerminalRow(terminal: terminal)
                        .onTapGesture { actions.open(.terminal(id: terminal.id)) }
                        .contextMenu {
                            Button("Открыть", systemImage: "arrow.up.forward") { actions.open(.terminal(id: terminal.id)) }
                            Button("Закрыть", systemImage: "xmark", role: .destructive) { pendingClose = .terminal(id: terminal.id) }
                        }
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        if !s.ended.isEmpty {
            EndedSection(ended: s.ended, expanded: $showEnded, restart: actions.restart, remove: actions.removeEnded)
        }
    }

    @ViewBuilder
    private func chatMenu(_ card: InboxCard, working: Bool) -> some View {
        Button("Открыть", systemImage: "arrow.up.forward") { actions.open(.chat(id: card.id)) }
        if working {
            Button("Стоп", systemImage: "stop.circle") { actions.stop(card.id) }
        }
        Button("Закрыть", systemImage: "xmark", role: .destructive) { pendingClose = .chat(id: card.id) }
    }
}
