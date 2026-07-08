import Testing
import Foundation
@testable import ClrcInstallerCore

struct FixedRandom: RandomBytes {
    let value: UInt8
    func bytes(_ count: Int) -> Data { Data(repeating: value, count: count) }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var store: [String: String] = [:]
    func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return store[key] }
    func set(_ key: String, _ value: String) throws { lock.lock(); defer { lock.unlock() }; store[key] = value }
}

@Test func secretsAreHexOfExpectedLength() {
    let s = Secrets.generate(FixedRandom(value: 0xAB))
    // 32 bytes -> 64 hex chars for jwt & agent secret
    #expect(s.jwtSecret.count == 64)
    #expect(s.agentSecret.count == 64)
    #expect(s.jwtSecret.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(!s.adminPassword.isEmpty)
}

@Test func distinctSecretsFromDistinctBytes() {
    // Two different RNG streams must not collide across the three fields.
    let s = Secrets.generate(SystemRandom())
    #expect(s.jwtSecret != s.agentSecret)
    #expect(s.jwtSecret != s.adminPassword)
}

@Test func inMemoryStoreRoundTrip() throws {
    let store = InMemorySecretStore()
    try store.set("AGENT_SECRET", "abc")
    #expect(try store.get("AGENT_SECRET") == "abc")
    #expect(try store.get("MISSING") == nil)
}
