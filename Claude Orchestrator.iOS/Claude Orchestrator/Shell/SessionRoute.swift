import SwiftUI
import ClrcCore

private struct OpenSessionRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (SessionRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes another session (e.g. «Терминал здесь» from a chat) onto the
    /// current stack. Set by `MainTabView`.
    var openSessionRoute: @MainActor (SessionRoute) -> Void {
        get { self[OpenSessionRouteKey.self] }
        set { self[OpenSessionRouteKey.self] = newValue }
    }
}

/// A session opened full screen from the Inbox or Projects.
enum SessionRoute: Hashable {
    case chat(id: String)
    case terminal(id: String)
}

/// Resolves a route to the live session's screen. The tab bar is hidden
/// inside a session to give the content the whole height (brief §4).
struct SessionScreen: View {
    let route: SessionRoute
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .chat(let id):
            if let chat = sessionManager.chatSessions.first(where: { $0.id == id }) {
                ChatScreen(session: chat)
            } else {
                closed
            }
        case .terminal(let id):
            if let terminal = sessionManager.sessions.first(where: { $0.id == id }) {
                TerminalScreen(session: terminal)
            } else if let ended = sessionManager.tombstones.first(where: { $0.id == id }) {
                EndedSessionView(ended: ended) {
                    sessionManager.restart(endedID: id)
                    dismiss()
                }
            } else {
                closed
            }
        }
    }

    private var closed: some View {
        ContentUnavailableView("Сессия закрыта", systemImage: "xmark.circle")
    }
}

/// A terminal whose process is gone: «Сессия завершена» + «Перезапустить».
struct EndedSessionView: View {
    let ended: PersistedSession
    let restart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TerminalChrome.blue)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
                .accessibilityLabel("Назад")
                Text("\(ended.customName) · \(ended.agentName)").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .frame(height: 44)
            Spacer()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сессия завершена").font(.system(size: 15, weight: .semibold))
                    Text(ended.projectPath.map(ChatContent.shortPath) ?? ended.agentName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TerminalChrome.dim)
                }
                Spacer()
                Button("Перезапустить", action: restart)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(TerminalChrome.blue, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(TerminalChrome.badge, in: RoundedRectangle(cornerRadius: 12))
            .padding(10)
        }
        .foregroundStyle(TerminalChrome.text)
        .background(Palette.code)
        .toolbar(.hidden, for: .navigationBar)
    }
}
