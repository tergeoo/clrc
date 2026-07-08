import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
    public var ok: Bool { exitCode == 0 }
}

public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult
}

public extension CommandRunner {
    func run(_ tool: String, _ args: [String]) async throws -> CommandResult {
        try await run(tool, args, stdin: nil)
    }
}
