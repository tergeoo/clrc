import SwiftUI
import ClrcCore

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
        let mgr = SessionManager(relay: ws, store: SessionManager.defaultStore())

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
    @State private var showScanner = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server")) {
                    TextField("Relay URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                    }
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
            .sheet(isPresented: $showScanner) {
                ScanToPairView { info in
                    serverURL = info.relay
                    password = info.password
                }
            }
        }
    }

    private func login() {
        guard let url = URL(string: serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }

        isLoading = true
        errorMessage = nil
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

