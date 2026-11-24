import Foundation

public enum ChangeKind: String, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case other = "?"

    /// From a `git status` code ("M", "A", "D", "R", "??", …).
    public init(statusCode: String) {
        switch statusCode {
        case "A", "??": self = .added
        case "M", "T": self = .modified
        case "D": self = .deleted
        case "R", "C": self = .renamed
        default: self = .other
        }
    }
}

public struct GitFileStatus: Equatable, Sendable, Identifiable {
    public let path: String
    public let status: String
    public var id: String { path }
    public var kind: ChangeKind { ChangeKind(statusCode: status) }
}

/// A `git_status_result`: branch and changed files of a project.
public struct GitStatusInfo: Equatable, Sendable {
    public let branch: String
    public let upstream: String
    public let ahead: Int
    public let behind: Int
    public let files: [GitFileStatus]
    public var isDirty: Bool { !files.isEmpty }

    /// nil when the agent reported an error (e.g. not a git repository).
    public init?(payload: [String: Any]) {
        if let error = payload["error"] as? String, !error.isEmpty { return nil }
        branch = payload["branch"] as? String ?? ""
        upstream = payload["upstream"] as? String ?? ""
        ahead = payload["ahead"] as? Int ?? 0
        behind = payload["behind"] as? Int ?? 0
        files = (payload["files"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
            return GitFileStatus(path: path, status: entry["status"] as? String ?? "")
        }
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed, noNewline }
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffHunk: Equatable, Sendable {
    public let header: String
    public var lines: [DiffLine]
}

public struct DiffFile: Equatable, Sendable, Identifiable {
    public var oldPath: String
    public var newPath: String
    public var kind: ChangeKind
    public var isBinary = false
    public var hunks: [DiffHunk] = []
    public var additions = 0
    public var deletions = 0

    /// The path shown: the old one for a deletion, else the new one.
    public var path: String { kind == .deleted ? oldPath : newPath }
    public var id: String { path }
}

/// Parses `git diff` output. Tolerant: a truncated or unexpected input
/// yields what could be read, never a crash.
public enum UnifiedDiff {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var oldLine = 0
        var newLine = 0

        func finish() {
            if let file = current { files.append(file) }
            current = nil
        }

        var lines = text.components(separatedBy: "\n")
        // The text's own final newline is not a diff line.
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("diff --git ") {
                finish()
                let (a, b) = headerPaths(String(line.dropFirst("diff --git ".count)))
                current = DiffFile(oldPath: a, newPath: b, kind: .modified)
                continue
            }
            guard var file = current else { continue }
            defer { current = file }

            if file.hunks.isEmpty || !isHunkBody(line) {
                if line.hasPrefix("new file mode") { file.kind = .added; continue }
                if line.hasPrefix("deleted file mode") { file.kind = .deleted; continue }
                if let from = line.dropPrefix("rename from ") { file.oldPath = from; file.kind = .renamed; continue }
                if let to = line.dropPrefix("rename to ") { file.newPath = to; file.kind = .renamed; continue }
                if line.hasPrefix("Binary files ") { file.isBinary = true; continue }
                if let old = line.dropPrefix("--- ") {
                    if old == "/dev/null" { file.kind = .added } else { file.oldPath = old.dropPrefix("a/") ?? old }
                    continue
                }
                if let new = line.dropPrefix("+++ ") {
                    if new == "/dev/null" { file.kind = .deleted } else { file.newPath = new.dropPrefix("b/") ?? new }
                    continue
                }
                if line.hasPrefix("@@") {
                    (oldLine, newLine) = hunkStarts(line)
                    file.hunks.append(DiffHunk(header: line, lines: []))
                    continue
                }
                if file.hunks.isEmpty { continue }
            }

            var hunk = file.hunks.removeLast()
            switch line.first {
            case "+":
                hunk.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
                file.additions += 1
            case "-":
                hunk.lines.append(DiffLine(kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
                file.deletions += 1
            case "\\":
                hunk.lines.append(DiffLine(kind: .noNewline, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            default:
                hunk.lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
            file.hunks.append(hunk)
        }
        finish()
        return files
    }

    private static func isHunkBody(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        return first == " " || first == "+" || first == "-" || first == "\\"
    }

    private static func headerPaths(_ rest: String) -> (String, String) {
        guard let range = rest.range(of: " b/", options: .backwards) else { return (rest, rest) }
        let a = String(rest[..<range.lowerBound])
        let b = String(rest[range.upperBound...])
        return (a.dropPrefix("a/") ?? a, b)
    }

    /// "@@ -10,2 +10,3 @@" → (10, 10).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}

public enum DiffPaths {
    /// Report paths relative to the session folder `repo`; other paths are
    /// passed through (the agent rejects anything outside the project).
    public static func relative(_ files: [String], to repo: String) -> [String] {
        let prefix = repo.hasSuffix("/") ? repo : repo + "/"
        return files.map { file in
            guard file.hasPrefix(prefix), file.count > prefix.count else { return file }
            return String(file.dropFirst(prefix.count))
        }
    }
}

extension String {
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

extension Substring {
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
