import SwiftUI
import ClrcCore

/// A project (spec 5.9 level 3): «Новая задача здесь», «Терминал здесь»,
/// its sessions and its files.
struct ProjectView: View {
    let agentID: String
    let path: String

    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.openSessionRoute) private var openSessionRoute
    @Environment(\.openDiff) private var openDiff
    @State private var newTask = false
    @State private var git: GitStatusInfo?
    @State private var gitError: String?
    /// Fixture status for previews; skips the request.
    var previewGit: GitStatusInfo?

    private var name: String { (path as NSString).lastPathComponent }
    private var online: Bool { relay.agents.contains { $0.id == agentID && $0.connected } }

    private var chats: [ChatSession] {
        sessionManager.chatSessions.filter {
            $0.agent.id == agentID && ProjectIndex.sessionCount(path: path, folders: [$0.cwd]) == 1
        }
    }
    private var terminals: [TerminalSession] {
        sessionManager.sessions.filter {
            $0.agent.id == agentID && ProjectIndex.sessionCount(path: path, folders: [$0.projectPath]) == 1
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 22, weight: .bold))
                    Text(ChatContent.shortPath(path)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.meta)
                    if let git {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(git.branch.isEmpty ? "—" : git.branch).font(.system(size: 13, design: .monospaced))
                            if git.ahead > 0 { Text("↑\(git.ahead)") }
                            if git.behind > 0 { Text("↓\(git.behind)") }
                            if git.isDirty {
                                Text("· есть изменения").foregroundStyle(Palette.orange)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.sec)
                    }
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    bigButton("Новая задача здесь", symbol: "plus", primary: true) { newTask = true }
                    bigButton("Терминал здесь", symbol: "terminal", primary: false) {
                        if let route = sessionManager.openTerminal(in: path, agentID: agentID) { openSessionRoute(route) }
                    }
                }
                .disabled(!online)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if !chats.isEmpty || !terminals.isEmpty {
                Section("Сессии в проекте") {
                    ForEach(chats) { chat in
                        Button { openSessionRoute(.chat(id: chat.id)) } label: { ChatSessionRow(session: chat) }
                            .buttonStyle(.plain)
                    }
                    ForEach(terminals) { terminal in
                        Button { openSessionRoute(.terminal(id: terminal.id)) } label: {
                            Label(terminal.customName, systemImage: "terminal")
                                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let git, git.isDirty {
                Section("Изменения") {
                    ForEach(git.files.prefix(Self.maxChangedRows)) { file in
                        Button {
                            openDiff(DiffRoute(agentID: agentID, repo: path, files: [file.path], title: (file.path as NSString).lastPathComponent))
                        } label: {
                            HStack(spacing: 10) {
                                ChangeBadge(kind: file.kind)
                                Text(file.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            }
                            .frame(minHeight: Metrics.minTapTarget)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Все изменения (\(git.files.count))") {
                        openDiff(DiffRoute(agentID: agentID, repo: path, files: nil, title: "Изменения \(name)"))
                    }
                }
            } else if let gitError {
                Section("Изменения") {
                    Text(gitError).font(.system(size: 14)).foregroundStyle(Palette.meta)
                }
            }

            Section("Файлы") {
                NavigationLink(value: ProjectsRoute.folder(agentID: agentID, path: path)) {
                    Label("Открыть файлы проекта", systemImage: "folder")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: online) { await loadGit() }
        .refreshable { await loadGit() }
        .sheet(isPresented: $newTask) {
            NewTaskSheet(preferredAgentID: agentID, preferredProject: path, onLaunched: openSessionRoute)
        }
    }

    private static let maxChangedRows = 8

    private func loadGit() async {
        if let previewGit { git = previewGit; return }
        guard online else { return }
        do {
            git = try await GitClient(relay: relay).status(agentID: agentID, path: path)
            gitError = nil
        } catch GitClientError.notARepository {
            git = nil
            gitError = nil
        } catch {
            gitError = error.localizedDescription
        }
    }

    private func bigButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(primary ? Color.white : Palette.tint)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(primary ? Palette.tint : Palette.tintSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A chat in a project list, with its live status.
private struct ChatSessionRow: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        let report = session.transcript.latestReport
        let status = SessionStatus.derive(isWorking: session.isWorking, lastError: session.lastError, report: report)
        HStack(spacing: 12) {
            StatusIcon(status: status, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(report?.title.isEmpty == false ? report!.title : session.customName)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(status.label).font(.system(size: 12)).foregroundStyle(Palette.meta)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }
}
