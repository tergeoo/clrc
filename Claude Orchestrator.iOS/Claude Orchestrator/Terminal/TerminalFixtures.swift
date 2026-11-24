#if DEBUG
import SwiftUI
import SwiftTerm
import ClrcCore

/// `-designPreview terminal|terminalreconnect|terminalended`.
struct TerminalPreviewHost: View {
    let state: String
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager
    private let session: TerminalSession

    static let states: Set<String> = ["terminal", "terminalreconnect", "terminalended"]

    init(state: String) {
        self.state = state
        let mac = Agent(id: "mbp", name: "mbp-work", connected: state != "terminalreconnect")
        let (relay, manager) = PreviewEnvironment.make(agents: [mac])
        let session = TerminalSession(agent: mac, customName: "zsh", initialCommand: ShellCommand.cd("/Users/g/dev/clrc"))
        if state == "terminalended" {
            manager.tombstones = [PersistedSession(id: session.id, agentID: "mbp", agentName: "mbp-work",
                                                   customName: "zsh", projectPath: "/Users/g/dev/clrc")]
        } else {
            manager.sessions = [session]
        }
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
        self.session = session
    }

    var body: some View {
        NavigationStack {
            SessionScreen(route: .terminal(id: session.id))
        }
        .environmentObject(relay)
        .environmentObject(sessionManager)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            session.terminalView?.feed(text: Self.sample)
        }
    }

    private static let sample = [
        "\u{1B}[36m~/dev/clrc\u{1B}[0m \u{1B}[90m(feat/structured-output)\u{1B}[0m $ git status",
        "On branch feat/structured-output",
        "Changes not staged for commit:",
        "  \u{1B}[31mmodified:   agent/report.go\u{1B}[0m",
        "  \u{1B}[31mmodified:   ios/Chat/ChatReportViews.swift\u{1B}[0m",
        "",
        "\u{1B}[36m~/dev/clrc\u{1B}[0m $ make test",
        "go test ./...",
        "\u{1B}[32mok\u{1B}[0m   clrc/agent      2.114s",
        "\u{1B}[32mok\u{1B}[0m   clrc/relay      0.882s",
        "\u{1B}[31mFAIL\u{1B}[0m clrc/protocol   0.341s",
        "\u{1B}[36m~/dev/clrc\u{1B}[0m $ ",
    ].joined(separator: "\r\n")
}
#endif
