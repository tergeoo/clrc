import SwiftUI
import ClrcCore

/// One Mac's projects: recent folders with their session counts, «Все
/// папки…», and sessions running on the Mac that this app is not showing.
struct MacProjectsView: View {
    let agentID: String

    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.openSessionRoute) private var openSessionRoute
    @State private var query = ""
    @State private var remote: [RemoteSessionInfo] = []
    @State private var loadingRemote = false

    private var agent: Agent? { relay.agents.first { $0.id == agentID } }
    private var saved: [String] {
        ProjectIndex.filter(sessionManager.savedProjects(for: agentID), query: query)
    }
    /// Recent folders that are not saved projects.
    private var projects: [String] {
        guard let agent else { return [] }
        let savedSet = Set(sessionManager.savedProjects(for: agentID))
        return ProjectIndex.filter(sessionManager.recentProjects(for: agent), query: query).filter { !savedSet.contains($0) }
    }
    /// Live sessions on the Mac that this app does not hold yet.
    private var unattached: [RemoteSessionInfo] {
        let known = Set(sessionManager.sessions.map(\.id) + sessionManager.chatSessions.map(\.id))
        return remote.filter { !known.contains($0.id) }
    }

    var body: some View {
        List {
            if agent?.connected == false {
                Section {
                    Label("Мак не в сети", systemImage: "wifi.slash").foregroundStyle(Palette.sec)
                }
            }
            if !saved.isEmpty {
                Section("Проекты") {
                    ForEach(saved, id: \.self) { path in
                        NavigationLink(value: ProjectsRoute.project(agentID: agentID, path: path)) {
                            SavedProjectRow(path: path,
                                            config: sessionManager.projectConfig(path: path, agentID: agentID),
                                            profiles: sessionManager.profiles(for: agentID),
                                            sessions: ProjectIndex.sessionCount(path: path, folders: folders))
                        }
                    }
                }
            }
            Section("Недавние проекты") {
                if projects.isEmpty {
                    Text(query.isEmpty ? "Пока нет — откройте папку через «Все папки…»" : "Ничего не найдено")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.meta)
                }
                ForEach(projects, id: \.self) { path in
                    NavigationLink(value: ProjectsRoute.project(agentID: agentID, path: path)) {
                        RecentProjectRow(path: path, sessions: ProjectIndex.sessionCount(path: path, folders: folders))
                    }
                }
                NavigationLink(value: ProjectsRoute.folder(agentID: agentID, path: "~")) {
                    Label("Все папки…", systemImage: "folder")
                }
            }
            if loadingRemote || !unattached.isEmpty {
                Section("Запущено на Маке") {
                    if loadingRemote && unattached.isEmpty { ProgressView() }
                    ForEach(unattached) { info in
                        Button { attach(info) } label: { RemoteSessionRow(info: info) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Поиск проекта")
        .navigationTitle(agent?.name ?? "Мак")
        .task(id: agent?.connected) {
            loadRemote()
            if agent?.connected == true { sessionManager.loadProfiles(agentID: agentID) }
        }
        .refreshable { loadRemote() }
    }

    /// Chat cwds and terminal project folders of this Mac.
    private var folders: [String?] {
        sessionManager.chatSessions.filter { $0.agent.id == agentID }.map { Optional($0.cwd) }
            + sessionManager.sessions.filter { $0.agent.id == agentID }.map(\.projectPath)
    }

    private func loadRemote() {
        guard agent?.connected == true else { return }
        loadingRemote = true
        relay.requestSessionList(agentID: agentID) { sessions in
            remote = sessions ?? []
            loadingRemote = false
        }
    }

    private func attach(_ info: RemoteSessionInfo) {
        guard let agent else { return }
        sessionManager.attachSession(agentID: agent.id, sessionID: info.id, agentName: agent.name, customName: info.name)
        openSessionRoute(.terminal(id: info.id))
    }
}

struct RecentProjectRow: View {
    let path: String
    let sessions: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text((path as NSString).lastPathComponent).font(.system(size: 16, weight: .semibold))
                Spacer()
                if sessions > 0 {
                    Text(ru(sessions, one: "сессия", few: "сессии", many: "сессий"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.tint)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Palette.tintSoft, in: Capsule())
                }
            }
            Text(ChatContent.shortPath(path))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.meta)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(minHeight: 48)
    }
}

private struct RemoteSessionRow: View {
    let info: RemoteSessionInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").foregroundStyle(Palette.sec).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name ?? String(info.id.prefix(8))).font(.system(size: 16))
                Text(subtitle).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.meta).lineLimit(1)
            }
            Spacer()
            Text("Подключиться").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.tint)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let command = info.command { parts.append(command) }
        if let started = info.started { parts.append("с " + started.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

/// A saved project: folder name, its profile badge and mode icon.
struct SavedProjectRow: View {
    let path: String
    let config: ProjectConfig?
    let profiles: MacProfiles?
    let sessions: Int

    var body: some View {
        HStack(spacing: 10) {
            RecentProjectRow(path: path, sessions: sessions)
            if let mode = config?.mode {
                Image(systemName: mode.symbol).foregroundStyle(Palette.meta)
            }
            if let profile = config?.profile {
                // Only flag a missing profile once the Mac has answered.
                ProfileBadge(profile: profile, missing: profiles.map { $0.profile(named: profile) == nil } ?? false)
            }
        }
    }
}
