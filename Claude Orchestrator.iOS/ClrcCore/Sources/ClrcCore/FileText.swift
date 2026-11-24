import Foundation

/// A previewed file as the agent sent it (`fs_read`, capped at 100 KB).
public struct FileText: Equatable, Sendable {
    /// The agent's read cap (`maxReadBytes` in agent/fs_ops.go). A reply of
    /// exactly this size was most likely cut.
    public static let agentReadLimit = 100 * 1024

    public let text: String
    public let truncated: Bool

    /// Decodes leniently: a cut can split a multi-byte character, and a
    /// strict decoder would then reject the whole file. The replacement
    /// character such a cut leaves at the very end is dropped.
    public init(data: Data) {
        var text = String(decoding: data, as: UTF8.self)
        truncated = data.count >= Self.agentReadLimit
        if truncated {
            while text.hasSuffix("\u{FFFD}") { text.removeLast() }
        }
        self.text = text
    }

    public var lines: [String] { text.components(separatedBy: "\n") }

    /// 0-based indices of lines containing `query`, ignoring case.
    public func matchingLines(_ query: String) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return lines.indices.filter { matchesQuery(lines[$0], query) }
    }

    public static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }
}
