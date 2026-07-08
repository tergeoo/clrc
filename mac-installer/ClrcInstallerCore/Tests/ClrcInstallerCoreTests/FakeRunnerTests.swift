import Testing
@testable import ClrcInstallerCore

@Test func fakeRunnerReturnsScriptedResultAndRecordsCalls() async throws {
    let r = FakeRunner()
    await r.script(tool: "/bin/echo", args: ["hi"],
                   result: CommandResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let out = try await r.run("/bin/echo", ["hi"])
    #expect(out.stdout == "hi\n")
    #expect(out.ok)
    let calls = await r.recorded()
    #expect(calls.count == 1)
    #expect(calls[0].tool == "/bin/echo")
}
