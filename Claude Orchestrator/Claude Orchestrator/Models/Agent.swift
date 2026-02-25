import Foundation

struct Agent: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var connected: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case connected
    }
}
