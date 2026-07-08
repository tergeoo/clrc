import Testing
@testable import ClrcInstallerCore

@Test func detectsAllInstalledWithVersions() async {
    let r = FakeRunner()
    await r.script(tool: "/opt/homebrew/bin/brew", args: ["--version"],
                   result: .init(exitCode: 0, stdout: "Homebrew 4.3.0\n", stderr: ""))
    await r.script(tool: "tailscale", args: ["version"],
                   result: .init(exitCode: 0, stdout: "1.70.0\n", stderr: ""))
    await r.script(tool: "/usr/local/bin/clrc", args: ["status"],
                   result: .init(exitCode: 0, stdout: "running\n", stderr: ""))
    let p = await PrereqChecker.check(r)
    #expect(p.homebrew == .installed(version: "Homebrew 4.3.0"))
    #expect(p.tailscale == .installed(version: "1.70.0"))
    #expect(p.clrc == .installed(version: nil))
}

@Test func detectsMissingOnNonZeroExit() async {
    let r = FakeRunner()
    await r.setFallback(.init(exitCode: 127, stdout: "", stderr: "not found"))
    let p = await PrereqChecker.check(r)
    #expect(p.homebrew == .missing)
    #expect(p.tailscale == .missing)
    #expect(p.clrc == .missing)
}
