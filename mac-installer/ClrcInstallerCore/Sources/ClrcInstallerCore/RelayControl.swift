import Foundation

public protocol FileWriter: Sendable {
    func write(_ path: String, _ contents: String, mode: Int16) throws
}
public protocol HealthChecker: Sendable {
    func healthy(_ url: String) async -> Bool
}

public struct DiskFileWriter: FileWriter {
    public init() {}
    public func write(_ path: String, _ contents: String, mode: Int16) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}

public struct URLHealthChecker: HealthChecker {
    public init() {}
    public func healthy(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u); req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

public struct RelayControl: Sendable {
    private let runner: CommandRunner
    private let files: FileWriter
    private let health: HealthChecker
    public init(runner: CommandRunner, files: FileWriter, health: HealthChecker) {
        self.runner = runner; self.files = files; self.health = health
    }

    public func writeEnv(path: String, secrets: HubSecrets, port: Int) throws {
        let body = """
        JWT_SECRET=\(secrets.jwtSecret)
        ADMIN_PASSWORD=\(secrets.adminPassword)
        AGENT_SECRET=\(secrets.agentSecret)
        PORT=\(port)
        """
        try files.write(path, body + "\n", mode: 0o600)
    }

    public func load(plistPath: String) async throws {
        let res = try await runner.run("/bin/launchctl",
            ["bootstrap", "gui/\(getuid())", plistPath])
        guard res.ok else { throw RelayError.loadFailed }
    }

    public func waitHealthy(url: String, attempts: Int) async -> Bool {
        for _ in 0..<max(1, attempts) {
            if await health.healthy(url) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
