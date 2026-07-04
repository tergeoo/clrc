import SwiftUI
import ClrcCore

struct AgentListView: View {
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService: AuthService

    // Session picker state
    @State private var selectedAgent: Agent?
    @State private var existingSessions: [RemoteSessionInfo] = []
    @State private var isLoadingSessions = false

    var body: some View {
        NavigationView {
            Group {
                if relay.connectionState != .connected {
                    connectionStatusView
                } else if relay.agents.isEmpty {
                    emptyView
                } else {
                    agentList
                }
            }
            .navigationTitle("Mac Agents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        connectionIndicator
                        Button { authService.logout() } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { relay.requestAgentList() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(item: $selectedAgent) { agent in
            SessionPickerView(
                agent: agent,
                existing: existingSessions,
                isLoading: isLoadingSessions
            ) { sessionID in
                selectedAgent = nil
                if let sid = sessionID {
                    sessionManager.attachSession(agentID: agent.id, sessionID: sid, agentName: agent.name)
                } else {
                    sessionManager.createSession(for: agent)
                }
            }
            .environmentObject(relay)
            .environmentObject(sessionManager)
        }
    }

    // MARK: - Subviews

    private var agentList: some View {
        List(relay.agents) { agent in
            AgentRow(
                agent: agent,
                openSessionCount: sessionManager.sessions.filter { $0.agent.id == agent.id }.count
            ) {
                connectTapped(agent: agent)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var connectionStatusView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(relay.connectionState == .connecting ? "Connecting to relay..." : "Disconnected")
                .foregroundStyle(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No agents online")
                .font(.headline)
            Text("Start the claude-agent daemon on your Mac\nand it will appear here automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var connectionIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 10, height: 10)
    }

    private var indicatorColor: Color {
        switch relay.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    // MARK: - Actions

    private func connectTapped(agent: Agent) {
        existingSessions = []
        isLoadingSessions = true
        relay.requestSessionList(agentID: agent.id) { sessions in
            existingSessions = sessions ?? []
            isLoadingSessions = false
        }
        selectedAgent = agent
    }
}

// MARK: - SessionPickerView

struct SessionPickerView: View {
    let agent: Agent
    let existing: [RemoteSessionInfo]
    let isLoading: Bool
    let onPick: (String?) -> Void  // nil = new session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        Label("New Session", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if isLoading {
                    Section("Existing Sessions") {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text("Loading sessions…").foregroundStyle(.secondary)
                        }
                    }
                } else if !existing.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(existing) { session in
                            Button {
                                onPick(session.id)
                            } label: {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name ?? String(session.id.prefix(8)) + "…")
                                            .font(.body)
                                        Text(sessionSubtitle(session))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func sessionSubtitle(_ session: RemoteSessionInfo) -> String {
        var parts: [String] = []
        if let command = session.command { parts.append(command) }
        if let started = session.started {
            parts.append("since " + started.formatted(date: .omitted, time: .shortened))
        }
        parts.append("\(session.cols)×\(session.rows)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - AgentRow

struct AgentRow: View {
    let agent: Agent
    let openSessionCount: Int
    let onConnect: () -> Void

    var body: some View {
        Button(action: { if agent.connected { onConnect() } }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agent.connected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        if agent.connected {
                            Text(openSessionCount == 0
                                 ? "Online — tap to connect"
                                 : "Online · \(openSessionCount) session\(openSessionCount == 1 ? "" : "s") open")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Offline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if agent.connected {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
