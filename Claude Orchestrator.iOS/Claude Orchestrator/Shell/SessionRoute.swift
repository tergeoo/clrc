import SwiftUI

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
                ChatSessionView(session: chat)
                    .navigationTitle(chat.customName)
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
