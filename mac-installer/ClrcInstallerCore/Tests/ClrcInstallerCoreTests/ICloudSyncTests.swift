import Testing
import Foundation
@testable import ClrcInstallerCore

final class MemoryKV: KVStore, @unchecked Sendable {
    private var d: [String: Data] = [:]
    func data(forKey key: String) -> Data? { d[key] }
    func set(_ data: Data?, forKey key: String) { d[key] = data }
}

@Test func iCloudRoundTripExcludesAuthKey() throws {
    let kv = MemoryKV()
    let desc = HubDescriptor(relayIP: "100.1.2.3", agentSecret: "SEC")
    try ICloudSync.save(desc, to: kv)
    #expect(try ICloudSync.load(from: kv) == desc)
    // stored blob must not contain a tskey field
    let raw = String(data: kv.data(forKey: "hubDescriptor")!, encoding: .utf8)!
    #expect(!raw.contains("tskey"))
}

@Test func iCloudLoadNilWhenEmpty() throws {
    #expect(try ICloudSync.load(from: MemoryKV()) == nil)
}
