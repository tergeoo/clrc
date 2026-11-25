import Testing
import Foundation
@testable import ClrcCore

private func fixturePayload(_ name: String) throws -> [String: Any] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: repoRoot.appendingPathComponent("protocol/fixtures/\(name)"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(json["payload"] as? [String: Any])
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clrc-launch-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Mac profiles

@Test func profilesListFixtureDecodes() throws {
    let profiles = try #require(MacProfiles(payload: try fixturePayload("profiles_list_result.json")))
    #expect(profiles.defaultProfile == "personal")
    #expect(profiles.profiles.map(\.name) == ["personal", "rtd", "solo"])
    #expect(profiles.profile(named: "rtd")?.launchArgs == ["--dangerously-skip-permissions"])
    #expect(profiles.profile(named: "rtd")?.description == "RTD Lab (gitlab.rtdlab.cloud): Go backend monorepo")
    #expect(profiles.profile(named: "solo")?.harness == false)
    #expect(profiles.profile(named: nil) == nil)
}

@Test func profilesWithoutDefaultDecode() {
    let profiles = MacProfiles(payload: ["default_profile": "", "profiles": [] as [Any]])
    #expect(profiles?.defaultProfile == nil)
    #expect(profiles?.profiles.isEmpty == true)
}

// MARK: - Resolution

@Test(arguments: [
    ("x", ProjectConfig(profile: "rtd"), "p", ResolvedProfile(name: "x", strict: false)),
    // The New Task sheet prefills the project's profile: still the project's.
    ("rtd", ProjectConfig(profile: "rtd"), "p", ResolvedProfile(name: "rtd", strict: true)),
    (nil, ProjectConfig(profile: "rtd"), "p", ResolvedProfile(name: "rtd", strict: true)),
    (nil, ProjectConfig(profile: nil, mode: .terminal), "p", ResolvedProfile(name: "p", strict: false)),
    (nil, nil, nil, ResolvedProfile(name: nil, strict: false)),
] as [(String?, ProjectConfig?, String?, ResolvedProfile)])
func resolverPrecedence(task: String?, project: ProjectConfig?, settings: String?, want: ResolvedProfile) {
    #expect(LaunchProfileResolver.resolve(taskOverride: task, project: project, settingsProfile: settings) == want)
}

@Test func defaultLabelNamesTheRealProfile() {
    #expect(LaunchProfileResolver.defaultLabel(settingsProfile: "rtd", macDefault: "personal") == "По умолчанию (rtd — из настроек)")
    #expect(LaunchProfileResolver.defaultLabel(settingsProfile: nil, macDefault: "personal") == "Как на Маке (personal)")
    #expect(LaunchProfileResolver.defaultLabel(settingsProfile: nil, macDefault: nil) == "Как на Маке")
}

// MARK: - Terminal command

@Test func terminalCommandAddsLaunchArgsOnce() {
    let cmd = SessionLaunchMode.terminalCommand(
        cwd: "~/w/backend", prompt: nil, skipPermissions: true,
        launchArgs: ["--dangerously-skip-permissions", "--model", "opus 4"])
    #expect(cmd == "cd ~/'w/backend' && claude --dangerously-skip-permissions --model 'opus 4'")
}

@Test func terminalCommandWithoutLaunchArgsIsUnchanged() {
    #expect(SessionLaunchMode.terminalCommand(cwd: "~/w", prompt: "hi", skipPermissions: false, launchArgs: [])
        == SessionLaunchMode.terminalCommand(cwd: "~/w", prompt: "hi", skipPermissions: false))
}

// MARK: - Project configs

@Test func projectConfigsPersistAndOldFilesLoad() throws {
    let dir = try tempDir()
    let store = SessionsStore(directory: dir)
    let config = ProjectConfig(profile: "rtd", mode: .terminal)
    store.setProjectConfig(config, path: "~/w/backend", agentID: "mac-a")
    #expect(SessionsStore(directory: dir).projectConfig(path: "~/w/backend", agentID: "mac-a") == config)

    store.setProjectConfig(nil, path: "~/w/backend", agentID: "mac-a")
    #expect(SessionsStore(directory: dir).projectConfig(path: "~/w/backend", agentID: "mac-a") == nil)

    let legacy = try tempDir()
    let old = #"{"sessions":[],"recentsByAgent":{"mac-a":["~/w/x"]}}"#
    try Data(old.utf8).write(to: legacy.appendingPathComponent("sessions-store.json"))
    let loaded = SessionsStore(directory: legacy)
    #expect(loaded.recentProjects(forAgent: "mac-a") == ["~/w/x"])
    #expect(loaded.savedProjects(forAgent: "mac-a").isEmpty)
}

