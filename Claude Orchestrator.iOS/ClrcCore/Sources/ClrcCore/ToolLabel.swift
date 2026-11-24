import Foundation

/// Short human labels for `tool_use` events, e.g. «Edit src/routes/login.tsx»
/// or «Bash: make test», shown on working sessions in the inbox.
public enum ToolLabel {
    static let maxLength = 60
    static let pathComponentsKept = 3

    private static let fileTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// The label for one tool call. `input` is the tool's JSON object as the
    /// agent sent it, possibly truncated; anything unreadable yields `name`.
    public static func label(name: String, input: String) -> String {
        guard let detail = detail(name: name, input: input), !detail.isEmpty else { return name }
        return capped(name == "Bash" ? "Bash: \(detail)" : "\(name) \(detail)")
    }

    /// SF Symbol for a tool.
    public static func symbol(for name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private static func detail(name: String, input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        switch name {
        case "Bash":
            return (object["command"] as? String)?
                .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        case _ where fileTools.contains(name):
            let path = (object["file_path"] as? String) ?? (object["notebook_path"] as? String)
            return path.map(shortPath)
        case "Grep", "Glob":
            return object["pattern"] as? String
        case "WebFetch":
            return object["url"] as? String
        case "WebSearch":
            return object["query"] as? String
        default:
            return nil
        }
    }

    private static func shortPath(_ path: String) -> String {
        path.split(separator: "/").suffix(pathComponentsKept).joined(separator: "/")
    }

    private static func capped(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}

extension ChatTurn {
    /// Label of the last tool call while the turn is still open; nil once
    /// the turn has ended or before any tool ran.
    public var currentTool: String? {
        guard !events.contains(where: { $0.kind == .turnEnd }),
              let tool = events.last(where: { $0.kind == .toolUse })
        else { return nil }
        return ToolLabel.label(name: tool.name, input: tool.input)
    }

    /// When the turn started, from its `turn_start` timestamp.
    public var startedAt: Date? {
        guard let start = events.first(where: { $0.kind == .turnStart }) else { return nil }
        return parseEventTimestamp(start.ts)
    }
}

/// Parses an event `ts` (RFC 3339, with or without fractional seconds).
public func parseEventTimestamp(_ ts: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: ts) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: ts)
}
