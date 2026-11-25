import Foundation

/// A one-tap reply chip under the chat feed.
public struct QuickReply: Equatable, Sendable, Identifiable {
    public let title: String
    /// What is sent to Claude.
    public let text: String
    /// True for a report question (drawn tinted).
    public let isAnswer: Bool
    public var id: String { title }
}

public enum QuickReplies {
    public static let permanent = ["Продолжай", "Да", "Нет", "Покажи diff", "Запусти тесты", "Закоммить"]
    static let maxTitleLength = 28

    /// The report's questions first, answered by number («1 · …» sends "1"),
    /// then the permanent chips minus any that repeat a question.
    public static func chips(for report: TurnReport?, permanent: [String] = QuickReplies.permanent) -> [QuickReply] {
        let questions = report?.questions ?? []
        let answers = questions.indices.map { index in
            QuickReply(title: capped("\(index + 1) · \(questions[index])"),
                       text: report?.answerDraft(forQuestionAt: index) ?? "",
                       isAnswer: true)
        }
        let asked = Set(questions.map { $0.lowercased() })
        let fixed = permanent
            .filter { !asked.contains($0.lowercased()) }
            .map { QuickReply(title: $0, text: $0, isAnswer: false) }
        return answers + fixed
    }

    private static func capped(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }
}

public enum ShellCommand {
    /// `cd` into `path`, quoted so spaces and quotes stay literal; no path or
    /// `~` means the home folder.
    public static func cd(_ path: String?) -> String {
        guard let path, !path.isEmpty, path != "~" else { return "cd ~" }
        return "cd " + quotedPath(path)
    }

    /// Quotes a path but leaves a leading `~` / `~/` outside the quotes, so
    /// the shell still expands it to the home folder.
    public static func quotedPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quoted(String(path.dropFirst(2))) }
        return quoted(path)
    }

    /// A command-line argument: as is when it has only shell-safe characters,
    /// otherwise single-quoted.
    public static func argument(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./=:@%+-,")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return quoted(text)
    }

    /// Single-quotes `text` for a POSIX shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
