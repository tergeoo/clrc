import Foundation

public struct AgentControl: Sendable {
    private let runner: CommandRunner
    private let clrcPath: String
    public init(runner: CommandRunner, clrcPath: String = PrereqChecker.clrcPath) {
        self.runner = runner; self.clrcPath = clrcPath
    }

    public func configure(relayURL: String, secret: String, name: String) async throws {
        let res = try await runner.run(clrcPath,
            ["config", "--relay-url", relayURL, "--secret", secret, "--name", name])
        guard res.ok else { throw AgentError.configFailed }
    }

    public func start() async throws {
        let res = try await runner.run(clrcPath, ["start"])
        guard res.ok else { throw AgentError.startFailed }
    }

    public func status() async throws -> String {
        let res = try await runner.run(clrcPath, ["status"])
        return res.stdout
    }
}
