import Foundation

/// The agent's `stop_reason` on the synthetic `turn_end` after «Стоп».
let interruptedStopReason = "interrupted"

extension ChatTurn {
    public var endEvent: ChatEvent? { events.last { $0.kind == .turnEnd } }

    /// The user stopped this turn.
    public var wasInterrupted: Bool { endEvent?.stopReason == interruptedStopReason }

    /// The last error reported in this turn.
    public var errorMessage: String? { events.last { $0.kind == .error }?.message }

    /// The error that failed this turn (red card), if any. A turn the user
    /// interrupted, or one with a non-failed report, did not fail: errors
    /// there are stderr noise and show as `noteErrors`.
    public var failureMessage: String? { failureEvent?.message }

    /// Errors shown as small inline notes rather than a failure.
    public var noteErrors: [ChatEvent] {
        let failure = failureEvent?.seq
        return events.filter { $0.kind == .error && $0.seq != failure }
    }

    private var failureEvent: ChatEvent? {
        guard !wasInterrupted else { return nil }
        if let report, report.status != .failed { return nil }
        return events.last { $0.kind == .error }
    }

    /// Claude's text for the turn, as one markdown document.
    public var assistantText: String {
        events.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
    }

    public var toolEvents: [ChatEvent] { events.filter { $0.kind == .toolUse } }

    /// The user already replied after this turn's report, so its questions
    /// are closed (the reply lands at the end of the turn until the next
    /// `turn_start`).
    public var isAnswered: Bool {
        guard let reportSeq = events.last(where: { $0.kind == .report })?.seq else { return false }
        return events.contains { $0.kind == .userText && $0.seq > reportSeq }
    }
}

extension ChatTranscript {
    /// The user's most recent message.
    public var lastUserText: String? {
        turns.reversed().lazy.compactMap { $0.events.last { $0.kind == .userText }?.text }.first
    }

    /// What «Повторить» sends for the error at `errorSeq`: the message that
    /// led to it. nil when that message already completed (a turn end or a
    /// report lies between them) — e.g. a new message failed to start before
    /// it was echoed — so a finished task is never run twice.
    public func retryText(beforeErrorSeq errorSeq: UInt64) -> String? {
        let all = turns.flatMap(\.events)
        guard let message = all.last(where: { $0.kind == .userText && $0.seq < errorSeq }) else { return nil }
        let completedSince = all.contains {
            ($0.kind == .turnEnd || $0.kind == .report) && $0.seq > message.seq && $0.seq < errorSeq
        }
        return completedSince ? nil : message.text
    }
}

/// «$0.42 · 1 мин 12 с» for a report card corner; parts that are zero are
/// left out, nil when both are.
public func turnCostText(costUSD: Double, durationMS: Int) -> String? {
    var parts: [String] = []
    if costUSD > 0 { parts.append(String(format: "$%.2f", costUSD)) }
    if durationMS > 0 { parts.append(durationText(seconds: durationMS / 1_000)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func durationText(seconds: Int) -> String {
    let minutes = seconds / 60
    let rest = seconds % 60
    if minutes == 0 { return "\(rest) с" }
    return rest == 0 ? "\(minutes) мин" : "\(minutes) мин \(rest) с"
}
