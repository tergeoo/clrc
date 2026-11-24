import Foundation
import ClrcCore

/// Where the relay address lives and which one the app starts with.
enum RelayAddress {
    static let storageKey = "relay_server_url"
    static let fallback = "http://localhost:8080"

    /// Saved address if valid, else the Info.plist `RELAY_URL`, else
    /// localhost — every candidate normalised the same way as at sign-in.
    static func startURL(defaults: UserDefaults = .standard) -> URL {
        let plist = Bundle.main.object(forInfoDictionaryKey: "RELAY_URL") as? String
        for candidate in [defaults.string(forKey: storageKey), plist, fallback] {
            if let candidate, let url = RelayURL.normalize(candidate) { return url }
        }
        return URL(string: fallback)!
    }
}
