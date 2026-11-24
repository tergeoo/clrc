import SwiftUI

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
                    .navigationTitle(terminal.customName)
            } else {
                closed
            }
        }
    }

    private var closed: some View {
        ContentUnavailableView("Сессия закрыта", systemImage: "xmark.circle")
    }
}
