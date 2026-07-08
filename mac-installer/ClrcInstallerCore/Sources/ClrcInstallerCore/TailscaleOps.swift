import Foundation

public struct TailscaleOps: Sendable {
    private let runner: CommandRunner
    private let tool: String
    public init(runner: CommandRunner, tool: String = PrereqChecker.tailscalePath) {
        self.runner = runner; self.tool = tool
    }

    public func ensureUp(authKey: String?) async throws {
        var args = ["up"]
        if let k = authKey, !k.isEmpty { args.append("--authkey=\(k)") }
        let res = try await runner.run(tool, args)
        guard res.ok else { throw TailscaleError.authFailed }
    }

    public func tailnetIPv4() async throws -> String {
        let res = try await runner.run(tool, ["ip", "-4"])
        let ip = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPv4(ip) else { throw TailscaleError.badIP(ip) }
        return ip
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), p.allSatisfy(\.isNumber), n >= 0, n <= 255 else { return false }
            return true
        }
    }
}
