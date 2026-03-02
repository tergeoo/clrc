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
    private var sessionCounter = 0

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
        sessionCounter += 1
        let name = autoName(for: initialCommand, index: sessionCounter)
        let session = TerminalSession(agent: agent, customName: name, initialCommand: initialCommand)
        sessions.append(session)
        relay.sendConnect(agentID: agent.id, sessionID: session.id, cols: 80, rows: 24)
    }

    /// Reattach to an existing PTY session on the agent (session_id is already known).
    func attachSession(agentID: String, sessionID: String, agentName: String) {
        guard !sessions.contains(where: { $0.id == sessionID }) else { return }
        sessionCounter += 1
        let session = TerminalSession(
            agentID: agentID,
            agentName: agentName,
            sessionID: sessionID,
            customName: "Session \(sessionCounter)"
        )
        sessions.append(session)
        relay.sendConnect(agentID: agentID, sessionID: sessionID, cols: 80, rows: 24)
    }

    func remove(session: TerminalSession) {
        relay.unregisterSessionHandler(sessionID: session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() {
        for session in sessions {
            relay.sendDisconnect(sessionID: session.id)
            relay.unregisterSessionHandler(sessionID: session.id)
        }
        sessions.removeAll()
    }

    // MARK: - Auto-naming

    private func autoName(for command: String?, index: Int) -> String {
        guard let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmd.isEmpty else {
            return "Session \(index)"
        }
        let dangerous = cmd.contains("--dangerously-skip-permissions")
        let warning = dangerous ? " ⚠" : ""

        // "cd ~/path && claude" → extract directory name
        if let dir = extractLastDir(from: cmd) {
            return dir + warning
        }
        // Generic claude launch
        if cmd.contains("claude") {
            return dangerous ? "Claude ⚠" : "Claude \(index)"
        }
        return "Session \(index)"
    }

    private func extractLastDir(from cmd: String) -> String? {
        // Match: cd "/some/path" && or cd ~/path && (with optional quotes)
        let pattern = #"cd\s+["']?([^"'&\r\n]+?)["']?\s*&&"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let range = Range(match.range(at: 1), in: cmd) else { return nil }
        let path = String(cmd[range]).trimmingCharacters(in: .whitespaces)
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }
}
