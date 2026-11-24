import SwiftUI
import ClrcCore

/// Navigation inside the Projects tab.
enum ProjectsRoute: Hashable {
    case mac(agentID: String)
    case project(agentID: String, path: String)
    case folder(agentID: String, path: String)
}

/// Projects tab (spec 5.9): Маки → проекты Мака → проект → файлы. The Mac
/// level is skipped when there is only one Mac.
struct ProjectsView: View {
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @State private var path = NavigationPath()
    @State private var showConnectHelp = false

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: ProjectsRoute.self) { route in
                    switch route {
                    case .mac(let agentID):
                        MacProjectsView(agentID: agentID)
                    case .project(let agentID, let projectPath):
                        ProjectView(agentID: agentID, path: projectPath)
                    case .folder(let agentID, let folder):
                        FolderBrowser(agentID: agentID, path: folder)
                    }
                }
                .navigationDestination(for: SessionRoute.self) { SessionScreen(route: $0) }
                .fileDestinations()
        }
        .environment(\.openSessionRoute) { path.append($0) }
        .sheet(isPresented: $showConnectHelp) { ConnectMacSheet() }
    }

    @ViewBuilder
    private var root: some View {
        if relay.agents.isEmpty {
            ContentUnavailableView {
                Label("Нет Маков", systemImage: "desktopcomputer")
            } description: {
                Text("Запустите clrc на Маке, и он появится здесь.")
            } actions: {
                Button("Как подключить Мак") { showConnectHelp = true }
            }
            .navigationTitle("Проекты")
        } else if !ProjectIndex.showsMacLevel(macCount: relay.agents.count), let only = relay.agents.first {
            MacProjectsView(agentID: only.id)
        } else {
            macList
        }
    }

    private var macList: some View {
        List {
            Section {
                ForEach(relay.agents) { agent in
                    NavigationLink(value: ProjectsRoute.mac(agentID: agent.id)) {
                        MacRow(agent: agent, sessions: sessionCount(agent))
                    }
                }
            }
            Section {
                Button("Подключить ещё Мак", systemImage: "plus") { showConnectHelp = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Маки")
        .refreshable { relay.requestAgentList() }
    }

    private func sessionCount(_ agent: Agent) -> Int {
        sessionManager.chatSessions.filter { $0.agent.id == agent.id }.count
            + sessionManager.sessions.filter { $0.agent.id == agent.id }.count
    }
}

private struct MacRow: View {
    let agent: Agent
    let sessions: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(agent.connected ? Palette.tint : Palette.meta)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.system(size: 17, weight: .semibold))
                HStack(spacing: 6) {
                    StatusDot(color: agent.connected ? Palette.green : Palette.meta, size: 7)
                    Text(agent.connected ? "в сети" : "не в сети")
                    if sessions > 0 {
                        Text("· " + ru(sessions, one: "сессия", few: "сессии", many: "сессий"))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.sec)
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

/// «Подключить ещё Мак»: how to bring another Mac online.
struct ConnectMacSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("На новом Маке установите clrc и укажите тот же relay и секрет агента, что и на первом Маке:")
                    .font(.system(size: 15))
                Text("brew install clrc\nclrc config --relay-url <URL relay> --secret <AGENT_SECRET>\nclrc start")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE6E6EB))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
                Text("Через несколько секунд Мак появится в списке.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.sec)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Подключить Мак")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
