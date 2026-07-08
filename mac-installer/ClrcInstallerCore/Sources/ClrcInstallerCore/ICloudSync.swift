import Foundation

public struct HubDescriptor: Codable, Equatable, Sendable {
    public let relayIP: String
    public let agentSecret: String
    public init(relayIP: String, agentSecret: String) { self.relayIP = relayIP; self.agentSecret = agentSecret }
}

public protocol KVStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public enum ICloudSync {
    static let key = "hubDescriptor"
    public static func save(_ d: HubDescriptor, to store: KVStore) throws {
        store.set(try JSONEncoder().encode(d), forKey: key)
    }
    public static func load(from store: KVStore) throws -> HubDescriptor? {
        guard let data = store.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(HubDescriptor.self, from: data)
    }
}
