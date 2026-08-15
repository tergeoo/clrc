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

    /// True while a gap-triggered `requestChatHistory` is in flight for this
    /// session. Guards against firing a second replay request for every
    /// gapped event in a burst; cleared on both the real reply and the
    /// 5-second timeout.
    var isReplaying = false

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
    /// was backgrounded. In that case the event is deliberately **not**
    /// applied: `ChatTranscript.applying` drops anything at or below
    /// `lastSeq`, so if this gapped event were applied now it would advance
    /// `lastSeq` past the hole and the replay that follows would arrive
    /// too late to backfill it — the missing events would be silently
    /// dropped on the way in. Leaving `lastSeq` where it was keeps it a
    /// correct lower bound for the replay request; the event itself comes
    /// back as part of that replay and is applied then, in order, by
    /// `apply(history:)`. The caller re-requests the tail rather than
    /// rendering a transcript with holes in it.
    func receive(_ event: ChatEvent) -> Bool {
        let hadGap = transcript.hasGap(before: event.seq)
        guard !hadGap else { return true }

        transcript = transcript.applying([event])

        switch event.kind {
        case .turnStart: isWorking = true
        case .turnEnd:   isWorking = false
        case .error:     lastError = event.message
        default:         break
        }
        return false
    }

    func apply(history events: [ChatEvent]) {
        transcript = transcript.applying(events)
    }
}
