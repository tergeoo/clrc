import Foundation
import Combine
import ClrcCore

/// One headless `claude` conversation on a Mac agent. Deliberately separate
/// from TerminalSession: that type owns a SwiftTerm view and ANSI parsing,
/// none of which applies here.
@MainActor
final class ChatSession: ObservableObject, Identifiable, Equatable {
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool { lhs.id == rhs.id }

    let id: String
    let agent: Agent
    let cwd: String

    @Published var customName: String
    @Published var transcript = ChatTranscript()
    @Published var isWorking = false
    @Published var lastError: String?

    init(agent: Agent, cwd: String, customName: String) {
        self.id = UUID().uuidString.lowercased()
        self.agent = agent
        self.cwd = cwd
        self.customName = customName
    }

    init(agentID: String, agentName: String, sessionID: String, cwd: String, customName: String) {
        self.id = sessionID
        self.agent = Agent(id: agentID, name: agentName, connected: true)
        self.cwd = cwd
        self.customName = customName
    }

    /// Applies one live event. A gap means events were missed while the app
    /// was backgrounded — the caller re-requests the tail rather than
    /// rendering a transcript with holes in it.
    func receive(_ event: ChatEvent) -> Bool {
        let hadGap = transcript.hasGap(before: event.seq)
        transcript = transcript.applying([event])

        switch event.kind {
        case .turnStart: isWorking = true
        case .turnEnd:   isWorking = false
        case .error:     lastError = event.message
        default:         break
        }
        return hadGap
    }

    func apply(history events: [ChatEvent]) {
        transcript = transcript.applying(events)
    }
}
