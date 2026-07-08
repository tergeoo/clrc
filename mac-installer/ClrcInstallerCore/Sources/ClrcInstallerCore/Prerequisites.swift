import Foundation

public enum ToolStatus: Equatable, Sendable {
    case installed(version: String?)
    case missing
}

public struct Prerequisites: Equatable, Sendable {
    public let homebrew: ToolStatus
    public let tailscale: ToolStatus
    public let clrc: ToolStatus
    public init(homebrew: ToolStatus, tailscale: ToolStatus, clrc: ToolStatus) {
        self.homebrew = homebrew; self.tailscale = tailscale; self.clrc = clrc
    }
}

public enum PrereqChecker {
    public static let brewPath = "/opt/homebrew/bin/brew"
    public static let tailscalePath = "tailscale"
    public static let clrcPath = "/usr/local/bin/clrc"

    public static func check(_ runner: CommandRunner) async -> Prerequisites {
        Prerequisites(
            homebrew: await probe(runner, brewPath, ["--version"], firstLineVersion: true),
            tailscale: await probe(runner, tailscalePath, ["version"], firstLineVersion: true),
            clrc: await probe(runner, clrcPath, ["status"], firstLineVersion: false)
        )
    }

    private static func probe(_ runner: CommandRunner, _ tool: String, _ args: [String],
                              firstLineVersion: Bool) async -> ToolStatus {
        guard let res = try? await runner.run(tool, args), res.ok else { return .missing }
        guard firstLineVersion else { return .installed(version: nil) }
        let line = res.stdout.split(separator: "\n").first.map(String.init)
        return .installed(version: line?.trimmingCharacters(in: .whitespaces))
    }
}
