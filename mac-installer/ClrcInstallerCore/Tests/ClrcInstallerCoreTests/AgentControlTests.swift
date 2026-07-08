import Testing
@testable import ClrcInstallerCore

@Test func configurePassesAllFlags() async throws {
    let r = FakeRunner()
    let a = AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc")
    try await a.configure(relayURL: "ws://100.1.2.3:8080", secret: "S", name: "My Mac")
    let calls = await r.recorded()
    #expect(calls.contains {
        $0.args == ["config", "--relay-url", "ws://100.1.2.3:8080", "--secret", "S", "--name", "My Mac"]
    })
}

@Test func startThrowsOnFailure() async {
    let r = FakeRunner()
    await r.setFallback(.init(exitCode: 1, stdout: "", stderr: "boom"))
    let a = AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc")
    await #expect(throws: AgentError.startFailed) { try await a.start() }
}
