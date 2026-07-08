import Foundation

public enum HubStep: Equatable, Sendable { case tailscale, secrets, relay, agent, done }
public enum HubError: Error, Equatable { case relayUnhealthy }

public struct HubResult: Sendable, Equatable {
    public let ip: String
    public let secrets: HubSecrets
}

public struct HubSetup: Sendable {
    private let tailscale: TailscaleOps
    private let rng: RandomBytes
    private let store: SecretStore
    private let relay: RelayControl
    private let agent: AgentControl
    private let relayEnvPath: String
    private let relayPlistPath: String
    private let healthURL: String

    public init(tailscale: TailscaleOps, rng: RandomBytes, store: SecretStore,
                relay: RelayControl, agent: AgentControl,
                relayEnvPath: String, relayPlistPath: String, healthURL: String) {
        self.tailscale = tailscale; self.rng = rng; self.store = store
        self.relay = relay; self.agent = agent
        self.relayEnvPath = relayEnvPath; self.relayPlistPath = relayPlistPath
        self.healthURL = healthURL
    }

    public func run(hostname: String, onStep: @Sendable (HubStep) -> Void) async throws -> HubResult {
        onStep(.tailscale)
        try await tailscale.ensureUp(authKey: nil)
        let ip = try await tailscale.tailnetIPv4()

        onStep(.secrets)
        let secrets = Secrets.generate(rng)
        try store.set("JWT_SECRET", secrets.jwtSecret)
        try store.set("ADMIN_PASSWORD", secrets.adminPassword)
        try store.set("AGENT_SECRET", secrets.agentSecret)

        onStep(.relay)
        try relay.writeEnv(path: relayEnvPath, secrets: secrets, port: 8080)
        try await relay.load(plistPath: relayPlistPath)
        guard await relay.waitHealthy(url: healthURL, attempts: 20) else { throw HubError.relayUnhealthy }

        onStep(.agent)
        try await agent.configure(relayURL: "ws://\(ip):8080", secret: secrets.agentSecret, name: hostname)
        try await agent.start()

        onStep(.done)
        return HubResult(ip: ip, secrets: secrets)
    }
}
