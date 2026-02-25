import SwiftUI
import Combine

@main
struct ClaudeTerminalApp: App {
    // MARK: - Services (shared across the app)
    @StateObject private var authService: AuthService
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager

    init() {
        // Load saved relay URL, fall back to Info.plist key, then localhost
        let savedURL = UserDefaults.standard.string(forKey: "relay_server_url")
        let plistURL = Bundle.main.object(forInfoDictionaryKey: "RELAY_URL") as? String
        let urlStr = savedURL ?? plistURL ?? "http://localhost:8080"
        let url = URL(string: urlStr) ?? URL(string: "http://localhost:8080")!

        let auth = AuthService(relayURL: url)
        let ws = RelayWebSocket(relayURL: url, authService: auth)
        let mgr = SessionManager(relay: ws)

        _authService = StateObject(wrappedValue: auth)
        _relay = StateObject(wrappedValue: ws)
        _sessionManager = StateObject(wrappedValue: mgr)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(relay)
                .environmentObject(sessionManager)
        }
    }
}

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        if authService.isAuthenticated {
            SessionTabsView()
        } else {
            LoginView()
        }
    }
}

// MARK: - LoginView

struct LoginView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var relay: RelayWebSocket

    @AppStorage("relay_server_url") private var serverURL = "http://localhost:8080"
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server")) {
                    TextField("Relay URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(header: Text("Auth")) {
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        login()
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Sign In")
                            }
                            Spacer()
                        }
                    }
                    .disabled(password.isEmpty || serverURL.isEmpty || isLoading)
                }
            }
            .navigationTitle("Claude Terminal")
        }
    }

    private func login() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        isLoading = true
        errorMessage = nil
        // Apply the (possibly changed) URL before connecting
        authService.updateRelayURL(url)
        relay.updateRelayURL(url)
        Task {
            do {
                try await authService.login(password: password)
                relay.connect()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - SessionManager

/// Manages creation and lifecycle of terminal sessions.
@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []

    private let relay: RelayWebSocket

    init(relay: RelayWebSocket) {
        self.relay = relay

        relay.onSessionReady = { [weak self] sessionID in
            guard let self = self else { return }
            if let session = self.sessions.first(where: { $0.id == sessionID }) {
                session.isReady = true
                if let cmd = session.initialCommand {
                    self.relay.sendInput(sessionID: sessionID, data: Data((cmd + "\n").utf8))
                }
            }
        }

        // After every reconnect, re-register all live sessions with the relay.
        // The agent's PTY processes survive Mac sleep, so reattaching restores the terminal.
        relay.onConnect = { [weak self] in
            guard let self = self else { return }
            for session in self.sessions {
                self.relay.sendConnect(
                    agentID: session.agent.id,
                    sessionID: session.id,
                    cols: session.lastCols,
                    rows: session.lastRows
                )
            }
        }
    }

    func createSession(for agent: Agent, initialCommand: String? = nil) {
        let session = TerminalSession(agent: agent, initialCommand: initialCommand)
        sessions.append(session)
        relay.sendConnect(agentID: agent.id, sessionID: session.id, cols: 80, rows: 24)
    }

    /// Reattach to an existing PTY session on the agent (session_id is already known).
    func attachSession(agentID: String, sessionID: String, agentName: String) {
        // Avoid duplicates — if we already have this session open, just switch to it
        guard !sessions.contains(where: { $0.id == sessionID }) else { return }
        let session = TerminalSession(agentID: agentID, agentName: agentName, sessionID: sessionID)
        sessions.append(session)
        // RemoteTerminalView.makeUIView registers the session handler when the view appears.
        // sendConnect tells the agent to reattach its PTY's sendFn to this client.
        relay.sendConnect(agentID: agentID, sessionID: sessionID, cols: 80, rows: 24)
    }

    func remove(session: TerminalSession) {
        relay.unregisterSessionHandler(sessionID: session.id)
        sessions.removeAll { $0.id == session.id }
    }
}
