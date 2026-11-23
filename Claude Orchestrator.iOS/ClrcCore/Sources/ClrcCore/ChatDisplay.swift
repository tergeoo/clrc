import Foundation

/// How the chat screen presents a turn, chosen by the user in Settings.
/// Each mode asks the agent for the matching output style.
public enum ChatDisplayMode: String, CaseIterable, Sendable, Identifiable {
    /// Bubbles first, the report card at the end of the turn.
    case chat
    /// The report card first, the text collapsed under "Details".
    case brief

    public var id: String { rawValue }

    /// The `style` sent in the chat `connect` payload.
    public var outputStyle: String {
        switch self {
        case .chat: return "clrc-chat"
        case .brief: return "clrc-brief"
        }
    }

    /// The `UserDefaults` / `@AppStorage` key for the selected mode.
    public static let storageKey = "chat_display_mode"
    /// The `UserDefaults` / `@AppStorage` key for the optional Claude profile.
    public static let profileStorageKey = "claude_profile"

    /// Reads the stored mode, defaulting to `.chat` for missing or unknown values.
    public static func stored(in defaults: UserDefaults) -> ChatDisplayMode {
        ChatDisplayMode(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .chat
    }
}

/// Validates a profile name the same way the agent does (`^[a-z0-9-]+$`),
/// so the app never sends a value the agent would reject. Returns nil for an
/// empty or invalid name, meaning "use the agent default".
public func normalizedProfile(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    return trimmed.allSatisfy { allowed.contains($0) } ? trimmed : nil
}

/// Renders assistant text as inline markdown (bold, italic, code, links),
/// preserving line breaks. Block syntax such as headings stays literal. Any
/// parse failure falls back to the plain text, never to an empty string.
public func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
