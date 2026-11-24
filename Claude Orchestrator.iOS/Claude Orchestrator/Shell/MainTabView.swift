import SwiftUI

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

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $inboxPath) {
                InboxView(path: $inboxPath)
                    .navigationDestination(for: SessionRoute.self) { SessionScreen(route: $0) }
            }
            .environment(\.openSessionRoute) { inboxPath.append($0) }
            .tabItem { Label("Входящие", systemImage: "tray.full") }
            .tag(MainTab.inbox)

            ContentUnavailableView("Ревью появится в следующем этапе", systemImage: "checklist")
                .tabItem { Label("Ревью", systemImage: "checklist") }
                .tag(MainTab.review)

            ProjectsView()
                .tabItem { Label("Проекты", systemImage: "folder") }
                .tag(MainTab.projects)

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(Palette.tint)
    }
}
