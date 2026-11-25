import Foundation

/// The profile a launch sends in `connect`.
public struct ResolvedProfile: Equatable, Sendable {
    /// nil = send none (the Mac's default).
    public let name: String?
    /// `profile_strict`: the Mac must refuse instead of falling back.
    public let strict: Bool

    public init(name: String?, strict: Bool) {
        self.name = name
        self.strict = strict
    }
}

public enum LaunchProfileResolver {
    /// Highest wins: the New Task override, the project's profile, the
    /// Settings profile, else none. Only a project's profile is strict: it is
    /// the one the owner saved as "this project runs as that account".
    public static func resolve(taskOverride: String?, project: ProjectConfig?,
                               settingsProfile: String?) -> ResolvedProfile {
        if let taskOverride { return ResolvedProfile(name: taskOverride, strict: false) }
        if let profile = project?.profile { return ResolvedProfile(name: profile, strict: true) }
        return ResolvedProfile(name: settingsProfile, strict: false)
    }

    /// The picker's «default» option, named after what it resolves to now.
    public static func defaultLabel(settingsProfile: String?, macDefault: String?) -> String {
        if let settingsProfile { return "По умолчанию (\(settingsProfile) — из настроек)" }
        if let macDefault { return "Как на Маке (\(macDefault))" }
        return "Как на Маке"
    }
}
