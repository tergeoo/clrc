import Foundation

/// A chat session as the Review tab reads it.
public struct ReviewSessionSnapshot: Sendable {
    public let sessionID: String
    public let agentID: String
    public let agentName: String
    public let cwd: String
    public let turns: [ChatTurn]

    public init(sessionID: String, agentID: String, agentName: String, cwd: String, turns: [ChatTurn]) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentName = agentName
        self.cwd = cwd
        self.turns = turns
    }
}

public enum ReviewLabel: Sendable, Equatable {
    /// The newest turn of its session, with questions still open.
    case waiting
    case new
    case viewed
}

/// One Claude turn that changed files («Ревью → От Claude»).
public struct ReviewItem: Identifiable, Sendable, Equatable {
    /// "<session id>:<turn id>", also the key of the viewed set.
    public let id: String
    public let sessionID: String
    public let agentID: String
    public let agentName: String
    public let cwd: String
    public let project: String
    /// 1-based number among the session's real turns (with a `turn_start`).
    public let turnNumber: Int
    public let title: String
    public let files: [String]
    public let label: ReviewLabel
    public let date: Date?
}

public enum ReviewItems {
    /// Turns whose report lists changed files, newest first.
    public static func build(sessions: [ReviewSessionSnapshot], viewed: Set<String>) -> [ReviewItem] {
        var items: [(item: ReviewItem, order: Int)] = []
        for session in sessions {
            let project = session.cwd == "~" ? "~" : (session.cwd as NSString).lastPathComponent
            var turnNumber = 0
            for (index, turn) in session.turns.enumerated() {
                if turn.events.contains(where: { $0.kind == .turnStart }) { turnNumber += 1 }
                guard let report = turn.report, !report.changedFiles.isEmpty else { continue }
                let id = "\(session.sessionID):\(turn.id)"
                let isNewest = index == session.turns.count - 1
                let label: ReviewLabel = isNewest && !report.questions.isEmpty && !turn.isAnswered
                    ? .waiting : viewed.contains(id) ? .viewed : .new
                let item = ReviewItem(id: id, sessionID: session.sessionID, agentID: session.agentID,
                                      agentName: session.agentName, cwd: session.cwd, project: project,
                                      turnNumber: max(turnNumber, 1),
                                      title: report.title.isEmpty ? project : report.title,
                                      files: report.changedFiles, label: label, date: turn.startedAt)
                items.append((item, index))
            }
        }
        return items.sorted {
            let a = $0.item.date ?? .distantPast
            let b = $1.item.date ?? .distantPast
            return a != b ? a > b : $0.order > $1.order
        }.map(\.item)
    }

    /// Project names present, sorted, for the filter chips.
    public static func projects(_ items: [ReviewItem]) -> [String] {
        Array(Set(items.map(\.project))).sorted()
    }

    public static func filter(_ items: [ReviewItem], project: String?) -> [ReviewItem] {
        guard let project else { return items }
        return items.filter { $0.project == project }
    }
}
