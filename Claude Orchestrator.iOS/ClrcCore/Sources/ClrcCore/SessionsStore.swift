import Foundation
import os

/// File-backed store for persisted sessions and recent project paths.
/// Synchronous; intended to be called from the main actor only.
public final class SessionsStore {

    public private(set) var sessions: [PersistedSession] = []
    private var recentsByAgent: [String: [String]] = [:]
    /// Saved projects: agent id → project path → launch config.
    private var configsByAgent: [String: [String: ProjectConfig]] = [:]

    private let fileURL: URL
    private static let maxRecents = 8
    private static let log = Logger(subsystem: "clrc", category: "SessionsStore")

    private struct StoreFile: Codable {
        var sessions: [PersistedSession] = []
        var recentsByAgent: [String: [String]] = [:]
        /// Optional so files written before saved projects still decode.
        var configsByAgent: [String: [String: ProjectConfig]]?
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("sessions-store.json")
        load()
    }

    // MARK: - Sessions

    public func upsert(_ session: PersistedSession) {
        sessions = sessions.filter { $0.id != session.id } + [session]
        save()
    }

    public func remove(id: String) {
        sessions = sessions.filter { $0.id != id }
        save()
    }

    public func rename(id: String, to name: String) {
        sessions = sessions.map { s in
            guard s.id == id else { return s }
            var copy = s
            copy.customName = name
            return copy
        }
        save()
    }

    /// Terminal sessions of one agent, in insertion order.
    public func ptySessions(forAgent agentID: String) -> [PersistedSession] {
        sessions(forAgent: agentID).filter { $0.kind == .pty }
    }

    /// Chat sessions of one agent, in insertion order.
    public func chatSessions(forAgent agentID: String) -> [PersistedSession] {
        sessions(forAgent: agentID).filter { $0.kind == .chat }
    }

    public func sessions(forAgent agentID: String) -> [PersistedSession] {
        sessions.filter { $0.agentID == agentID }
    }

    // MARK: - Recent projects

    public func addRecentProject(_ path: String, agentID: String) {
        var list = recentsByAgent[agentID] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        recentsByAgent[agentID] = Array(list.prefix(Self.maxRecents))
        save()
    }

    public func recentProjects(forAgent agentID: String) -> [String] {
        recentsByAgent[agentID] ?? []
    }

    // MARK: - Saved projects

    public func projectConfig(path: String, agentID: String) -> ProjectConfig? {
        configsByAgent[agentID]?[path]
    }

    /// Saves (or, with nil, un-saves) a project's launch config.
    public func setProjectConfig(_ config: ProjectConfig?, path: String, agentID: String) {
        var configs = configsByAgent[agentID] ?? [:]
        configs[path] = config
        configsByAgent[agentID] = configs.isEmpty ? nil : configs
        save()
    }

    /// Saved project paths of one agent, sorted by folder name.
    public func savedProjects(forAgent agentID: String) -> [String] {
        (configsByAgent[agentID] ?? [:]).keys.sorted {
            let a = ($0 as NSString).lastPathComponent, b = ($1 as NSString).lastPathComponent
            return a == b ? $0 < $1 : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The config saved for the same path on another Mac, to prefill a new
    /// project; its profile is kept only if this Mac has it (`available`).
    public func suggestedConfig(path: String, forAgent agentID: String, available: [String]) -> ProjectConfig? {
        let other = configsByAgent.first { $0.key != agentID && $0.value[path] != nil }?.value[path]
        guard var config = other else { return nil }
        if let profile = config.profile, !available.contains(profile) { config.profile = nil }
        return config
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return } // first launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(StoreFile.self, from: data) else {
            Self.log.error("corrupt store at \(self.fileURL.path) — starting empty")
            return
        }
        sessions = file.sessions
        recentsByAgent = file.recentsByAgent
        configsByAgent = file.configsByAgent ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(StoreFile(sessions: sessions, recentsByAgent: recentsByAgent, configsByAgent: configsByAgent))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure must never break the live session UI.
            Self.log.error("save failed: \(error.localizedDescription)")
        }
    }
}
