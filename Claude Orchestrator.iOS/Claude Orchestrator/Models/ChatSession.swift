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
    /// When this app instance created or restored the session; the Inbox's
    /// "updated" time until the first event arrives.
    let createdAt = Date()

    @Published var customName: String
    @Published var transcript = ChatTranscript()
    @Published var isWorking = false
    @Published var lastError: String?

    /// True while a gap-triggered `requestChatHistory` is in flight for this
    /// session. Guards against firing a second replay request for every
    /// gapped event in a burst; cleared on both the real reply and the
    /// 5-second timeout.
    var isReplaying = false

    /// Highest `seq` of a live event that arrived (and was dropped as a gap)
    /// while a replay was already in flight. `SessionManager` checks this
    /// once the in-flight replay completes and, if it is still ahead of
    /// `transcript.lastSeq`, issues one more replay — otherwise a live event
    /// dropped mid-replay (e.g. the `turn_end` that would clear `isWorking`)
    /// is only ever recovered by luck, when some later event happens to
    /// trigger another gap check.
    var highWaterSeqDuringReplay: UInt64 = 0

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
    /// `apply(history:)` — including its effect on `isWorking`/`lastError`,
    /// via the same `updateState` walk used here. The caller re-requests
    /// the tail rather than rendering a transcript with holes in it.
    func receive(_ event: ChatEvent) -> Bool {
        let hadGap = transcript.hasGap(before: event.seq)
        guard !hadGap else { return true }

        transcript = transcript.applying([event])
        updateState(from: [event])
        return false
    }

    /// Folds a replayed batch into the transcript. Also re-derives
    /// `isWorking`/`lastError` from the same batch — a gapped event that
    /// carried a `turnEnd` or `.error` was withheld from `receive` and only
    /// ever reaches session state through this path, so it must run the
    /// same state walk as the live path or the spinner/error banner would
    /// never update for anything that arrived via replay.
    func apply(history events: [ChatEvent]) {
        transcript = transcript.applying(events)
        updateState(from: events)
    }

    /// Discards the transcript and its derived UI state entirely. Called by
    /// `SessionManager` when a chat-history reply reveals the agent's
    /// buffer has reset (`ChatTranscript.isBehindBufferReset`, e.g. after an
    /// agent restart) — our accumulated `lastSeq` belongs to a buffer that
    /// no longer exists, so nothing about the old transcript or the
    /// spinner/error state derived from it can be trusted going forward
    /// either. The caller re-requests the tail from scratch immediately
    /// after calling this.
    func resetTranscript() {
        transcript = ChatTranscript()
        isWorking = false
        lastError = nil
    }

    /// Derives `isWorking`/`lastError` from `events` via `ChatStateDeriver`
    /// (pure logic, tested in `ClrcCore`), folded onto the session's current
    /// state. Order within `events` doesn't matter — the deriver sorts by
    /// `seq` itself — which matters for a multi-event replay batch: the last
    /// `turnStart`/`turnEnd` in the backlog wins for `isWorking`, e.g. a
    /// batch containing `turnStart, ..., turnEnd` must leave `isWorking`
    /// false, while a batch containing only `turnStart` (Claude still
    /// mid-turn when the replay was requested) must leave it true.
    private func updateState(from events: [ChatEvent]) {
        let state = ChatStateDeriver.deriving(events, from: ChatSessionState(isWorking: isWorking, lastError: lastError))
        isWorking = state.isWorking
        lastError = state.lastError
    }
}
