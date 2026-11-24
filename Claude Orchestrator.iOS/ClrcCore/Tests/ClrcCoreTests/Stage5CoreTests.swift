import Testing
import Foundation
@testable import ClrcCore

@Test func dangerousFlagPrecedesPrompt() {
    #expect(SessionLaunchMode.terminalCommand(cwd: "~/dev/api", prompt: "fix 'it'", skipPermissions: true)
            == #"cd ~/'dev/api' && claude --dangerously-skip-permissions 'fix '\''it'\'''"#)
}

@Test func dangerousWithoutPrompt() {
    let cmd = SessionLaunchMode.terminalCommand(cwd: nil, prompt: nil, skipPermissions: true)
    #expect(cmd == "claude --dangerously-skip-permissions")
    #expect(SessionNaming.autoName(for: cmd, index: 1) == "Claude ⚠")
    #expect(SessionLaunchMode.terminalCommand(cwd: nil, prompt: nil, skipPermissions: false) == "claude")
}

@Test func storedListDecodes() {
    #expect(StoredList.decode(" Да \n\nНет\nДа\n", defaults: ["x"]) == ["Да", "Нет"])
    #expect(StoredList.decode(nil, defaults: ["x"]) == ["x"])
    #expect(StoredList.decode("  \n ", defaults: ["x"]) == ["x"])
}

@Test func storedListRoundTrips() {
    let items = ["Продолжай", "Запусти тесты"]
    #expect(StoredList.decode(StoredList.encode(items), defaults: []) == items)
}

@Test func chipsUseCustomPermanentList() {
    let chips = QuickReplies.chips(for: TurnReport(status: .needsInput, questions: ["Ок"]), permanent: ["Ок", "Дальше"])
    #expect(chips.map(\.title) == ["1 · Ок", "Дальше"])
}

@Test func relayURLNormalizes() {
    #expect(RelayURL.normalize("192.168.1.5:8080")?.absoluteString == "http://192.168.1.5:8080")
    #expect(RelayURL.normalize(" https://r.example.com/ ")?.absoluteString == "https://r.example.com")
    #expect(RelayURL.normalize("http://localhost:8080")?.absoluteString == "http://localhost:8080")
}

@Test func relayURLRejectsInvalid() {
    #expect(RelayURL.normalize("ftp://x") == nil)
    #expect(RelayURL.normalize("a b") == nil)
    #expect(RelayURL.normalize("") == nil)
    #expect(RelayURL.normalize("http://") == nil)
}

// Review fix: «Перезапустить» must not replay a task, and never skips permissions silently.
@Test func restartCommandForALaunchHasNoPromptAndNoFlag() {
    let request = NewTaskPlanner.request(agentID: "a", cwd: "~/dev/api", mode: .terminal, prompt: "удали миграции",
                                         customName: "", model: "", profile: "", skipPermissions: true)
    #expect(NewTaskPlanner.restartCommand(for: request) == "cd ~/'dev/api' && claude")
}

@Test func storedDangerousCommandRestartsPlainClaude() {
    let entry = PersistedSession(id: "d", agentID: "m", agentName: "mac", customName: "api ⚠", projectPath: "/u/api",
                                 command: "cd '/u/api' && claude --dangerously-skip-permissions 'удали миграции'")
    #expect(entry.restartCommand == "cd '/u/api' && claude")
}

@Test func dangerousLaunchKeepsTheWarningInItsName() {
    let request = NewTaskPlanner.request(agentID: "a", cwd: "/u/api", mode: .terminal, prompt: "", customName: "",
                                         model: "", profile: "", skipPermissions: true)
    #expect(request.name == "api ⚠")
    let custom = NewTaskPlanner.request(agentID: "a", cwd: "/u/api", mode: .terminal, prompt: "", customName: "fix",
                                        model: "", profile: "", skipPermissions: true)
    #expect(custom.name == "fix ⚠")
}
