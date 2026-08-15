import SwiftUI
import ClrcCore

/// Two-tap session creation: pick a Mac, tap a recent project (or browse).
struct NewSessionSheet: View {
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    /// Preselected agent (current session's agent), if still online.
    let preferredAgentID: String?

    @State private var selectedAgentID: String?
    @State private var customName = ""
    @State private var showBrowser = false

    private var onlineAgents: [Agent] {
        relay.agents.filter(\.connected)
    }

    private var selectedAgent: Agent? {
        onlineAgents.first { $0.id == selectedAgentID } ?? onlineAgents.first
    }

    var body: some View {
        NavigationView {
            List {
                if onlineAgents.isEmpty {
                    Section {
                        Label("No agents online", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if onlineAgents.count > 1 {
                        Section("Mac") {
                            Picker("Mac", selection: agentSelection) {
                                ForEach(onlineAgents) { agent in
                                    Text(shortName(agent.name)).tag(agent.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    if let agent = selectedAgent {
                        projectSection(agent: agent)
                        optionsSection
                        startSection(agent: agent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showBrowser) {
                if let agent = selectedAgent {
                    FileBrowserView(agentID: agent.id, agentName: agent.name, embedded: false) { path, _ in
                        showBrowser = false
                        // Let the inner sheet finish dismissing before starting the session
                        // and dismissing this sheet — simultaneous dismissals drop transitions.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            start(in: path, agent: agent)
                        }
                    }
                    .environmentObject(relay)
                }
            }
        }
        .onAppear {
            selectedAgentID = preferredAgentID ?? onlineAgents.first?.id
        }
    }

    private var agentSelection: Binding<String> {
        Binding(
            get: { selectedAgent?.id ?? "" },
            set: { selectedAgentID = $0 }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private func projectSection(agent: Agent) -> some View {
        Section("Project") {
            ForEach(sessionManager.recentProjects(for: agent), id: \.self) { path in
                Button {
                    start(in: path, agent: agent)
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                                .foregroundStyle(.primary)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Button {
                showBrowser = true
            } label: {
                Label("Browse folders…", systemImage: "folder")
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            TextField("Name (optional)", text: $customName)
                .autocorrectionDisabled()
        }
    }

    private func startSection(agent: Agent) -> some View {
        Section {
            Button {
                start(in: nil, agent: agent)
            } label: {
                Label("Start Claude in home folder", systemImage: "sparkles")
            }
            Button {
                sessionManager.createSession(for: agent)
                renameIfNeeded()
                dismiss()
            } label: {
                Label("Plain shell", systemImage: "terminal")
            }
        }
    }

    // MARK: - Actions

    private func start(in path: String?, agent: Agent) {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionManager.createChatSession(
            for: agent,
            cwd: path ?? "~",
            name: name.isEmpty ? (path as NSString?)?.lastPathComponent ?? "claude" : name
        )
        dismiss()
    }

    private func renameIfNeeded() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let created = sessionManager.sessions.last else { return }
        sessionManager.rename(created, to: trimmed)
    }

    private func shortName(_ name: String) -> String {
        name.components(separatedBy: ".").first ?? name
    }
}
