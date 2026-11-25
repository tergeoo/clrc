import Foundation
import ClrcCore

struct Agent: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var connected: Bool
    /// Agent build version; nil for agents older than 2.1.
    var version: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case connected
        case version
    }

    /// The Mac runs an agent this app does not fully support.
    var needsUpdate: Bool { AgentVersion.isOutdated(version) }
}
