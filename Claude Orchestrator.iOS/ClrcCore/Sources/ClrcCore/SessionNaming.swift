import Foundation

/// Derives display names and project paths from the shell command a session was started with.
public enum SessionNaming {

    /// Extracts the directory from a "cd <path> && …" prefix, if present.
    public static func projectPath(from command: String?) -> String? {
        guard let cmd = command else { return nil }
        let pattern = #"cd\s+["']?([^"'&\r\n]+?)["']?\s*&&"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let range = Range(match.range(at: 1), in: cmd) else { return nil }
        let path = String(cmd[range]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    public static func autoName(for command: String?, index: Int) -> String {
        guard let cmd = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmd.isEmpty else {
            return "Session \(index)"
        }
        let dangerous = cmd.contains("--dangerously-skip-permissions")
        let warning = dangerous ? " ⚠" : ""

        if let path = projectPath(from: cmd) {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last + warning }
        }
        if cmd.contains("claude") {
            return dangerous ? "Claude ⚠" : "Claude \(index)"
        }
        return "Session \(index)"
    }
}
