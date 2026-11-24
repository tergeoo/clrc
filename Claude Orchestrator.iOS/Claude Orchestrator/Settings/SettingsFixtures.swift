#if DEBUG
import SwiftUI

/// `-designPreview settings`.
struct SettingsPreviewHost: View {
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager
    @StateObject private var auth = AuthService(relayURL: URL(string: "http://127.0.0.1:9")!)

    init() {
        let (relay, manager) = PreviewEnvironment.make(agents: PreviewEnvironment.macs)
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        SettingsScreen()
            .environmentObject(relay)
            .environmentObject(sessionManager)
            .environmentObject(auth)
    }
}
#endif
