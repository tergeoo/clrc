#if DEBUG
import Foundation
import ClrcCore

/// Fake services for `-designPreview`: a relay that points at a discard
/// address and never signs in, with the given Macs, and a session manager
/// over a temporary store seeded with recent projects.
@MainActor
enum PreviewEnvironment {
    static func make(agents: [Agent], recents: [String: [String]] = [:]) -> (RelayWebSocket, SessionManager) {
        let url = URL(string: "http://127.0.0.1:9")!
        let relay = RelayWebSocket(relayURL: url, authService: AuthService(relayURL: url))
        relay.agents = agents
        relay.connectionState = .connected
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clrc-design-preview", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let store = SessionsStore(directory: dir)
        for (agentID, paths) in recents {
            for path in paths.reversed() { store.addRecentProject(path, agentID: agentID) }
        }
        return (relay, SessionManager(relay: relay, store: store))
    }

    static let macs = [Agent(id: "mbp", name: "mbp-work", connected: true, version: "2.2.0"),
                       Agent(id: "mini", name: "mac-mini", connected: true)]
    static let recents = ["mbp": ["/Users/g/startups/api", "/Users/g/startups/web", "/Users/g/startups/clrc"]]

    static let profiles = MacProfiles(defaultProfile: "personal", profiles: [
        MacProfile(name: "dats", description: "DATS (gitlab.dats.tech): Go backends", launchArgs: [], harness: true),
        MacProfile(name: "personal", description: "Личный", launchArgs: ["--dangerously-skip-permissions"], harness: true),
        MacProfile(name: "rtd", description: "RTD Lab (gitlab.rtdlab.cloud): Go backend monorepo",
                   launchArgs: ["--dangerously-skip-permissions"], harness: true),
    ])
}
#endif
