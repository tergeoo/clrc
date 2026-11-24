import Foundation

/// One entry of an `fs_list` reply.
public struct FSItem: Equatable, Sendable, Identifiable {
    public let name: String
    public let isDir: Bool
    public let size: Int64
    public let modified: Date?
    public var id: String { name }

    public init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String, let isDir = dict["is_dir"] as? Bool else { return nil }
        self.name = name
        self.isDir = isDir
        size = (dict["size"] as? Int).map(Int64.init) ?? (dict["size"] as? Int64) ?? 0
        modified = (dict["mod_time"] as? String).flatMap(parseEventTimestamp)
    }

    private static let codeExtensions: Set<String> = ["swift", "go", "ts", "tsx", "js", "jsx", "py", "json",
                                                      "yml", "yaml", "sh", "rs", "kt", "java", "rb", "c", "h", "m"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg"]

    /// SF Symbol for the row.
    public var kindSymbol: String {
        if isDir { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return "doc.richtext" }
        if Self.codeExtensions.contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if Self.imageExtensions.contains(ext) { return "photo" }
        return "doc"
    }
}

/// Case- and diacritic-insensitive "contains", shared by the searches.
func matchesQuery(_ text: String, _ query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

public enum FSListing {
    /// Folders first, then names in Finder order (a2 before a10).
    public static func sorted(_ items: [FSItem]) -> [FSItem] {
        items.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func filtered(_ items: [FSItem], query: String) -> [FSItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { matchesQuery($0.name, query) }
    }
}

public struct PathCrumb: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }
}

public enum PathCrumbs {
    /// One crumb per level; each crumb's path opens exactly that folder.
    public static func crumbs(for path: String) -> [PathCrumb] {
        let root: String
        if path == "~" || path.hasPrefix("~/") {
            root = "~"
        } else if path.hasPrefix("/") {
            root = "/"
        } else {
            root = ""
        }
        var crumbs = root.isEmpty ? [] : [PathCrumb(name: root, path: root)]
        var current = root
        let rest = root.isEmpty ? path : String(path.dropFirst(root.count))
        for part in rest.split(separator: "/") {
            current = current.isEmpty ? String(part) : join(current, String(part))
            crumbs.append(PathCrumb(name: String(part), path: current))
        }
        return crumbs
    }

    public static func join(_ parent: String, _ child: String) -> String {
        parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }
}

public enum ProjectIndex {
    /// The «Маки» level is skipped when there is only one Mac.
    public static func showsMacLevel(macCount: Int) -> Bool { macCount > 1 }

    public static func filter(_ paths: [String], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return paths }
        return paths.filter { matchesQuery($0, query) }
    }

    /// Sessions working in exactly `path` (a trailing "/" is ignored).
    public static func sessionCount(path: String, folders: [String?]) -> Int {
        let target = trimmedSlash(path)
        return folders.compactMap { $0 }.filter { trimmedSlash($0) == target }.count
    }

    private static func trimmedSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
