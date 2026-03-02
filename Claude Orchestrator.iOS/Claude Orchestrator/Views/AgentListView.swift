import SwiftUI

struct AgentListView: View {
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService: AuthService

    // Session picker state
    @State private var selectedAgent: Agent?
    @State private var existingSessions: [[String: Any]] = []
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

        let requestID = UUID().uuidString
        relay.onSessionsList = { reqID, sessions in
            guard reqID == requestID else { return }
            existingSessions = sessions
            isLoadingSessions = false
        }
        relay.requestSessionList(agentID: agent.id, requestID: requestID)

        // Timeout fallback
        Task {
            try? await Task.sleep(for: .seconds(3))
            if isLoadingSessions {
                isLoadingSessions = false
            }
        }

        // Open sheet after setting up the request
        selectedAgent = agent
    }
}

// MARK: - SessionPickerView

struct SessionPickerView: View {
    let agent: Agent
    let existing: [[String: Any]]
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
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Loading sessions…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !existing.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(existing, id: \.sessionID) { (session: [String: Any]) in
                            Button {
                                onPick(session.sessionID)
                            } label: {
                                HStack {
                                    Image(systemName: "terminal")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.shortID)
                                            .font(.system(.body, design: .monospaced))
                                        Text("\(session.cols)×\(session.rows)")
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

// MARK: - Helpers

private extension Dictionary where Key == String, Value == Any {
    var sessionID: String { self["id"] as? String ?? "" }
    var cols: Int { self["cols"] as? Int ?? 80 }
    var rows: Int { self["rows"] as? Int ?? 24 }
    var shortID: String {
        let id = sessionID
        return id.count > 8 ? String(id.prefix(8)) + "…" : id
    }
}
