import Foundation

/// One collapsed line for a turn's tool calls:
/// «7 действий · Read ×3 · Edit ×2 · Bash ×2».
public struct ToolSummary: Equatable, Sendable {
    static let maxNames = 3

    public let count: Int
    public let text: String
    /// Tool results that came back with `ok == false`.
    public let failed: Int

    /// nil when the events hold no tool call.
    public static func of(_ events: [ChatEvent]) -> ToolSummary? {
        let uses = events.filter { $0.kind == .toolUse }
        guard !uses.isEmpty else { return nil }

        var order: [String] = []
        var counts: [String: Int] = [:]
        for use in uses {
            if counts[use.name] == nil { order.append(use.name) }
            counts[use.name, default: 0] += 1
        }
        // Stable: equal counts keep first-appearance order.
        let ranked = order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map(\.element)

        var parts = [ru(uses.count, one: "действие", few: "действия", many: "действий")]
        parts += ranked.prefix(maxNames).map { name in
            let n = counts[name]!
            return n > 1 ? "\(name) ×\(n)" : name
        }
        if ranked.count > maxNames { parts.append("ещё \(ranked.count - maxNames)") }

        let failed = events.filter { $0.kind == .toolResult && $0.ok == false }.count
        return ToolSummary(count: uses.count, text: parts.joined(separator: " · "), failed: failed)
    }
}
