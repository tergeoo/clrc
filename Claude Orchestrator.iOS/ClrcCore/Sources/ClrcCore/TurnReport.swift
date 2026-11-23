import Foundation

/// Status of a finished turn, as reported by the agent. `unknown` keeps an
/// older app working when a newer agent invents a status.
public enum TurnReportStatus: String, Codable, Sendable {
    case done
    case needsInput = "needs_input"
    case failed
    case inProgress = "in_progress"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnReportStatus(rawValue: raw) ?? .unknown
    }
}

/// Structured summary of one turn, carried by a `report` event right before
/// the turn's `turn_end`. Built by the agent from the model's `clrc-report`
/// block, or as a fallback when the block was missing or malformed
/// (`source == "fallback"`). Every field is optional on the wire and unknown
/// fields are ignored.
public struct TurnReport: Codable, Sendable, Equatable {
    public let v: Int
    public let status: TurnReportStatus
    public let title: String
    public let summary: String
    public let questions: [String]
    public let nextSteps: [String]
    public let changedFiles: [String]
    /// The style's context header line without the bold markers, e.g.
    /// "tergeo · personal"; empty when the reply had none.
    public let header: String
    /// True when the header was present (and matched the agent's expected
    /// prefix, if one is configured).
    public let contextOK: Bool
    public let source: String

    enum CodingKeys: String, CodingKey {
        case v, status, title, summary, questions, header, source
        case nextSteps = "next_steps"
        case changedFiles = "changed_files"
        case contextOK = "context_ok"
    }

    public init(
        v: Int = 1, status: TurnReportStatus, title: String = "", summary: String = "",
        questions: [String] = [], nextSteps: [String] = [], changedFiles: [String] = [],
        header: String = "", contextOK: Bool = false, source: String = ""
    ) {
        self.v = v
        self.status = status
        self.title = title
        self.summary = summary
        self.questions = questions
        self.nextSteps = nextSteps
        self.changedFiles = changedFiles
        self.header = header
        self.contextOK = contextOK
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        status = try c.decodeIfPresent(TurnReportStatus.self, forKey: .status) ?? .unknown
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        changedFiles = try c.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        header = try c.decodeIfPresent(String.self, forKey: .header) ?? ""
        contextOK = try c.decodeIfPresent(Bool.self, forKey: .contextOK) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }

    /// The composer text for answering question `index`. The clrc styles
    /// number their questions, so the 1-based number is the answer. An index
    /// outside the list yields an empty draft.
    public func answerDraft(forQuestionAt index: Int) -> String {
        guard questions.indices.contains(index) else { return "" }
        return String(index + 1)
    }
}
