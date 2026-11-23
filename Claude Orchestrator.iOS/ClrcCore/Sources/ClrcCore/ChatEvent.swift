import Foundation

/// Normalised event kinds sent by the agent. `unknown` is the forward-
/// compatibility escape hatch: a newer agent must never break an older app,
/// and the App Store makes the app the slowest component to update.
public enum ChatEventKind: String, Codable, Sendable {
    case turnStart = "turn_start"
    case text
    case userText = "user_text"
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case turnEnd = "turn_end"
    case error
    /// Structured turn summary; carries `ChatEvent.report`.
    case report
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatEventKind(rawValue: raw) ?? .unknown
    }
}

/// One event in a chat session. `seq` is assigned by the agent and is what
/// makes reconnection correct — the client replays only what it is missing.
public struct ChatEvent: Codable, Sendable, Identifiable, Equatable {
    public let kind: ChatEventKind
    public let seq: UInt64
    public let ts: String

    public let text: String
    public let toolID: String
    public let name: String
    public let input: String
    public let output: String
    public let ok: Bool?
    public let truncated: Bool

    public let numTurns: Int
    public let costUSD: Double
    public let durationMS: Int
    public let stopReason: String
    public let message: String
    /// Set only on `.report` events.
    public let report: TurnReport?

    public var id: UInt64 { seq }

    enum CodingKeys: String, CodingKey {
        case kind, seq, ts, text, name, input, output, ok, truncated, message, report
        case toolID = "tool_id"
        case numTurns = "num_turns"
        case costUSD = "cost_usd"
        case durationMS = "duration_ms"
        case stopReason = "stop_reason"
    }

    public init(
        kind: ChatEventKind, seq: UInt64, ts: String,
        text: String = "", toolID: String = "", name: String = "",
        input: String = "", output: String = "", ok: Bool? = nil,
        truncated: Bool = false, numTurns: Int = 0, costUSD: Double = 0,
        durationMS: Int = 0, stopReason: String = "", message: String = "",
        report: TurnReport? = nil
    ) {
        self.kind = kind
        self.seq = seq
        self.ts = ts
        self.text = text
        self.toolID = toolID
        self.name = name
        self.input = input
        self.output = output
        self.ok = ok
        self.truncated = truncated
        self.numTurns = numTurns
        self.costUSD = costUSD
        self.durationMS = durationMS
        self.stopReason = stopReason
        self.message = message
        self.report = report
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ChatEventKind.self, forKey: .kind)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolID = try c.decodeIfPresent(String.self, forKey: .toolID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        numTurns = try c.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        durationMS = try c.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        // A report this app cannot read must not cost it the whole event.
        report = try? c.decodeIfPresent(TurnReport.self, forKey: .report)
    }
}
