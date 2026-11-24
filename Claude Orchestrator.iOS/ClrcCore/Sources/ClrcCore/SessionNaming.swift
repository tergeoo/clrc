import Foundation

/// Derives display names and project paths from the shell command a session was started with.
public enum SessionNaming {

    /// Extracts the directory from a "cd <path> && …" prefix or a bare
    /// "cd <path>", if present. The path is read as one shell word (single
    /// and double quotes, `'\''` escapes), so `cd ~/'my dir'` gives
    /// `~/my dir`. The home folder (`~`) is not a project.
    public static func projectPath(from command: String?) -> String? {
        guard let command else { return nil }
        var rest = Substring(command).drop { $0 == " " || $0 == "\t" }
        guard rest.hasPrefix("cd"), let afterCd = rest.dropFirst(2).first, afterCd == " " || afterCd == "\t" else { return nil }
        rest = rest.dropFirst(2).drop { $0 == " " || $0 == "\t" }
        guard let (word, remainder) = shellWord(rest) else { return nil }
        let tail = remainder.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("&&") else { return nil }
        let path = word.trimmingCharacters(in: .whitespaces)
        return path.isEmpty || path == "~" ? nil : path
    }

    /// Reads one shell word; nil on an unterminated quote.
    private static func shellWord(_ text: Substring) -> (String, Substring)? {
        var word = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == " " || char == "\t" || char == "&" || char == "\n" { break }
            if char == "'" || char == "\"" {
                guard let close = text[text.index(after: index)...].firstIndex(of: char) else { return nil }
                word += text[text.index(after: index)..<close]
                index = text.index(after: close)
            } else if char == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { word.append(text[index]); index = text.index(after: index) }
            } else {
                word.append(char)
                index = text.index(after: index)
            }
        }
        return (word, text[index...])
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
