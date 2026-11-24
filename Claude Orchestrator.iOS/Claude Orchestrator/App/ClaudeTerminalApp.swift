import SwiftUI
import ClrcCore

@main
struct ClaudeTerminalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // MARK: - Services (shared across the app)
    @StateObject private var authService: AuthService
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager

    init() {
        let url = RelayAddress.startURL()

        let auth = AuthService(relayURL: url)
        let ws = RelayWebSocket(relayURL: url, authService: auth)
        let mgr = SessionManager(relay: ws, store: SessionManager.defaultStore())

        PushManager.shared.configure(relay: ws, auth: auth)
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
