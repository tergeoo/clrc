import SwiftUI
import ClrcCore

// MARK: - AppTab

enum AppTab: String, CaseIterable {
    case terminal = "Terminal"
    case files    = "Files"
}

// MARK: - SessionTabsView

struct SessionTabsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var authService: AuthService

    @State private var selectedSessionID: String?
    @State private var activeTab: AppTab = .terminal
    @State private var showMachineSelector = false
    @State private var showSettings = false
    @State private var showAddAgent = false
    @State private var showNewSession = false

    var activeSession: TerminalSession? {
        sessionManager.sessions.first(where: { $0.id == selectedSessionID })
            ?? sessionManager.sessions.first
    }

    var activeChatSession: ChatSession? {
        sessionManager.chatSessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        Group {
            if sessionManager.sessions.isEmpty && sessionManager.chatSessions.isEmpty {
                waitingView
            } else {
                mainView
            }
        }
    }

    // Shown when no sessions exist yet — full agent list so user can connect immediately
    private var waitingView: some View {
        AgentListView()
            .environmentObject(relay)
            .environmentObject(sessionManager)
            .environmentObject(authService)
    }

    // MARK: - Main layout

    private var mainView: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            reconnectingBanner
            topTabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showMachineSelector) {
            MachineSelectorSheet(
                selectedSessionID: $selectedSessionID,
                onAddMachine: {
                    showMachineSelector = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showAddAgent = true
                    }
                },
                onDismiss: { showMachineSelector = false }
            )
            .environmentObject(relay)
            .environmentObject(sessionManager)
            .environmentObject(authService)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(authService)
                .environmentObject(relay)
                .environmentObject(sessionManager)
        }
        .sheet(isPresented: $showAddAgent) {
            AgentListView()
                .environmentObject(relay)
                .environmentObject(sessionManager)
                .environmentObject(authService)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(preferredAgentID: activeSession?.agent.id)
                .environmentObject(relay)
                .environmentObject(sessionManager)
        }
        .onChange(of: sessionManager.sessions) { _, sessions in
            if let last = sessions.last,
               selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = last.id
            }
        }
        .onChange(of: sessionManager.chatSessions) { _, chats in
            if let last = chats.last,
               selectedSessionID == nil || !chats.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = last.id
            }
        }
        // Dismiss keyboard whenever the user switches away from the Terminal tab.
        // Without this, SwiftTerm keeps first responder and the keyboard covers the tab bar.
        .onChange(of: activeTab) { _, _ in
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }

    // MARK: - Top bar (44pt)

    private var topBar: some View {
        HStack(spacing: 12) {
            // Session name button — uses ObservedObject wrapper for live updates
            if let chat = activeChatSession {
                Button { showMachineSelector = true } label: {
                    HStack(spacing: 5) {
                        Text(chat.customName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else if let session = activeSession {
                SessionNameButton(session: session) {
                    showMachineSelector = true
                }
            } else {
                Button { showMachineSelector = true } label: {
                    HStack(spacing: 5) {
                        Text("No Session")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Connection status
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(connectionLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // New session
            Button {
                showNewSession = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            // Settings
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    private var connectionColor: Color {
        switch relay.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    private var connectionLabel: String {
        switch relay.connectionState {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }

    // MARK: - Reconnecting banner

    @ViewBuilder
    private var reconnectingBanner: some View {
        if relay.connectionState == .connecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Reconnecting…")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color(UIColor.systemYellow).opacity(0.15))
        } else if relay.connectionState == .disconnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12))
                Text("Disconnected")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Retry") { relay.connect() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(UIColor.systemRed).opacity(0.1))
        }
    }

    // MARK: - Top tab bar

    private var topTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                TopTabButton(
                    tab: tab,
                    isSelected: activeTab == tab,
                    action: { activeTab = tab }
                )
            }
        }
        .background(.bar)
    }

    // MARK: - Tab content (switch, no bottom tab bar)

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .terminal: terminalTab
        case .files:    filesTab
        }
    }

    @ViewBuilder
    private var terminalTab: some View {
        if let chat = activeChatSession {
            ChatSessionView(session: chat)
                .environmentObject(relay)
        } else if let session = activeSession {
            TerminalTabContent(session: session)
        } else {
            noSessionPlaceholder
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        if let session = activeSession {
            FileBrowserView(
                agentID: session.agent.id,
                agentName: session.agent.name,
                embedded: true
            ) { path, dangerous in
                let cmd = dangerous
                    ? "cd \"\(path)\" && claude --dangerously-skip-permissions"
                    : "cd \"\(path)\" && claude"
                sessionManager.createSession(for: session.agent, initialCommand: cmd)
                activeTab = .terminal
            }
            .id(session.agent.id)
            .environmentObject(relay)
        } else {
            noSessionPlaceholder
        }
    }

    private var noSessionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No active session")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - TopTabButton

private struct TopTabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void

    private var icon: String {
        switch tab {
        case .terminal: return "terminal.fill"
        case .files:    return "folder.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.top, 8)

                // Underline indicator
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .animation(.easeInOut(duration: 0.2), value: isSelected)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SessionNameButton
// Separate struct so @ObservedObject tracks customName / claudeState live.

private struct SessionNameButton: View {
    @ObservedObject var session: TerminalSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Working indicator dot (orange when Claude is active)
                if case .working = session.claudeState {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                }
                Text(session.customName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MachineSelectorSheet
// Shows active sessions + available agents in one unified list.

private struct MachineSelectorSheet: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var relay: RelayWebSocket

    @Binding var selectedSessionID: String?
    let onAddMachine: () -> Void   // opens full AgentListView for reattach
    let onDismiss: () -> Void

    @State private var sessionToRename: TerminalSession?
    @State private var renameDraft = ""

    var body: some View {
        NavigationView {
            List {
                // ── Active sessions ──────────────────────────────────────
                if !sessionManager.sessions.isEmpty {
                    Section {
                        ForEach(sessionManager.sessions) { session in
                            SessionRowView(
                                session: session,
                                isActive: session.id == selectedSessionID
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSessionID = session.id
                                onDismiss()
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    sessionToRename = session
                                    renameDraft = session.customName
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Close", role: .destructive) {
                                    closeSession(session)
                                }
                            }
                        }
                    } header: {
                        Label(
                            "\(sessionManager.sessions.count) active session\(sessionManager.sessions.count == 1 ? "" : "s")",
                            systemImage: "terminal"
                        )
                    }
                }

                // ── Chat sessions ────────────────────────────────────────
                if !sessionManager.chatSessions.isEmpty {
                    Section {
                        ForEach(sessionManager.chatSessions) { chat in
                            ChatSessionRowView(
                                session: chat,
                                isActive: chat.id == selectedSessionID
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSessionID = chat.id
                                onDismiss()
                            }
                        }
                    } header: {
                        Label(
                            "\(sessionManager.chatSessions.count) chat session\(sessionManager.chatSessions.count == 1 ? "" : "s")",
                            systemImage: "message"
                        )
                    }
                }

                // ── Mac Agents ───────────────────────────────────────────
                if !relay.agents.isEmpty {
                    Section {
                        ForEach(relay.agents) { agent in
                            AgentSelectorRow(
                                agent: agent,
                                openSessionCount: sessionManager.sessions
                                    .filter { $0.agent.id == agent.id }.count
                            ) {
                                sessionManager.createSession(for: agent)
                                onDismiss()
                            }
                        }
                    } header: {
                        Label("Mac Agents", systemImage: "desktopcomputer")
                    }
                } else if relay.connectionState == .connected {
                    Section {
                        Label("No agents online", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } header: {
                        Label("Mac Agents", systemImage: "desktopcomputer")
                    }
                }

                // ── Ended sessions (PTY gone) ────────────────────────────
                if !sessionManager.tombstones.isEmpty {
                    Section {
                        ForEach(sessionManager.tombstones) { tombstone in
                            HStack(spacing: 12) {
                                Image(systemName: "moon.zzz")
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tombstone.customName)
                                        .foregroundStyle(.secondary)
                                    if let path = tombstone.projectPath {
                                        Text(path)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Button {
                                    sessionManager.restartTombstone(tombstone)
                                    onDismiss()
                                } label: {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    sessionManager.removeTombstone(id: tombstone.id)
                                }
                            }
                        }
                    } header: {
                        Label("Ended sessions", systemImage: "moon.zzz")
                    }
                }

                // ── Footer actions ───────────────────────────────────────
                Section {
                    Button(action: onAddMachine) {
                        Label("Reattach to existing session…", systemImage: "arrow.clockwise")
                            .foregroundStyle(Color.accentColor)
                    }
                    if !sessionManager.sessions.isEmpty {
                        Button("Close All Sessions", role: .destructive) {
                            onDismiss()
                            sessionManager.closeAll()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions & Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .alert("Rename Session", isPresented: renameAlertBinding) {
            TextField("Session name", text: $renameDraft)
                .autocorrectionDisabled()
            Button("Save") {
                if let session = sessionToRename {
                    sessionManager.rename(session, to: renameDraft)
                }
                sessionToRename = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToRename = nil
            }
        } message: {
            Text("Choose a name that helps you identify this session")
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }

    private func closeSession(_ session: TerminalSession) {
        sessionManager.close(session)
        if selectedSessionID == session.id {
            selectedSessionID = sessionManager.sessions.first?.id
        }
    }
}

// MARK: - AgentSelectorRow

private struct AgentSelectorRow: View {
    let agent: Agent
    let openSessionCount: Int
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Online indicator
            Circle()
                .fill(agent.connected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(shortName)
                    .font(.body)
                    .foregroundStyle(agent.connected ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if agent.connected {
                Button(action: onNewSession) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    private var shortName: String {
        agent.name.components(separatedBy: ".").first ?? agent.name
    }

    private var subtitle: String {
        guard agent.connected else { return "Offline" }
        if openSessionCount == 0 {
            return "Tap + to start a session"
        }
        return "\(openSessionCount) session\(openSessionCount == 1 ? "" : "s") open · tap + to add"
    }
}

// MARK: - SessionRowView
// @ObservedObject allows live updates to claudeState and customName.

private struct SessionRowView: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Active indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.customName)
                    .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    // Agent name (short)
                    Text(shortAgentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Claude state badge
                    claudeStateBadge
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 3)
    }

    private var shortAgentName: String {
        session.agent.name.components(separatedBy: ".").first ?? session.agent.name
    }

    @ViewBuilder
    private var claudeStateBadge: some View {
        switch session.claudeState {
        case .idle:
            EmptyView()
        case .working(let toolsUsed):
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                Text(toolsUsed > 0
                     ? "working · \(toolsUsed) tool\(toolsUsed == 1 ? "" : "s")"
                     : "working…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - ChatSessionRowView
// Mirrors SessionRowView's style for chat sessions in the machine selector.
// Rename/close are intentionally not offered here — out of scope for this pass.

private struct ChatSessionRowView: View {
    @ObservedObject var session: ChatSession
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Active indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.customName)
                    .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    // Agent name (short)
                    Text(shortAgentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Working badge
                    if session.isWorking {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5, height: 5)
                            Text("working…")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 3)
    }

    private var shortAgentName: String {
        session.agent.name.components(separatedBy: ".").first ?? session.agent.name
    }
}

// MARK: - TerminalTabContent

private struct TerminalTabContent: View {
    let session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket

    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 0) {
                QuickCommandBar { bytes in
                    relay.sendInput(sessionID: session.id, data: Data(bytes))
                }

                // Keyboard dismiss button — appears only when keyboard is up
                if keyboardVisible {
                    Divider().frame(height: 32)
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, height: 44)
                    }
                }
            }
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}
