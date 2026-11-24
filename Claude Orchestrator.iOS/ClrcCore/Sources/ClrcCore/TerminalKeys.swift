import Foundation

/// The special keys in the one row above the keyboard (spec 5.6).
public enum TerminalKey: String, CaseIterable, Sendable {
    case esc, tab, up, down, left, right, pipe, tilde, slash, dash

    public var label: String {
        switch self {
        case .esc: return "Esc"
        case .tab: return "Tab"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .pipe: return "|"
        case .tilde: return "~"
        case .slash: return "/"
        case .dash: return "-"
        }
    }

    /// Bytes sent to the PTY (arrows as ANSI cursor sequences).
    public var bytes: [UInt8] {
        switch self {
        case .esc: return [0x1B]
        case .tab: return [0x09]
        case .up: return [0x1B, 0x5B, 0x41]
        case .down: return [0x1B, 0x5B, 0x42]
        case .right: return [0x1B, 0x5B, 0x43]
        case .left: return [0x1B, 0x5B, 0x44]
        case .pipe, .tilde, .slash, .dash: return Array(label.utf8)
        }
    }
}

public enum TerminalKeys {
    /// Ctrl+C.
    public static let interrupt: [UInt8] = [0x03]
    /// «↑ история»: the shell's previous command.
    public static let historyUp: [UInt8] = TerminalKey.up.bytes

    /// The control byte for Ctrl+<letter> (ASCII letters only).
    public static func ctrl(_ letter: Character) -> UInt8? {
        guard letter.isASCII, letter.isLetter, let ascii = letter.uppercased().first?.asciiValue else { return nil }
        return ascii & 0x1F
    }
}

/// Terminal font size: 13 pt by default, pinch between 10 and 18 pt.
public enum TerminalFont {
    public static let defaultSize: CGFloat = 13
    public static let range: ClosedRange<CGFloat> = 10...18
    static let step: CGFloat = 0.5

    public static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, range.lowerBound), range.upperBound)
    }

    /// The size after a pinch of `scale` from `base`, on a half-point grid.
    public static func pinched(from base: CGFloat, scale: CGFloat) -> CGFloat {
        clamped((base * scale / step).rounded() * step)
    }
}

public struct TerminalCommand: Equatable, Sendable, Identifiable {
    public let title: String
    public let command: String
    public var id: String { title }
    /// The command followed by a newline, so it runs at once.
    public var bytes: [UInt8] { Array((command + "\n").utf8) }
}

public struct TerminalCommandGroup: Equatable, Sendable, Identifiable {
    public let title: String
    public let commands: [TerminalCommand]
    public var id: String { title }
}

/// «Команды» sheet contents.
public enum TerminalCommands {
    public static let groups: [TerminalCommandGroup] = [
        group("Навигация", [("pwd", "pwd"), ("ls -la", "ls -la"), ("cd ~", "cd ~"), ("cd ..", "cd ..")]),
        group("Git", [("git status", "git status"), ("git diff --stat", "git diff --stat"),
                      ("git log", "git log --oneline -15"), ("git pull", "git pull")]),
        group("Claude", [("claude", "claude"), ("claude --continue", "claude --continue"), ("/compact", "/compact")]),
        group("Система", [("clear", "clear"), ("df -h", "df -h"), ("ps", "ps aux | head -20"),
                          ("top", "top -l 1 | head -15")]),
    ]

    private static func group(_ title: String, _ items: [(String, String)]) -> TerminalCommandGroup {
        TerminalCommandGroup(title: title, commands: items.map { TerminalCommand(title: $0.0, command: $0.1) })
    }
}
