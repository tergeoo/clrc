import Foundation

/// One Mac in the relay's `agent_list` message.
public struct AgentSummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let connected: Bool
    /// Agent build version; nil for agents older than 2.1, which do not report one.
    public let version: String?

    public init(id: String, name: String, connected: Bool, version: String?) {
        self.id = id
        self.name = name
        self.connected = connected
        self.version = version
    }

    public init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let name = dict["name"] as? String else { return nil }
        let version = dict["version"] as? String
        self.init(id: id, name: name,
                  connected: dict["connected"] as? Bool ?? false,
                  version: (version?.isEmpty == false) ? version : nil)
    }

    /// Decodes the `agents` array of an `agent_list` payload, skipping malformed entries.
    public static func list(fromAgentListPayload payload: [String: Any]) -> [AgentSummary] {
        let raw = payload["agents"] as? [[String: Any]] ?? []
        return raw.compactMap(AgentSummary.init(dict:))
    }
}

/// Whether a Mac's agent is too old for this app.
public enum AgentVersion {
    /// Oldest agent this app fully supports. Raise it when the app starts
    /// relying on a protocol feature added in a newer agent.
    public static let minimumSupported = "2.0.0"

    /// True when the agent must be updated: it reported no version (pre-2.1)
    /// or a release older than `minimumSupported`. Builds whose version does
    /// not start with `X.Y.Z` (e.g. "dev") are never flagged.
    public static func isOutdated(_ reported: String?) -> Bool {
        guard let reported, !reported.isEmpty else { return true }
        guard let have = numericTriple(reported),
              let need = numericTriple(minimumSupported) else { return false }
        return have.lexicographicallyPrecedes(need)
    }

    /// Leading "X.Y.Z" of a version string ("2.0.0-5-gabc" → [2, 0, 0]).
    private static func numericTriple(_ version: String) -> [Int]? {
        let core = version.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).prefix(3).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
