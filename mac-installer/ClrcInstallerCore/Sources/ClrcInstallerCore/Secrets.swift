import Foundation
import Security

public protocol RandomBytes: Sendable { func bytes(_ count: Int) -> Data }

public struct SystemRandom: RandomBytes {
    public init() {}
    public func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}

public struct HubSecrets: Sendable, Equatable {
    public let jwtSecret: String
    public let adminPassword: String
    public let agentSecret: String
    public init(jwtSecret: String, adminPassword: String, agentSecret: String) {
        self.jwtSecret = jwtSecret; self.adminPassword = adminPassword; self.agentSecret = agentSecret
    }
}

public enum Secrets {
    public static func generate(_ rng: RandomBytes) -> HubSecrets {
        HubSecrets(
            jwtSecret: hex(rng.bytes(32)),
            adminPassword: passphrase(rng.bytes(24)),
            agentSecret: hex(rng.bytes(32))
        )
    }
    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    // URL/paste-safe readable password: base32-ish over a fixed alphabet.
    private static func passphrase(_ d: Data) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String(d.map { alphabet[Int($0) % alphabet.count] })
    }
}

public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
}
