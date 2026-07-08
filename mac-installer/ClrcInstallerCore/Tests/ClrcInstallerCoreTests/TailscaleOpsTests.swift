import Testing
@testable import ClrcInstallerCore

@Test func ensureUpPassesAuthKeyFlag() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up", "--authkey=K123"],
                   result: .init(exitCode: 0, stdout: "", stderr: ""))
    try await TailscaleOps(runner: r).ensureUp(authKey: "K123")
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up", "--authkey=K123"] })
}

@Test func ensureUpInteractiveWhenNoKey() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    try await TailscaleOps(runner: r).ensureUp(authKey: nil)
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up"] })
}

@Test func ensureUpThrowsOnFailure() async {
    let r = FakeRunner()
    await r.setFallback(.init(exitCode: 1, stdout: "", stderr: "auth error"))
    await #expect(throws: TailscaleError.authFailed) {
        try await TailscaleOps(runner: r).ensureUp(authKey: "bad")
    }
}

@Test func tailnetIPv4ParsesAndValidates() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.101.102.103\n", stderr: ""))
    let ip = try await TailscaleOps(runner: r).tailnetIPv4()
    #expect(ip == "100.101.102.103")
}

@Test func tailnetIPv4RejectsGarbage() async {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "not-an-ip\n", stderr: ""))
    await #expect(throws: TailscaleError.badIP("not-an-ip")) {
        try await TailscaleOps(runner: r).tailnetIPv4()
    }
}
