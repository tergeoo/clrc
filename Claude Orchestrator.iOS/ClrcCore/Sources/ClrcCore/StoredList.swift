import Foundation

/// A user-editable list kept in UserDefaults as newline-separated text
/// (quick replies, task templates).
public enum StoredList {
    /// Trims items, drops blanks and repeats (first wins); nothing left →
    /// `defaults`.
    public static func decode(_ raw: String?, defaults: [String]) -> [String] {
        var seen = Set<String>()
        let items = (raw ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return items.isEmpty ? defaults : items
    }

    public static func encode(_ items: [String]) -> String {
        items.joined(separator: "\n")
    }
}

/// The relay address typed at sign-in or in Settings.
public enum RelayURL {
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Adds `http://` when no scheme was typed, drops a trailing `/`;
    /// nil unless it is an http(s) URL with a host and no spaces.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
