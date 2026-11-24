import Foundation

/// Everything needed to start one session from the New Task sheet.
public struct LaunchRequest: Sendable, Equatable {
    public let agentID: String
    /// nil = the Mac user's home folder.
    public let cwd: String?
    public let mode: SessionLaunchMode
    /// The first message for Claude; nil starts the session without one.
    public let prompt: String?
    public let name: String
    public let model: String?
    public let profile: String?
    /// Terminal launches only: `claude --dangerously-skip-permissions`.
    public let skipPermissions: Bool
}

public enum NewTaskPlanner {
    public static let templates = ["Почини тесты", "Сделай ревью ветки", "Объясни код", "Обнови зависимости"]
    static let fallbackName = "claude"

    /// The Mac preselected in the sheet: the preferred one if online, else
    /// the Mac of the most recent project, else the first online Mac.
    public static func defaultAgentID(onlineAgentIDs: [String], preferred: String?,
                                      lastProjectAgentID: String?) -> String? {
        if let preferred, onlineAgentIDs.contains(preferred) { return preferred }
        if let last = lastProjectAgentID, onlineAgentIDs.contains(last) { return last }
        return onlineAgentIDs.first
    }

    /// Normalizes the sheet's raw inputs: blanks become nil, `~` means home,
    /// the name falls back to the project folder, the profile must be valid.
    public static func request(agentID: String, cwd: String?, mode: SessionLaunchMode, prompt: String,
                               customName: String, model: String, profile: String,
                               skipPermissions: Bool = false) -> LaunchRequest {
        let folder = (cwd == "~" || cwd?.isEmpty == true) ? nil : cwd
        let skip = skipPermissions && mode == .terminal
        let baseName = nonEmpty(customName) ?? folder.map { ($0 as NSString).lastPathComponent } ?? fallbackName
        // A dangerous session stays marked wherever its name is shown.
        let name = skip && !baseName.hasSuffix(dangerMarker) ? baseName + " " + dangerMarker : baseName
        return LaunchRequest(agentID: agentID, cwd: folder, mode: mode, prompt: nonEmpty(prompt),
                             name: name, model: nonEmpty(model), profile: normalizedProfile(profile),
                             // Chat sessions already run with bypassPermissions on the agent.
                             skipPermissions: skip)
    }

    static let dangerMarker = "⚠"

    /// What «Перезапустить» runs for a terminal launch: Claude in the same
    /// folder — never the original task again, never without permissions.
    public static func restartCommand(for request: LaunchRequest) -> String {
        SessionLaunchMode.terminalCommand(cwd: request.cwd, prompt: nil, skipPermissions: false)
    }

    /// Tapping a recent project launches at once only when no task was typed.
    public static func launchesOnProjectTap(prompt: String) -> Bool {
        nonEmpty(prompt) == nil
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
