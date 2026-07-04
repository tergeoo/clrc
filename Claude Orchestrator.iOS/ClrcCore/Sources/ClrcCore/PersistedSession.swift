import Foundation

/// A terminal session as remembered by the iOS app between launches.
public struct PersistedSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let agentID: String
    public let agentName: String
    public var customName: String
    public var projectPath: String?
    public let createdAt: Date

    public init(id: String, agentID: String, agentName: String,
                customName: String, projectPath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.customName = customName
        self.projectPath = projectPath
        self.createdAt = createdAt
    }
}
