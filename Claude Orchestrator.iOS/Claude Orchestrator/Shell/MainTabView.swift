import SwiftUI
import ClrcCore

enum MainTab: Hashable {
    case inbox, review, projects, settings
}

/// The 2.0 shell: Входящие · Ревью · Проекты · Настройки. Sessions are
/// pushed full screen inside the Inbox stack.
struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager

    @State private var tab: MainTab = .inbox
    @State private var inboxPath = NavigationPath()
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $inboxPath) {
                InboxView(path: $inboxPath)
                    .navigationDestination(for: SessionRoute.self) { SessionScreen(route: $0) }
                    .diffDestinations()
                    .fileDestinations()
            }
            .environment(\.openSessionRoute) { inboxPath.append($0) }
            .environment(\.openDiff) { inboxPath.append($0) }
            .tabItem { Label("Входящие", systemImage: "tray.full") }
            .tag(MainTab.inbox)

            ReviewScreen()
                .tabItem { Label("Ревью", systemImage: "checklist") }
                .tag(MainTab.review)

            ProjectsView()
                .tabItem { Label("Проекты", systemImage: "folder") }
                .tag(MainTab.projects)

            SettingsScreen()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(Palette.tint)
        // A tapped notification opens its chat in the Inbox.
        .onChange(of: push.openRequest) { _, target in
            guard let target, sessionManager.chatSessions.contains(where: { $0.id == target.sessionID }) else { return }
            tab = .inbox
            inboxPath = NavigationPath()
            inboxPath.append(SessionRoute.chat(id: target.sessionID))
            push.openRequest = nil
        }
    }
}
