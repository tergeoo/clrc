#if DEBUG
import SwiftUI
import ClrcCore

/// Mockup data (docs/design/2.0.0/Inbox.dc.html) for previews and the
/// `-designPreview` launch argument. Debug builds only.
enum InboxFixtures {
    static let now = Date()

    static func chat(_ id: String, _ status: SessionStatus, title: String, summary: String = "",
                     project: String, mac: String = "mbp-work", files: Int = 0, questions: [String] = [],
                     tool: String? = nil, startedAgo: TimeInterval? = nil, ago: TimeInterval = 120,
                     online: Bool = true) -> InboxChatSnapshot {
        let reportStatus: TurnReportStatus = switch status {
        case .needsInput: .needsInput
        case .failed: .failed
        case .working: .inProgress
        case .done: .done
        case .idle: .unknown
        }
        return InboxChatSnapshot(
            id: id, name: project, agentID: mac, agentName: mac, project: project, status: status,
            report: TurnReport(status: reportStatus, title: title, summary: summary, questions: questions,
                               changedFiles: (0..<files).map { "f\($0)" }, contextOK: true),
            currentTool: tool, turnStartedAt: startedAgo.map { now.addingTimeInterval(-$0) },
            updatedAt: now.addingTimeInterval(-ago), agentOnline: online)
    }

    /// `relayDown` mirrors the live model: with no relay every Mac is offline.
    static func sections(offline: Bool = false, relayDown: Bool = false) -> InboxSections {
        let chats = baseChats(offline: offline).map { chat in
            relayDown ? InboxChatSnapshot(id: chat.id, name: chat.name, agentID: chat.agentID, agentName: chat.agentName,
                                          project: chat.project, status: chat.status, report: chat.report,
                                          currentTool: chat.currentTool, turnStartedAt: chat.turnStartedAt,
                                          updatedAt: chat.updatedAt, agentOnline: false) : chat
        }
        return InboxBuilder.build(
            chats: chats,
            terminals: [InboxTerminalSnapshot(id: "t1", name: "zsh", agentName: "mbp-work", isWorking: false, agentOnline: !relayDown)],
            ended: [InboxEndedSnapshot(id: "e1", name: "infra", agentName: "mac-mini", projectPath: "/Users/g/infra", agentOnline: !relayDown)],
            pendingAnswerIDs: [])
    }

    private static func baseChats(offline: Bool) -> [InboxChatSnapshot] {
            [
                chat("api", .needsInput, title: "Миграция users → accounts",
                     summary: "Модели обновлены, миграция обратимая. Запустить на staging или сначала показать SQL?",
                     project: "api", files: 4, questions: ["Запусти на staging", "Покажи SQL"]),
                chat("auth", .failed, title: "3 теста падают в auth_test.go",
                     summary: "После рефакторинга мок токена истекает раньше проверки. Починить мок или откатить?",
                     project: "auth-svc", mac: "mac-mini", files: 2, questions: ["Почини мок", "Откати"],
                     ago: 480, online: !offline),
                chat("web", .working, title: "Passkey-логин", project: "web",
                     tool: "Edit src/routes/login.tsx", startedAgo: 102),
                chat("clrc", .working, title: "Структурированный output", project: "clrc",
                     tool: "Bash: make test", startedAgo: 18),
                chat("docs", .done, title: "README обновлён", summary: "Добавлен раздел про Tailscale.",
                     project: "clrc", files: 1, ago: 3_600),
            ]
    }

