import Foundation

/// How a saved project launches. A project with a config is "saved".
public struct ProjectConfig: Codable, Equatable, Sendable {
    /// Claude profile; nil = the default (Settings, else the Mac's).
    public var profile: String?
    /// Launch mode; nil = the app default from Settings.
    public var mode: SessionLaunchMode?

    public init(profile: String? = nil, mode: SessionLaunchMode? = nil) {
        self.profile = profile
        self.mode = mode
    }
}
