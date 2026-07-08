import Foundation
import Testing
@testable import ClrcInstallerCore

/// `onStep` is typed `@Sendable`, so the compiler must assume it could be
/// invoked from a concurrent context even though `SatelliteSetup.run` in fact
/// calls it serially; a plain captured `var` therefore fails Swift 6
/// strict-concurrency checking. Use a lock-protected box instead (same
/// pattern as `StepRecorder` in HubSetupTests / `StubHealth.Box` in
/// RelayControlTests).
final class SatelliteStepRecorder: @unchecked Sendable {
    private var items: [SatelliteStep] = []
    private let lock = NSLock()
    func append(_ step: SatelliteStep) {
        lock.lock(); defer { lock.unlock() }
        items.append(step)
    }
    func all() -> [SatelliteStep] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

@Test func satelliteJoinsUsingTokenFields() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up", "--authkey=TK"],
                   result: .init(exitCode: 0, stdout: "", stderr: ""))
    let token = JoinToken.encodeJoin(JoinPayload(
        relay: "100.9.9.9:8080", secret: "SEC", tskey: "TK", exp: 5_000_000_000))
    let sat = SatelliteSetup(tailscale: TailscaleOps(runner: r),
                             agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"))
    let recorder = SatelliteStepRecorder()
    try await sat.run(token: token, hostname: "Laptop", now: 1_000_000_000) { recorder.append($0) }
    #expect(recorder.all() == [.tailscale, .agent, .done])
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up", "--authkey=TK"] })
    #expect(calls.contains {
        $0.args == ["config", "--relay-url", "ws://100.9.9.9:8080", "--secret", "SEC", "--name", "Laptop"]
    })
}

@Test func satelliteRejectsExpiredToken() async {
    let token = JoinToken.encodeJoin(JoinPayload(relay: "x:8080", secret: "s", tskey: "k", exp: 100))
    let sat = SatelliteSetup(tailscale: TailscaleOps(runner: FakeRunner()),
                             agent: AgentControl(runner: FakeRunner()))
    await #expect(throws: TokenError.expired) {
        try await sat.run(token: token, hostname: "x", now: 200) { _ in }
    }
}
