import SwiftUI
import ClrcCore

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("relay_server_url") private var relayURLString = "http://localhost:8080"
    @AppStorage(ChatDisplayMode.storageKey) private var chatDisplayMode: ChatDisplayMode = .chat
    @AppStorage(ChatDisplayMode.profileStorageKey) private var claudeProfile = ""
    @State private var showCloseAllConfirm = false

    /// Explains the profile field, and flags a value the agent would reject.
    private var profileFooter: String {
        let trimmed = claudeProfile.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, normalizedProfile(trimmed) == nil {
            return "Use lowercase letters, digits and dashes. This value is ignored."
        }
        return "Applies to new chat sessions. Empty uses the Mac's default (CLRC_PROFILE). "
            + "Brief shows the result card first."
    }

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Connection
                Section("Connection") {
                    TextField("Relay URL", text: $relayURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if relay.connectionState != .connected {
                            Button("Reconnect") {
                                applyURLAndReconnect()
                            }
                            .font(.callout)
                        }
                    }
                }

                // MARK: - Chat
                Section {
                    Picker("Display", selection: $chatDisplayMode) {
                        Text("Chat").tag(ChatDisplayMode.chat)
                        Text("Brief").tag(ChatDisplayMode.brief)
                    }
                    TextField("Claude profile (optional)", text: $claudeProfile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Chat")
                } footer: {
                    Text(profileFooter)
                }

                // MARK: - Sessions
                Section("Sessions") {
                    HStack {
                        Text("Open sessions")
                        Spacer()
                        Text("\(sessionManager.sessions.count)")
                            .foregroundStyle(.secondary)
                    }
                    if !sessionManager.sessions.isEmpty {
                        Button("Close All Sessions", role: .destructive) {
                            showCloseAllConfirm = true
                        }
                    }
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("v2.0")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Account
                Section {
                    Button("Logout", role: .destructive) {
                        dismiss()
                        authService.logout()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Close all \(sessionManager.sessions.count) session(s)?",
                isPresented: $showCloseAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Close All", role: .destructive) {
                    sessionManager.closeAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch relay.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch relay.connectionState {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }

    private func applyURLAndReconnect() {
        guard let url = URL(string: relayURLString) else { return }
        relay.updateRelayURL(url)
        if relay.connectionState == .disconnected {
            relay.connect()
        }
    }
}
