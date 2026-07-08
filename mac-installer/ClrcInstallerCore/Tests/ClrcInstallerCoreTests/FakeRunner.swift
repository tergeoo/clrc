import Foundation
@testable import ClrcInstallerCore

actor FakeRunner: CommandRunner {
    struct Key: Hashable { let tool: String; let args: [String] }
    private var scripted: [Key: CommandResult] = [:]
    private(set) var calls: [(tool: String, args: [String])] = []
    var fallback = CommandResult(exitCode: 0, stdout: "", stderr: "")

    func script(tool: String, args: [String], result: CommandResult) {
        scripted[Key(tool: tool, args: args)] = result
    }
    func setFallback(_ result: CommandResult) {
        fallback = result
    }
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult {
        calls.append((tool, args))
        return scripted[Key(tool: tool, args: args)] ?? fallback
    }
    func recorded() -> [(tool: String, args: [String])] { calls }
}
