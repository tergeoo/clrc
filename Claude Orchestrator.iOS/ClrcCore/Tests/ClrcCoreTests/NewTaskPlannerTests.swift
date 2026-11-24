import Testing
@testable import ClrcCore

@Test func defaultAgentPrefersOnlinePreferred() {
    #expect(NewTaskPlanner.defaultAgentID(onlineAgentIDs: ["a", "b"], preferred: "b", lastProjectAgentID: "a") == "b")
}

@Test func defaultAgentSkipsOfflinePreferred() {
    #expect(NewTaskPlanner.defaultAgentID(onlineAgentIDs: ["a", "b"], preferred: "x", lastProjectAgentID: "b") == "b")
    #expect(NewTaskPlanner.defaultAgentID(onlineAgentIDs: ["a", "b"], preferred: nil, lastProjectAgentID: "x") == "a")
}

@Test func defaultAgentNilWhenNoneOnline() {
    #expect(NewTaskPlanner.defaultAgentID(onlineAgentIDs: [], preferred: "a", lastProjectAgentID: "a") == nil)
}

@Test func requestTrimsAndNames() {
    let r = NewTaskPlanner.request(agentID: "a", cwd: "/u/g/api", mode: .chat, prompt: "  ",
                                   customName: " ", model: " opus ", profile: "Bad Name")
    #expect(r.prompt == nil)
    #expect(r.name == "api")
    #expect(r.model == "opus")
    #expect(r.profile == nil)
    #expect(r.cwd == "/u/g/api")
}

@Test func requestKeepsCustomNameAndPrompt() {
    let r = NewTaskPlanner.request(agentID: "a", cwd: nil, mode: .terminal, prompt: " fix it \n",
                                   customName: "hotfix", model: "", profile: "work")
    #expect(r.prompt == "fix it")
    #expect(r.name == "hotfix")
    #expect(r.model == nil)
    #expect(r.profile == "work")
    #expect(r.mode == .terminal)
}

@Test func requestWithoutCwdIsNamedClaude() {
    let r = NewTaskPlanner.request(agentID: "a", cwd: nil, mode: .chat, prompt: "", customName: "", model: "", profile: "")
    #expect(r.name == "claude")
    let home = NewTaskPlanner.request(agentID: "a", cwd: "~", mode: .chat, prompt: "", customName: "", model: "", profile: "")
    #expect(home.cwd == nil)
    #expect(home.name == "claude")
}

@Test func launchesOnProjectTapOnlyWithEmptyTask() {
    #expect(NewTaskPlanner.launchesOnProjectTap(prompt: ""))
    #expect(NewTaskPlanner.launchesOnProjectTap(prompt: "  \n"))
    #expect(!NewTaskPlanner.launchesOnProjectTap(prompt: "x"))
}

@Test func templatesMatchSpec() {
    #expect(NewTaskPlanner.templates == ["Почини тесты", "Сделай ревью ветки", "Объясни код", "Обнови зависимости"])
}

@Test func skipPermissionsOnlyInTerminal() {
    let chat = NewTaskPlanner.request(agentID: "a", cwd: nil, mode: .chat, prompt: "", customName: "", model: "", profile: "",
                                      skipPermissions: true)
    #expect(!chat.skipPermissions)
    let term = NewTaskPlanner.request(agentID: "a", cwd: nil, mode: .terminal, prompt: "", customName: "", model: "", profile: "",
                                      skipPermissions: true)
    #expect(term.skipPermissions)
    let plain = NewTaskPlanner.request(agentID: "a", cwd: nil, mode: .terminal, prompt: "", customName: "", model: "", profile: "")
    #expect(!plain.skipPermissions)
}
