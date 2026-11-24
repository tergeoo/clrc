import Foundation

/// A session as remembered by the iOS app between launches: a terminal (PTY)
/// or a chat session. Chat sessions also keep their working directory, which
/// the chat `connect` needs to reattach.
public struct PersistedSession: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pty
        case chat
    }

    public let id: String
    public let agentID: String
    public let agentName: String
    public var customName: String
    public var projectPath: String?
    public let createdAt: Date
    /// Entries written before chat sessions were persisted have no kind and
    /// are terminals.
    public let kind: Kind
    /// Chat sessions only: the working directory sent in `connect`.
    public let cwd: String?

    public init(id: String, agentID: String, agentName: String,
                customName: String, projectPath: String? = nil, createdAt: Date = Date(),
                kind: Kind = .pty, cwd: String? = nil) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.customName = customName
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.kind = kind
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case id, agentID, agentName, customName, projectPath, createdAt, kind, cwd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentID = try c.decode(String.self, forKey: .agentID)
        agentName = try c.decode(String.self, forKey: .agentName)
        customName = try c.decode(String.self, forKey: .customName)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .pty
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    }
}
