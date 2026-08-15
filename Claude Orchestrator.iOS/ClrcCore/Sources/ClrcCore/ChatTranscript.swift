import Foundation

/// One turn: everything from a `turn_start` up to the next one.
public struct ChatTurn: Sendable, Identifiable, Equatable {
    public let id: UInt64
    public let events: [ChatEvent]

    public init(id: UInt64, events: [ChatEvent]) {
        self.id = id
        self.events = events
    }

    fileprivate func appending(_ event: ChatEvent) -> ChatTurn {
        ChatTurn(id: id, events: events + [event])
    }
}

/// Accumulated view of a chat session. Immutable: `applying` returns a new
/// transcript rather than mutating in place, so a stale copy can never be
/// observed mid-update.
public struct ChatTranscript: Sendable, Equatable {
    public let turns: [ChatTurn]
    public let lastSeq: UInt64

    public init(turns: [ChatTurn] = [], lastSeq: UInt64 = 0) {
        self.turns = turns
        self.lastSeq = lastSeq
    }

    /// Returns a transcript with `events` applied. Events at or below
    /// `lastSeq` are dropped, which makes duplicate delivery and out-of-order
    /// arrival both harmless.
    public func applying(_ events: [ChatEvent]) -> ChatTranscript {
        var turns = self.turns
        var lastSeq = self.lastSeq

        for event in events.sorted(by: { $0.seq < $1.seq }) where event.seq > lastSeq {
            lastSeq = event.seq

            if event.kind == .turnStart || turns.isEmpty {
                turns.append(ChatTurn(id: event.seq, events: [event]))
            } else {
                turns[turns.count - 1] = turns[turns.count - 1].appending(event)
            }
        }

        return ChatTranscript(turns: turns, lastSeq: lastSeq)
    }

    /// True when `seq` is further ahead than the next expected event, meaning
    /// something was missed and the tail should be re-requested.
    public func hasGap(before seq: UInt64) -> Bool {
        seq > lastSeq + 1
    }

    /// True when a history reply's `next_seq` is *behind* this transcript's
    /// `lastSeq` — the signal that the agent's in-memory seq counter has
    /// gone backwards, not that anything was merely missed. `seq` is
    /// strictly monotonic for the life of one agent process (`ChatBuffer`
    /// never rewinds it), so the only way a reply can report a high-water
    /// mark lower than what we already applied is that the buffer itself is
    /// new — e.g. the agent restarted (a reboot, or `clrc restart`) and
    /// started counting again from 1. Continuing to compare future replies
    /// and live events against the old, now-stale `lastSeq` would make
    /// every one of them look "already seen" and silently drop them
    /// forever, freezing the tab with no error. The caller must discard the
    /// transcript and rebuild it from this new counter instead.
    public func isBehindBufferReset(replyNextSeq: UInt64) -> Bool {
        replyNextSeq < lastSeq
    }
}
