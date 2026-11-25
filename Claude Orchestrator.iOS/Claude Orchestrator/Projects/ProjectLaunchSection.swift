import SwiftUI
import ClrcCore

/// «Запуск» on a project screen: the project's Claude profile and mode.
/// Any change saves the project; «Убрать из проектов» forgets the config.
struct ProjectLaunchSection: View {
    let agentID: String
    let path: String

    @EnvironmentObject var sessionManager: SessionManager

    private var saved: ProjectConfig? { sessionManager.projectConfig(path: path, agentID: agentID) }
    /// What the pickers show is exactly what a launch uses: the saved config
    /// or the defaults. Another Mac's config is only offered as a button.
    private var shown: ProjectConfig { saved ?? ProjectConfig() }
    private var suggestion: ProjectConfig? {
        saved == nil ? sessionManager.suggestedConfig(path: path, agentID: agentID) : nil
    }
    private var profiles: MacProfiles? { sessionManager.profiles(for: agentID) }

    var body: some View {
        Section {
            if let suggestion {
                Button {
                    sessionManager.setProjectConfig(suggestion, path: path, agentID: agentID)
                } label: {
                    Label("Как на другом Маке: \([suggestion.profile, suggestion.mode?.title].compactMap { $0 }.joined(separator: " · "))",
                          systemImage: "arrow.down.doc")
                }
            }
            ProfilePicker(
                title: "Профиль Claude",
                selection: Binding(get: { shown.profile }, set: { update(profile: $0, mode: shown.mode) }),
                profiles: profiles,
                unavailable: sessionManager.profilesUnavailable.contains(agentID),
                defaultLabel: LaunchProfileResolver.defaultLabel(settingsProfile: sessionManager.settingsProfile,
                                                                 macDefault: profiles?.defaultProfile))
            Picker("Режим", selection: Binding(get: { shown.mode }, set: { update(profile: shown.profile, mode: $0) })) {
                Text("Как в настройках").tag(SessionLaunchMode?.none)
                ForEach(SessionLaunchMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(Optional(mode))
                }
            }
            if saved != nil {
                Button("Убрать из проектов", role: .destructive) {
                    sessionManager.setProjectConfig(nil, path: path, agentID: agentID)
                }
            }
        } header: {
            Text("Запуск")
        } footer: {
            Text(saved == nil
                 ? "Выберите профиль или режим — проект сохранится с этими настройками."
                 : "Сохранённый профиль обязателен: если его нет на Маке, запуск не произойдёт.")
        }
        .task { sessionManager.loadProfiles(agentID: agentID) }
    }

    private func update(profile: String?, mode: SessionLaunchMode?) {
        sessionManager.setProjectConfig(ProjectConfig(profile: profile, mode: mode), path: path, agentID: agentID)
    }
}
