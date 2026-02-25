import SwiftUI

// MARK: - ViewMode

enum ViewMode: String, CaseIterable {
    case terminal, files
}

// MARK: - SessionTabsView (root view when sessions exist)

struct SessionTabsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var authService: AuthService

    @State private var selectedSessionID: String?
    @State private var viewMode: ViewMode = .terminal
    @State private var showAddAgent = false

    var activeSession: TerminalSession? {
        sessionManager.sessions.first(where: { $0.id == selectedSessionID })
            ?? sessionManager.sessions.first
    }

    var body: some View {
        Group {
            if sessionManager.sessions.isEmpty {
                AgentListView()
            } else {
                mainView
            }
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

    // MARK: - Main layout

    private var mainView: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            reconnectingBanner
            contentArea
            if viewMode == .terminal, let session = activeSession {
                Divider()
                QuickCommandBar { bytes in
                    relay.sendInput(sessionID: session.id, data: Data(bytes))
                }
            }
        }
        .sheet(isPresented: $showAddAgent) {
            AgentListView()
                .environmentObject(relay)
                .environmentObject(sessionManager)
                .environmentObject(authService)
        }
        .onChange(of: sessionManager.sessions) { _, sessions in
            if let last = sessions.last,
               selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = last.id
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // Machine pills (scrollable)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessionManager.sessions) { session in
                        MachinePill(
                            name: session.agent.name,
                            isSelected: activeSession?.id == session.id
                        ) {
                            selectedSessionID = session.id
                        } onClose: {
                            closeSession(session)
                        }
                    }
                    // Add machine button
                    Button { showAddAgent = true } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // Separator
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(width: 0.5, height: 30)

            // Terminal / Files toggle
            Picker("", selection: $viewMode) {
                Image(systemName: "terminal.fill").tag(ViewMode.terminal)
                Image(systemName: "folder.fill").tag(ViewMode.files)
            }
            .pickerStyle(.segmented)
            .frame(width: 88)
            .padding(.horizontal, 10)
        }
        .frame(height: 46)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if let session = activeSession {
            Group {
                if viewMode == .terminal {
                    RemoteTerminalView(session: session)
                        .id(session.id)
                        .ignoresSafeArea(edges: .bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileBrowserView(
                        agentID: session.agent.id,
                        agentName: session.agent.name,
                        embedded: true
                    ) { path, dangerous in
                        let cmd = dangerous
                            ? "cd \"\(path)\" && claude --dangerously-skip-permissions"
                            : "cd \"\(path)\" && claude"
                        sessionManager.createSession(for: session.agent, initialCommand: cmd)
                        viewMode = .terminal
                    }
                    .environmentObject(relay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func closeSession(_ session: TerminalSession) {
        relay.sendDisconnect(sessionID: session.id)
        relay.unregisterSessionHandler(sessionID: session.id)
        sessionManager.remove(session: session)
        if selectedSessionID == session.id {
            selectedSessionID = sessionManager.sessions.first?.id
        }
    }
}

// MARK: - MachinePill

struct MachinePill: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// Shortened display name: take part before first "." or first 14 chars
    private var shortName: String {
        let s = name.components(separatedBy: ".").first ?? name
        return s.count > 14 ? String(s.prefix(14)) : s
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)

            Text(shortName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color(UIColor.secondarySystemBackground)
                : Color(UIColor.tertiarySystemBackground),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture { onSelect() }
    }
}
