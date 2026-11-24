import Foundation

/// What the inbox needs to know about one chat session, read from the live
/// `ChatSession` by the app.
public struct InboxChatSnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    public let agentID: String
    public let agentName: String
    /// Folder name of the session's cwd, as shown on the card.
    public let project: String
    public let status: SessionStatus
    public let report: TurnReport?
    public let currentTool: String?
    public let turnStartedAt: Date?
    /// Time of the latest event, else when the session was created.
    public let updatedAt: Date
    public let agentOnline: Bool

    public init(id: String, name: String, agentID: String, agentName: String, project: String,
                status: SessionStatus, report: TurnReport?, currentTool: String?,
                turnStartedAt: Date?, updatedAt: Date, agentOnline: Bool) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.agentName = agentName
        self.project = project
        self.status = status
        self.report = report
        self.currentTool = currentTool
        self.turnStartedAt = turnStartedAt
        self.updatedAt = updatedAt
        self.agentOnline = agentOnline
    }
}

public struct InboxTerminalSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let agentName: String
    public let isWorking: Bool
    public let agentOnline: Bool

    public init(id: String, name: String, agentName: String, isWorking: Bool, agentOnline: Bool) {
        self.id = id
        self.name = name
        self.agentName = agentName
        self.isWorking = isWorking
        self.agentOnline = agentOnline
    }
}

/// A session whose process is gone («Завершённые»).
public struct InboxEndedSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let agentName: String
    public let projectPath: String?
    /// «Перезапустить» needs the Mac; offline it is shown disabled.
    public let agentOnline: Bool

    public init(id: String, name: String, agentName: String, projectPath: String?, agentOnline: Bool) {
        self.id = id
        self.name = name
        self.agentName = agentName
        self.projectPath = projectPath
        self.agentOnline = agentOnline
    }
}

public struct InboxCard: Sendable, Equatable, Identifiable {
    public static let maxAnswers = 2

    public let snapshot: InboxChatSnapshot
    /// Up to `maxAnswers` report questions, offered as one-tap answers.
    public let answers: [String]
    public let moreAnswers: Bool
    /// «api · mbp-work · 4 файла»; the files part is left out when zero.
    public let meta: String
    /// The report's context check; nil when there is no report yet.
    public let contextOK: Bool?

    public var id: String { snapshot.id }
    /// Report title, else the session name.
    public var title: String {
        let title = snapshot.report?.title ?? ""
        return title.isEmpty ? snapshot.name : title
    }

    init(snapshot: InboxChatSnapshot) {
        self.snapshot = snapshot
        let questions = snapshot.report?.questions ?? []
        answers = Array(questions.prefix(Self.maxAnswers))
        moreAnswers = questions.count > Self.maxAnswers
        contextOK = snapshot.report?.contextOK

        var parts = [snapshot.project, snapshot.agentName]
        let files = snapshot.report?.changedFiles.count ?? 0
        if files > 0 { parts.append(ru(files, one: "файл", few: "файла", many: "файлов")) }
        meta = parts.joined(separator: " · ")
    }
}

public struct InboxSections: Sendable, Equatable {
    /// needs_input and failed, newest first.
    public let waiting: [InboxCard]
    /// Running turns (and answers waiting out their undo), oldest turn first.
    public let working: [InboxCard]
    /// done and idle, newest first.
    public let done: [InboxCard]
    public let terminals: [InboxTerminalSnapshot]
    public let ended: [InboxEndedSnapshot]

    public init(waiting: [InboxCard] = [], working: [InboxCard] = [], done: [InboxCard] = [],
                terminals: [InboxTerminalSnapshot] = [], ended: [InboxEndedSnapshot] = []) {
        self.waiting = waiting
        self.working = working
        self.done = done
        self.terminals = terminals
        self.ended = ended
    }

    public var isEmpty: Bool {
        waiting.isEmpty && working.isEmpty && done.isEmpty && terminals.isEmpty && ended.isEmpty
    }

    /// «2 ждут вас · 2 работают · 1 готово», zero parts left out.
    public var summaryLine: String {
        var parts: [String] = []
        if !waiting.isEmpty {
            parts.append("\(waiting.count) " + ruForm(waiting.count, one: "ждёт вас", few: "ждут вас", many: "ждут вас"))
        }
        if !working.isEmpty {
            parts.append("\(working.count) " + ruForm(working.count, one: "работает", few: "работают", many: "работают"))
        }
        if !done.isEmpty { parts.append("\(done.count) готово") }
        return parts.isEmpty ? "Всё спокойно" : parts.joined(separator: " · ")
    }
}

public enum InboxBuilder {
    /// Groups sessions by urgency. A session with an answer waiting out its
    /// undo window counts as working: the user already acted on it.
    public static func build(chats: [InboxChatSnapshot], terminals: [InboxTerminalSnapshot],
                             ended: [InboxEndedSnapshot], pendingAnswerIDs: Set<String>) -> InboxSections {
        var waiting: [InboxCard] = []
        var working: [InboxCard] = []
        var done: [InboxCard] = []

        for snapshot in chats {
            let card = InboxCard(snapshot: snapshot)
            if pendingAnswerIDs.contains(snapshot.id) || snapshot.status == .working {
                working.append(card)
            } else if snapshot.status.needsUser {
                waiting.append(card)
            } else {
                done.append(card)
            }
        }

        let newestFirst: (InboxCard, InboxCard) -> Bool = { $0.snapshot.updatedAt > $1.snapshot.updatedAt }
        let oldestTurnFirst: (InboxCard, InboxCard) -> Bool = {
            ($0.snapshot.turnStartedAt ?? $0.snapshot.updatedAt) < ($1.snapshot.turnStartedAt ?? $1.snapshot.updatedAt)
        }
        return InboxSections(waiting: waiting.sorted(by: newestFirst),
                             working: working.sorted(by: oldestTurnFirst),
                             done: done.sorted(by: newestFirst),
                             terminals: terminals, ended: ended)
    }

    /// The connection pill next to the title.
    public static func connectionPill(relayConnected: Bool, onlineMacs: Int) -> String {
        guard relayConnected else { return "нет связи" }
        guard onlineMacs > 0 else { return "нет Маков" }
        return ru(onlineMacs, one: "Мак", few: "Мака", many: "Маков")
    }
}
