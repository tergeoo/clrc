import Testing
@testable import ClrcCore

@Suite("SessionNaming")
struct SessionNamingTests {

    @Test("extracts project path from cd && claude command")
    func projectPathFromCommand() {
        #expect(SessionNaming.projectPath(from: #"cd "/Users/me/dev/drops" && claude"#) == "/Users/me/dev/drops")
        #expect(SessionNaming.projectPath(from: "cd ~/dev/drops && claude") == "~/dev/drops")
        #expect(SessionNaming.projectPath(from: "claude") == nil)
        #expect(SessionNaming.projectPath(from: nil) == nil)
        #expect(SessionNaming.projectPath(from: "") == nil)
    }

    @Test("names session after project folder")
    func autoNameFromProject() {
        #expect(SessionNaming.autoName(for: #"cd "/Users/me/dev/drops" && claude"#, index: 3) == "drops")
    }

    @Test("marks dangerous sessions")
    func autoNameDangerous() {
        let name = SessionNaming.autoName(
            for: #"cd "/Users/me/dev/drops" && claude --dangerously-skip-permissions"#, index: 1)
        #expect(name == "drops ⚠")
        #expect(SessionNaming.autoName(for: "claude --dangerously-skip-permissions", index: 1) == "Claude ⚠")
    }

    @Test("falls back to generic names")
    func autoNameFallbacks() {
        #expect(SessionNaming.autoName(for: nil, index: 2) == "Session 2")
        #expect(SessionNaming.autoName(for: "  ", index: 2) == "Session 2")
        #expect(SessionNaming.autoName(for: "claude", index: 4) == "Claude 4")
        #expect(SessionNaming.autoName(for: "htop", index: 5) == "Session 5")
    }

    @Test("a bare cd («Терминал здесь») still names the project")
    func bareCdNamesProject() {
        #expect(SessionNaming.projectPath(from: ShellCommand.cd("/u/my api")) == "/u/my api")
        #expect(SessionNaming.autoName(for: ShellCommand.cd("/u/my api"), index: 1) == "my api")
        #expect(SessionNaming.projectPath(from: "cd ~") == nil)
    }
}
