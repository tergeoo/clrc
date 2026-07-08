import Foundation

public enum SatelliteStep: Equatable, Sendable { case tailscale, agent, done }

public struct SatelliteSetup: Sendable {
    private let tailscale: TailscaleOps
    private let agent: AgentControl
    public init(tailscale: TailscaleOps, agent: AgentControl) {
        self.tailscale = tailscale; self.agent = agent
    }

    public func run(token: String, hostname: String, now: Int64,
                    onStep: @Sendable (SatelliteStep) -> Void) async throws {
        let p = try JoinToken.decodeJoin(token, now: now)
        onStep(.tailscale)
        try await tailscale.ensureUp(authKey: p.tskey)
        onStep(.agent)
        try await agent.configure(relayURL: "ws://\(p.relay)", secret: p.secret, name: hostname)
        try await agent.start()
        onStep(.done)
    }
}
