import Foundation
import Testing
@testable import ClrcInstallerCore

/// Collects steps emitted by `onStep`. `onStep` is typed `@Sendable`, so the
/// compiler must assume it could be invoked from a concurrent context even
/// though `HubSetup.run` in fact calls it serially; a plain captured `var`
/// therefore fails Swift 6 strict-concurrency checking. Use a lock-protected
/// box instead (same pattern as `StubHealth.Box` in RelayControlTests).
final class StepRecorder: @unchecked Sendable {
    private var items: [HubStep] = []
    private let lock = NSLock()
    func append(_ step: HubStep) {
        lock.lock(); defer { lock.unlock() }
        items.append(step)
    }
    func all() -> [HubStep] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

@Test func hubSetupRunsAllStepsInOrderAndStoresSecrets() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.5.6.7\n", stderr: ""))
    let store = InMemorySecretStore()
    let files = SpyFileWriter()
    let hub = HubSetup(
        tailscale: TailscaleOps(runner: r),
        rng: FixedRandom(value: 0x11),
        store: store,
        relay: RelayControl(runner: r, files: files, health: StubHealth(results: [true])),
        agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"),
        relayEnvPath: "/tmp/relay.env",
        relayPlistPath: "/tmp/relay.plist",
        healthURL: "http://127.0.0.1:8080/health"
    )
    let recorder = StepRecorder()
    let result = try await hub.run(hostname: "My Mac") { recorder.append($0) }
    #expect(recorder.all() == [.tailscale, .secrets, .relay, .agent, .done])
    #expect(result.ip == "100.5.6.7")
    #expect(try store.get("AGENT_SECRET") == result.secrets.agentSecret)
    // agent configured against the tailnet relay
    let calls = await r.recorded()
    #expect(calls.contains { $0.args.contains("--relay-url") && $0.args.contains("ws://100.5.6.7:8080") })
}

@Test func hubSetupThrowsWhenRelayNeverHealthy() async {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.5.6.7\n", stderr: ""))
    let hub = HubSetup(
        tailscale: TailscaleOps(runner: r), rng: FixedRandom(value: 1),
        store: InMemorySecretStore(),
        relay: RelayControl(runner: r, files: SpyFileWriter(), health: StubHealth(results: [false])),
        agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"),
        relayEnvPath: "/tmp/e", relayPlistPath: "/tmp/p", healthURL: "http://127.0.0.1:8080/health"
    )
    await #expect(throws: HubError.relayUnhealthy) { _ = try await hub.run(hostname: "x") { _ in } }
}
