#if DEBUG
import SwiftUI

/// `-designPreview onboarding|onboardingmanual|onboardingerror|onboardingoffline`.
struct OnboardingPreviewHost: View {
    let state: String
    @StateObject private var auth = AuthService(relayURL: URL(string: "http://127.0.0.1:9")!)
    @StateObject private var relay: RelayWebSocket

    init(state: String) {
        self.state = state
        let (relay, _) = PreviewEnvironment.make(agents: [])
        _relay = StateObject(wrappedValue: relay)
    }

    var body: some View {
        OnboardingView(step: state == "onboarding" ? .start : .manual,
                       problem: state == "onboardingerror" ? .wrongPassword
                           : state == "onboardingoffline" ? .unreachable : nil)
            .environmentObject(auth)
            .environmentObject(relay)
    }
}
#endif
