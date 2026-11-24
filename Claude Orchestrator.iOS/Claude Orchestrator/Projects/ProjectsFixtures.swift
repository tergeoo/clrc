#if DEBUG
import SwiftUI
import ClrcCore

/// `-designPreview projects|macprojects|project`.
struct ProjectsPreviewHost: View {
    let state: String
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager

    static let states: Set<String> = ["projects", "macprojects", "project"]

    init(state: String) {
        self.state = state
        let macs = state == "projects" ? PreviewEnvironment.macs : [PreviewEnvironment.macs[0]]
        let (relay, manager) = PreviewEnvironment.make(agents: macs, recents: PreviewEnvironment.recents)
        manager.createChatSession(for: macs[0], cwd: "/Users/g/startups/api", name: "api")
        manager.openTerminal(in: "/Users/g/startups/api", agentID: "mbp")
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        Group {
            if state == "project" {
                NavigationStack { ProjectView(agentID: "mbp", path: "/Users/g/startups/api") }
            } else {
                ProjectsView()
            }
        }
        .environmentObject(relay)
        .environmentObject(sessionManager)
    }
}
#endif
