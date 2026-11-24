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
        #if DEBUG
        if let state = DesignPreviewRoot.requestedState {
            DesignPreviewRoot(state: state)
        } else {
            authenticatedOrLogin
        }
        #else
        authenticatedOrLogin
        #endif
    }

    @ViewBuilder
    private var authenticatedOrLogin: some View {
        if authService.isAuthenticated {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}
