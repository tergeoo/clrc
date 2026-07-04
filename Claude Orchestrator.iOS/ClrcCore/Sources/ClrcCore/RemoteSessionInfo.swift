import Foundation

/// One entry of the agent's `sessions_list` reply.
public struct RemoteSessionInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let cols: Int
    public let rows: Int
    public let name: String?
    public let command: String?
    public let started: Date?

    public init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.cols = dict["cols"] as? Int ?? 80
        self.rows = dict["rows"] as? Int ?? 24
        let name = dict["name"] as? String
        self.name = (name?.isEmpty == false) ? name : nil
        let command = dict["command"] as? String
        self.command = (command?.isEmpty == false) ? command : nil
        let iso = ISO8601DateFormatter()
        self.started = (dict["started"] as? String).flatMap { iso.date(from: $0) }
    }
}
