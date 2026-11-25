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
    /// Terminals: the command the session was started with, repeated on
    /// restart. nil for entries saved before it was recorded.
    public let command: String?
    /// The profile the session was launched with; reattach, restore and
    /// restart reuse it rather than the current Settings or project config.
    public let profile: String?
    /// Whether that profile was sent with `profile_strict`.
    public let profileStrict: Bool

    /// What «Перезапустить» runs: the stored command; for older entries,
    /// Claude in their project folder (the previous behaviour).
    public var restartCommand: String? {
        // A stored dangerous launch restarts as plain Claude: skipping
        // permissions always needs a fresh confirmation (brief §2 п.6).
        if let command, !command.isEmpty, !command.contains(SessionLaunchMode.skipPermissionsFlag) { return command }
        return projectPath.map { SessionLaunchMode.terminalCommand(cwd: $0) }
    }

    public init(id: String, agentID: String, agentName: String,
                customName: String, projectPath: String? = nil, createdAt: Date = Date(),
                kind: Kind = .pty, cwd: String? = nil, command: String? = nil,
                profile: String? = nil, profileStrict: Bool = false) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.customName = customName
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.kind = kind
        self.cwd = cwd
        self.command = command
        self.profile = profile
        self.profileStrict = profileStrict
    }

    enum CodingKeys: String, CodingKey {
        case id, agentID, agentName, customName, projectPath, createdAt, kind, cwd, command, profile, profileStrict
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
        command = try c.decodeIfPresent(String.self, forKey: .command)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        profileStrict = try c.decodeIfPresent(Bool.self, forKey: .profileStrict) ?? false
    }
}
