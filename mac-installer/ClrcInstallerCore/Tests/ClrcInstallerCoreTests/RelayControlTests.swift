import Testing
@testable import ClrcInstallerCore

final class SpyFileWriter: FileWriter, @unchecked Sendable {
    var written: [(path: String, contents: String, mode: Int16)] = []
    func write(_ path: String, _ contents: String, mode: Int16) throws {
        written.append((path, contents, mode))
    }
}
struct StubHealth: HealthChecker {
    let results: [Bool]
    private let box = Box()
    final class Box: @unchecked Sendable { var i = 0 }
    func healthy(_ url: String) async -> Bool {
        defer { box.i += 1 }
        return box.i < results.count ? results[box.i] : false
    }
}

@Test func writeEnvEmitsAllSecretsMode0600() throws {
    let files = SpyFileWriter()
    let rc = RelayControl(runner: FakeRunner(), files: files, health: StubHealth(results: [true]))
    let secrets = HubSecrets(jwtSecret: "J", adminPassword: "P", agentSecret: "A")
    try rc.writeEnv(path: "/tmp/relay.env", secrets: secrets, port: 8080)
    #expect(files.written.count == 1)
    let w = files.written[0]
    #expect(w.mode == 0o600)
    #expect(w.contents.contains("JWT_SECRET=J"))
    #expect(w.contents.contains("ADMIN_PASSWORD=P"))
    #expect(w.contents.contains("AGENT_SECRET=A"))
    #expect(w.contents.contains("PORT=8080"))
}

@Test func loadThrowsWhenLaunchctlFails() async {
    let r = FakeRunner()
    await r.setFallback(.init(exitCode: 1, stdout: "", stderr: "no"))
    let rc = RelayControl(runner: r, files: SpyFileWriter(), health: StubHealth(results: [true]))
    await #expect(throws: RelayError.loadFailed) { try await rc.load(plistPath: "/tmp/x.plist") }
}

@Test func waitHealthyRetriesUntilTrue() async {
    let rc = RelayControl(runner: FakeRunner(), files: SpyFileWriter(),
                          health: StubHealth(results: [false, false, true]))
    let ok = await rc.waitHealthy(url: "http://127.0.0.1:8080/health", attempts: 5)
    #expect(ok)
}