@Test func savedProjectsSurviveRecentsCap() throws {
    let store = SessionsStore(directory: try tempDir())
    store.setProjectConfig(ProjectConfig(profile: "rtd"), path: "~/w/backend", agentID: "mac-a")
    store.setProjectConfig(ProjectConfig(mode: .chat), path: "~/w/api", agentID: "mac-a")
    for i in 0..<9 { store.addRecentProject("~/w/p\(i)", agentID: "mac-a") }
    #expect(store.savedProjects(forAgent: "mac-a") == ["~/w/api", "~/w/backend"])
    #expect(store.savedProjects(forAgent: "mac-b").isEmpty)
}

@Test func suggestedConfigDropsMissingProfile() throws {
    let store = SessionsStore(directory: try tempDir())
    store.setProjectConfig(ProjectConfig(profile: "rtd", mode: .terminal), path: "~/w/backend", agentID: "mac-a")
    #expect(store.suggestedConfig(path: "~/w/backend", forAgent: "mac-b", available: ["personal"])
        == ProjectConfig(profile: nil, mode: .terminal))
    #expect(store.suggestedConfig(path: "~/w/backend", forAgent: "mac-b", available: ["rtd"])
        == ProjectConfig(profile: "rtd", mode: .terminal))
    #expect(store.suggestedConfig(path: "~/w/other", forAgent: "mac-b", available: ["rtd"]) == nil)
    // Its own config is not a suggestion.
    #expect(store.suggestedConfig(path: "~/w/backend", forAgent: "mac-a", available: ["rtd"]) == nil)
}

// MARK: - Session profile

@Test func persistedSessionKeepsProfile() throws {
    let session = PersistedSession(id: "s", agentID: "a", agentName: "Mac", customName: "n",
                                   createdAt: Date(timeIntervalSince1970: 0),
                                   profile: "rtd", profileStrict: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PersistedSession.self, from: encoder.encode(session))
    #expect(decoded.profile == "rtd" && decoded.profileStrict)

    let legacy = #"{"id":"s","agentID":"a","agentName":"Mac","customName":"n","createdAt":"1970-01-01T00:00:00Z"}"#
    let old = try decoder.decode(PersistedSession.self, from: Data(legacy.utf8))
    #expect(old.profile == nil && !old.profileStrict)
}

// MARK: - Review fixes

@Test(arguments: [
    (nil, false), ("2.1.0", false), ("2.2.0", true), ("2.2.0-3-gabc", true), ("3.0.0", true), ("dev", true),
] as [(String?, Bool)])
func strictProfilesNeedAgent22(version: String?, supported: Bool) {
    #expect(AgentVersion.supportsStrictProfiles(version) == supported)
}

@Test func defaultLabelInsideSavedProjectNamesTheProject() {
    #expect(LaunchProfileResolver.defaultLabel(settingsProfile: "work", macDefault: "personal", projectProfile: "rtd")
        == "Как в проекте (rtd)")
    #expect(LaunchProfileResolver.defaultLabel(settingsProfile: "work", macDefault: "personal", projectProfile: nil)
        == "По умолчанию (work — из настроек)")
}

@Test func recordedMacDefaultIsNotReplacedBySettings() {
    let launchedWithDefault = PersistedSession(id: "s", agentID: "a", agentName: "Mac", customName: "n",
                                               profile: nil, profileStrict: false, profileRecorded: true)
    #expect(launchedWithDefault.launchProfile(settingsProfile: "work") == ResolvedProfile(name: nil, strict: false))

    let named = PersistedSession(id: "s", agentID: "a", agentName: "Mac", customName: "n",
                                 profile: "rtd", profileStrict: true, profileRecorded: true)
    #expect(named.launchProfile(settingsProfile: "work") == ResolvedProfile(name: "rtd", strict: true))

    // Saved before profiles were recorded: Settings, as before.
    let legacy = PersistedSession(id: "s", agentID: "a", agentName: "Mac", customName: "n")
    #expect(legacy.launchProfile(settingsProfile: "work") == ResolvedProfile(name: "work", strict: false))
}

@Test func profileRecordedSurvivesRoundTrip() throws {
    let session = PersistedSession(id: "s", agentID: "a", agentName: "Mac", customName: "n",
                                   createdAt: Date(timeIntervalSince1970: 0), profileRecorded: true)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(PersistedSession.self, from: encoder.encode(session)).profileRecorded)
}
