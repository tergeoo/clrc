import Foundation

/// One Claude profile a Mac reports in `profiles_list_result`.
public struct MacProfile: Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    /// Extra `claude` flags from the harness profile (terminal launches only).
    public let launchArgs: [String]
    /// A synced ~/harness profile (vs a plain `~/.claude-<name>` dir).
    public let harness: Bool

    public var id: String { name }

    public init(name: String, description: String, launchArgs: [String], harness: Bool) {
        self.name = name
        self.description = description
        self.launchArgs = launchArgs
        self.harness = harness
    }
}

/// The profiles of one Mac and its default (CLRC_PROFILE).
public struct MacProfiles: Equatable, Sendable {
    public let defaultProfile: String?
    public let profiles: [MacProfile]

    public init(defaultProfile: String?, profiles: [MacProfile]) {
        self.defaultProfile = defaultProfile
        self.profiles = profiles
    }

    /// Decodes a `profiles_list_result` payload; nil when it has no profile list.
    public init?(payload: [String: Any]) {
        guard let raw = payload["profiles"] as? [[String: Any]] else { return nil }
        let def = payload["default_profile"] as? String
        self.init(
            defaultProfile: (def?.isEmpty == false) ? def : nil,
            profiles: raw.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                return MacProfile(name: name, description: dict["description"] as? String ?? "",
                                  launchArgs: dict["launch_args"] as? [String] ?? [],
                                  harness: dict["harness"] as? Bool ?? false)
            })
    }

    public func profile(named name: String?) -> MacProfile? {
        guard let name else { return nil }
        return profiles.first { $0.name == name }
    }
}