    static func content(_ state: String) -> InboxContent {
        var content = InboxContent()
        content.now = now
        content.relayConnected = true
        content.pill = "2 Мака"
        switch state {
        case "offline":
            content.sections = sections(relayDown: true)
            content.relayConnected = false
            content.pill = "нет связи"
            content.lastSyncText = "Показаны данные на 9:32"
        case "empty":
            content.recents = [
                RecentProject(agentID: "m", agentName: "mbp-work", path: "~/startups/api"),
                RecentProject(agentID: "m", agentName: "mbp-work", path: "~/startups/web"),
                RecentProject(agentID: "m", agentName: "mbp-work", path: "~/startups/clrc"),
            ]
        case "loading":
            content.isLoading = true
            content.relayConnected = false
            content.pill = "нет связи"
        case "answered":
            content.sections = sections()
            content.toast = Toast(text: "Ответ отправлен", canUndo: true)
        case "macoffline":
            content.sections = sections(offline: true)
        default:
            content.sections = sections()
        }
        return content
    }
}

/// `-designPreview <state>` (normal | answered | offline | macoffline | empty | loading | newtask | chat | brief | chatworking | chaterror | chatinput | terminal | terminalreconnect | terminalended | folder | file | filesearch | markdown | projects | macprojects | project | settings | newtaskdanger | onboarding | onboardingmanual | onboardingerror | onboardingoffline):
/// the 2.0 shell over fixture data, no relay or sign-in involved.
struct DesignPreviewRoot: View {
    let state: String

    var body: some View {
        if state == "newtask" || state == "newtaskdanger" {
            NewTaskPreviewHost(danger: state == "newtaskdanger")
        } else if DiffPreviewHost.states.contains(state) {
            DiffPreviewHost(state: state)
        } else if state.hasPrefix("onboarding") {
            OnboardingPreviewHost(state: state)
        } else if state == "settings" {
            SettingsPreviewHost()
        } else if ProjectsPreviewHost.states.contains(state) {
            ProjectsPreviewHost(state: state)
        } else if FilesPreviewHost.states.contains(state) {
            FilesPreviewHost(state: state)
        } else if TerminalPreviewHost.states.contains(state) {
            TerminalPreviewHost(state: state)
        } else if ChatPreviewHost.states.contains(state) {
            ChatPreviewHost(state: state)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            NavigationStack { InboxScreen(content: InboxFixtures.content(state), actions: InboxActions()) }
                .tabItem { Label("Входящие", systemImage: "tray.full") }
            Text("Ревью").tabItem { Label("Ревью", systemImage: "checklist") }
            Text("Проекты").tabItem { Label("Проекты", systemImage: "folder") }
            Text("Настройки").tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        .tint(Palette.tint)
    }

    /// The New Task sheet over two fake Macs with recent projects. The relay
    /// points at a discard address and never signs in.
    private struct NewTaskPreviewHost: View {
        @StateObject private var relay: RelayWebSocket
        @StateObject private var sessionManager: SessionManager
        @State private var shown = true
        let danger: Bool

        init(danger: Bool) {
            self.danger = danger
            let (relay, manager) = PreviewEnvironment.make(agents: PreviewEnvironment.macs, recents: PreviewEnvironment.recents)
            _relay = StateObject(wrappedValue: relay)
            _sessionManager = StateObject(wrappedValue: manager)
        }

        var body: some View {
            Palette.bg.ignoresSafeArea()
                .sheet(isPresented: $shown) {
                    NewTaskSheet(preferredAgentID: "mbp", previewDanger: danger)
                        .environmentObject(relay)
                        .environmentObject(sessionManager)
                }
        }
    }

    /// The state named after `-designPreview`, or nil when the argument is absent.
    static var requestedState: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-designPreview") else { return nil }
        return args.indices.contains(index + 1) ? args[index + 1] : "normal"
    }
}

#Preview("Inbox") { InboxScreen(content: InboxFixtures.content("normal"), actions: InboxActions()) }
#Preview("Inbox offline") { InboxScreen(content: InboxFixtures.content("offline"), actions: InboxActions()) }
#Preview("Inbox empty") { InboxScreen(content: InboxFixtures.content("empty"), actions: InboxActions()) }
#Preview("Inbox loading") { InboxScreen(content: InboxFixtures.content("loading"), actions: InboxActions()) }
#endif
