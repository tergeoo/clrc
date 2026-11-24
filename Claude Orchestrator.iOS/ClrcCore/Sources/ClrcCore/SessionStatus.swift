import Foundation

/// The one status every screen shows for a session (inbox card, chat header,
/// push). Colors live in the app; this type owns the decision and the words.
public enum SessionStatus: String, Sendable, CaseIterable {
    case needsInput
    case failed
    case working
    case done
    case idle

    /// A live turn wins over everything: the last report belongs to the
    /// previous turn. A sticky error wins over that report; otherwise the
    /// report decides, and no report means nothing is known yet.
    public static func derive(isWorking: Bool, lastError: String?, report: TurnReport?) -> SessionStatus {
        if isWorking { return .working }
        if lastError != nil { return .failed }
        switch report?.status {
        case .needsInput: return .needsInput
        case .failed: return .failed
        case .done: return .done
        case .inProgress: return .working
        case .unknown, .none: return .idle
        }
    }

    public var label: String {
        switch self {
        case .needsInput: return "ждёт ответа"
        case .failed: return "ошибка"
        case .working: return "работает"
        case .done: return "готово"
        case .idle: return "нет данных"
        }
    }

    /// The glyph inside the status circle; `working` draws a ring instead.
    public var glyph: String {
        switch self {
        case .needsInput: return "?"
        case .failed: return "!"
        case .working: return ""
        case .done: return "✓"
        case .idle: return "–"
        }
    }

    /// True for the statuses that wait on the user («Ждёт вас»).
    public var needsUser: Bool {
        self == .needsInput || self == .failed
    }

    /// VoiceOver text, e.g. «Сессия api: ждёт ответа, 2 вопроса».
    public static func accessibilityLabel(session: String, status: SessionStatus, questionCount: Int) -> String {
        let base = "Сессия \(session): \(status.label)"
        guard questionCount > 0 else { return base }
        return base + ", " + ru(questionCount, one: "вопрос", few: "вопроса", many: "вопросов")
    }
}
