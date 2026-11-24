import Foundation

/// How a new Claude session starts, picked in the New Session sheet:
/// a chat session in one of the two display modes, or `claude` in a terminal.
/// It is derived from two stored values so the Settings display picker and
/// the sheet never disagree.
public enum SessionLaunchMode: String, CaseIterable, Sendable, Identifiable {
    case chat
    case brief
    case terminal

    public var id: String { rawValue }

    /// The `UserDefaults` / `@AppStorage` key for "start Claude in a terminal".
    public static let terminalStorageKey = "claude_in_terminal"

    public init(displayMode: ChatDisplayMode, inTerminal: Bool) {
        if inTerminal {
            self = .terminal
            return
        }
        switch displayMode {
        case .chat: self = .chat
        case .brief: self = .brief
        }
    }

    /// The chat display mode to use, or nil for a terminal session.
    public var displayMode: ChatDisplayMode? {
        switch self {
        case .chat: return .chat
        case .brief: return .brief
        case .terminal: return nil
        }
    }

    /// The shell command for a terminal Claude session. The path is
    /// single-quoted so spaces and shell metacharacters in folder names stay
    /// literal; `~` or no path starts in the shell's home folder.
    public static func terminalCommand(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "~" else { return "claude" }
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude"
    }
}
