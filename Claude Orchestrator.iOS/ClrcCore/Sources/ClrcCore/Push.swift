import Foundation

public struct PushAction: Equatable, Sendable {
    public let id: String
    public let title: String
}

public struct PushCategory: Equatable, Sendable {
    public let id: String
    public let answerActions: [PushAction]
}

/// Notification categories matching the relay's `CLRC_Q<n>` (n questions,
/// at most 3): one «Вариант N» action per question plus a text reply.
public enum PushCategories {
    public static let maxQuestions = 3
    public static let textReplyID = "reply_text"
    static let answerPrefix = "answer_"

    public static let all: [PushCategory] = (0...maxQuestions).map { count in
        PushCategory(id: "CLRC_Q\(count)",
                     answerActions: (0..<count).map { PushAction(id: "\(answerPrefix)\($0 + 1)", title: "Вариант \($0 + 1)") })
    }

    /// What a tapped action sends: the question number, or the typed text;
    /// nil for a plain tap (open the app) or an unknown action.
    public static func answer(actionID: String, typedText: String?) -> String? {
        if actionID == textReplyID {
            let text = (typedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard actionID.hasPrefix(answerPrefix), let n = Int(actionID.dropFirst(answerPrefix.count)),
              (1...maxQuestions).contains(n) else { return nil }
        return String(n)
    }
}

/// The chat a push is about.
public struct PushTarget: Equatable, Sendable {
    public let agentID: String
    public let sessionID: String

    public init(agentID: String, sessionID: String) {
        self.agentID = agentID
        self.sessionID = sessionID
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let agent = userInfo["agent_id"] as? String, let session = userInfo["session_id"] as? String,
              !agent.isEmpty, !session.isEmpty else { return nil }
        self.init(agentID: agent, sessionID: session)
    }
}

/// Which report statuses notify this device (Settings → Уведомления).
public enum PushNotify {
    public static let storageKey = "notify_statuses"
    public static let allStatuses = ["needs_input", "failed", "done"]
    static let noneMarker = "none"

    public static func decode(_ raw: String?) -> [String] {
        guard let raw else { return allStatuses }
        if raw == noneMarker { return [] }
        let chosen = Set(raw.split(separator: ",").map(String.init))
        return allStatuses.filter(chosen.contains)
    }

    public static func encode(_ statuses: [String]) -> String {
        statuses.isEmpty ? noneMarker : statuses.joined(separator: ",")
    }

    /// APNs device token as the relay expects it (lowercase hex).
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
