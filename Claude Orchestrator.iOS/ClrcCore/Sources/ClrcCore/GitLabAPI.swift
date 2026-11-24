import Foundation

public enum GitLabEndpoint: Equatable, Sendable {
    case user
    case mergeRequests(GitLabScope)
    case mergeRequest(project: Int, iid: Int)
    case diffs(project: Int, iid: Int)
    case discussions(project: Int, iid: Int)
    case approve(project: Int, iid: Int)
    case note(project: Int, iid: Int, body: String)
    case lineComment(project: Int, iid: Int, body: String, refs: GitLabDiffRefs, oldPath: String, newPath: String, line: DiffLine)
    /// `sha`: the head the user reviewed; GitLab refuses (409) if it moved.
    case merge(project: Int, iid: Int, sha: String?)
    case close(project: Int, iid: Int)

    /// Changes something (vs. reading): a 401 here is a permission answer,
    /// not necessarily a bad token.
    public var isAction: Bool {
        switch self {
        case .user, .mergeRequests, .mergeRequest, .diffs, .discussions: return false
        case .approve, .note, .lineComment, .merge, .close: return true
        }
    }
}

/// Builds GitLab REST v4 requests. The token travels only in the
/// `PRIVATE-TOKEN` header; projects are addressed by numeric id.
public struct GitLabAPI: Sendable {
    static let listPageSize = 50
    static let detailPageSize = 100

    public let baseURL: URL
    private let token: String

    /// nil without a token or an http(s) base URL; "https://" is assumed
    /// when no scheme is given.
    public init?(baseURL raw: String, token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        baseURL = url
        self.token = token
    }

    public func request(_ endpoint: GitLabEndpoint) -> URLRequest {
        let (method, path, query, body) = parts(endpoint)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path.isEmpty ? "" : components.path) + "/api/v4" + path
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func parts(_ endpoint: GitLabEndpoint) -> (String, String, [(String, String)], [String: Any]?) {
        func mr(_ project: Int, _ iid: Int) -> String { "/projects/\(project)/merge_requests/\(iid)" }
        switch endpoint {
        case .user:
            return ("GET", "/user", [], nil)
        case .mergeRequests(let scope):
            return ("GET", "/merge_requests", [("scope", scope.rawValue), ("state", "opened"),
                                               ("per_page", "\(Self.listPageSize)"), ("order_by", "updated_at")], nil)
        case .mergeRequest(let p, let i):
            return ("GET", mr(p, i), [], nil)
        case .diffs(let p, let i):
            return ("GET", mr(p, i) + "/diffs", [("per_page", "\(Self.detailPageSize)")], nil)
        case .discussions(let p, let i):
            return ("GET", mr(p, i) + "/discussions", [("per_page", "\(Self.detailPageSize)")], nil)
        case .approve(let p, let i):
            return ("POST", mr(p, i) + "/approve", [], nil)
        case .note(let p, let i, let body):
            return ("POST", mr(p, i) + "/notes", [], ["body": body])
        case .lineComment(let p, let i, let body, let refs, let oldPath, let newPath, let line):
            var position: [String: Any] = ["position_type": "text", "base_sha": refs.baseSHA, "head_sha": refs.headSHA,
                                           "start_sha": refs.startSHA, "old_path": oldPath, "new_path": newPath]
            // Removed lines exist only on the old side, added only on the new
            // side; context lines are addressed by both numbers.
            switch line.kind {
            case .added: position["new_line"] = line.newNumber
            case .removed: position["old_line"] = line.oldNumber
            case .context, .noNewline:
                position["old_line"] = line.oldNumber
                position["new_line"] = line.newNumber
            }
            return ("POST", mr(p, i) + "/discussions", [], ["body": body, "position": position])
        case .merge(let p, let i, let sha):
            return ("PUT", mr(p, i) + "/merge", [], sha.map { ["sha": $0] })
        case .close(let p, let i):
            return ("PUT", mr(p, i), [], ["state_event": "close"])
        }
    }
}

public enum GitLabDiffs {
    static let lockFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum", "Cargo.lock",
                                         "Podfile.lock", "Gemfile.lock", "composer.lock"]

    /// GitLab sends only the hunks; a git header is synthesised so the
    /// shared parser fills in kind and counts.
    public static func files(_ entries: [GitLabDiffEntry]) -> [DiffFile] {
        entries.map { entry in
            var header = "diff --git a/\(entry.oldPath) b/\(entry.newPath)\n"
            if entry.newFile { header += "new file mode 100644\n--- /dev/null\n+++ b/\(entry.newPath)\n" }
            else if entry.deletedFile { header += "deleted file mode 100644\n--- a/\(entry.oldPath)\n+++ /dev/null\n" }
            else {
                if entry.renamedFile { header += "rename from \(entry.oldPath)\nrename to \(entry.newPath)\n" }
                header += "--- a/\(entry.oldPath)\n+++ b/\(entry.newPath)\n"
            }
            var file = UnifiedDiff.parse(header + entry.diff).first
                ?? DiffFile(oldPath: entry.oldPath, newPath: entry.newPath, kind: .modified)
            file.oldPath = entry.oldPath
            file.newPath = entry.newPath
            if entry.renamedFile { file.kind = .renamed }
            return file
        }
    }

    /// Lock files and files GitLab marks as generated start hidden.
    public static func isHidden(_ entry: GitLabDiffEntry) -> Bool {
        entry.generatedFile == true || lockFiles.contains((entry.newPath as NSString).lastPathComponent)
    }
}

public enum GitLabDiscussions {
    /// Line notes of `file`, keyed "n<new line>" or "o<old line>".
    public static func notes(on file: DiffFile, in discussions: [GitLabDiscussion]) -> [String: [GitLabNote]] {
        var map: [String: [GitLabNote]] = [:]
        for discussion in discussions {
            guard let first = discussion.notes.first, let position = first.position else { continue }
            guard position.newPath == file.newPath || position.oldPath == file.oldPath else { continue }
            let key: String
            if let new = position.newLine { key = "n\(new)" } else if let old = position.oldLine { key = "o\(old)" } else { continue }
            map[key, default: []].append(contentsOf: discussion.notes.filter { !$0.system })
        }
        return map
    }

    /// The map key for a diff line (new number wins, as GitLab addresses context lines).
    public static func key(for line: DiffLine) -> String? {
        if let new = line.newNumber { return "n\(new)" }
        if let old = line.oldNumber { return "o\(old)" }
        return nil
    }
}
