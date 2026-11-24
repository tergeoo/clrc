import SwiftUI
import UIKit
import ClrcCore

/// «Новая задача»: Мак → проект → задача → режим → Запустить (brief §5.3).
/// Opens at medium height with nothing focused; tapping a recent project
/// with an empty task launches at once.
struct NewTaskSheet: View {
    var preferredAgentID: String?
    var onLaunched: (SessionRoute) -> Void = { _ in }

    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ChatDisplayMode.storageKey) private var displayMode: ChatDisplayMode = .chat
    @AppStorage(SessionLaunchMode.terminalStorageKey) private var claudeInTerminal = false
    @AppStorage(ChatDisplayMode.profileStorageKey) private var storedProfile = ""

    @State private var agentID: String?
    @State private var projectPath: String?
    @State private var prompt = ""
    @State private var mode: SessionLaunchMode = .chat
    @State private var customName = ""
    @State private var model = ""
    @State private var profile = ""
    @State private var showAdvanced = false
    @State private var showBrowser = false
    @State private var detent: PresentationDetent = .medium
    @FocusState private var promptFocused: Bool

    private static let maxRecents = 5
    private static let homePath = "~"

    private var onlineAgents: [Agent] { relay.agents.filter(\.connected) }
    private var agent: Agent? { onlineAgents.first { $0.id == agentID } }
    private var recents: [String] {
        agent.map { Array(sessionManager.recentProjects(for: $0).prefix(Self.maxRecents)) } ?? []
    }
    private var projectName: String {
        guard let projectPath, projectPath != Self.homePath else { return "домашней папке" }
        return (projectPath as NSString).lastPathComponent
    }

    var body: some View {
        NavigationStack {
            Group {
                if onlineAgents.isEmpty {
                    ContentUnavailableView("Нет Маков в сети", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                           description: Text("Запустите clrc на Маке, и он появится здесь."))
                } else {
                    form
                }
            }
            .background(Palette.bg)
            .navigationTitle("Новая задача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { promptFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Спрятать клавиатуру")
                    Spacer()
                    Button("Запустить") { launch() }.fontWeight(.semibold).disabled(agent == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !onlineAgents.isEmpty && !promptFocused { bottomBar }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear(perform: setUp)
        .onChange(of: promptFocused) { _, focused in
            if focused { detent = .large }
        }
        .onChange(of: agentID) { _, _ in projectPath = recents.first ?? Self.homePath }
        .sheet(isPresented: $showBrowser) {
            if let agent {
                FileBrowserView(agentID: agent.id, agentName: agent.name, embedded: false, showDangerousOption: false) { path, _ in
                    showBrowser = false
                    projectPath = path
                }
                .environmentObject(relay)
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if promptFocused {
                    compactSummary
                } else {
                    if onlineAgents.count > 1 { macChips }
                    projectList
                }
                taskField
                if !promptFocused {
                    modePicker
                    advanced
                }
            }
            .padding(16)
            .animation(.easeOut(duration: Metrics.transition), value: promptFocused)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var macChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Мак")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(onlineAgents) { mac in
                        Chip(title: mac.name, selected: mac.id == agentID) { agentID = mac.id }
                    }
                }
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Проект")
            VStack(spacing: 0) {
                ForEach(recents, id: \.self) { path in
                    ProjectRow(name: (path as NSString).lastPathComponent, path: path,
                               selected: path == projectPath) { tapProject(path) }
                    Divider().padding(.leading, 14)
                }
                ProjectRow(name: "Домашняя папка", path: Self.homePath,
                           selected: projectPath == Self.homePath) { tapProject(Self.homePath) }
                Divider().padding(.leading, 14)
                Button { showBrowser = true } label: {
                    Label("Выбрать папку…", systemImage: "folder")
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget + 4, alignment: .leading)
                        .padding(.horizontal, 14)
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    private var taskField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Задача")
            TextField("Что сделать? (необязательно)", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .focused($promptFocused)
                .font(.system(size: 16))
                .cardStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(NewTaskPlanner.templates, id: \.self) { template in
                        Chip(title: template, selected: false) { prompt = template }
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Режим")
            Picker("Режим", selection: $mode) {
                Text("Chat").tag(SessionLaunchMode.chat)
                Text("Brief").tag(SessionLaunchMode.brief)
                Text("Terminal").tag(SessionLaunchMode.terminal)
            }
            .pickerStyle(.segmented)
            Text(modeHint)
                .font(.system(size: 13))
                .foregroundStyle(Palette.meta)
        }
    }

    private var modeHint: String {
        switch mode {
        case .chat: return "Ответ текстом, итог в конце"
        case .brief: return "Сначала итог, текст свёрнут"
        case .terminal: return "claude в терминале, как на Маке"
        }
    }

    private var advanced: some View {
        DisclosureGroup("Дополнительно", isExpanded: $showAdvanced) {
            VStack(spacing: 0) {
                AdvancedField(title: "Имя сессии", text: $customName, placeholder: projectName)
                Divider().padding(.leading, 14)
                AdvancedField(title: "Модель", text: $model, placeholder: "по умолчанию")
                Divider().padding(.leading, 14)
                AdvancedField(title: "Профиль Claude", text: $profile, placeholder: "по умолчанию")
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .padding(.top, 8)
        }
        .font(.system(size: 15))
        .tint(Palette.sec)
    }

    /// While typing, Мак · проект · режим shrink to one row of chips.
    private var compactSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let agent { Chip(title: agent.name, selected: true) { promptFocused = false } }
                Chip(title: projectName, selected: true) { promptFocused = false }
                Chip(title: mode.rawValue.capitalized, selected: true) { promptFocused = false }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Button(action: launch) {
                Text("Запустить в \(projectName)")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(agent == nil)
            Button("Пустой терминал", action: launchEmptyTerminal)
                .font(.system(size: 15))
                .frame(minHeight: Metrics.minTapTarget)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func setUp() {
        mode = SessionLaunchMode(displayMode: displayMode, inTerminal: claudeInTerminal)
        profile = storedProfile
        let lastProjectAgent = onlineAgents.first { !sessionManager.recentProjects(for: $0).isEmpty }?.id
        agentID = NewTaskPlanner.defaultAgentID(onlineAgentIDs: onlineAgents.map(\.id),
                                                preferred: preferredAgentID,
                                                lastProjectAgentID: lastProjectAgent)
        projectPath = recents.first ?? Self.homePath
    }

    private func tapProject(_ path: String) {
        projectPath = path
        if NewTaskPlanner.launchesOnProjectTap(prompt: prompt) { launch() }
    }

    private func launch() {
        guard let agent else { return }
        let request = NewTaskPlanner.request(agentID: agent.id, cwd: projectPath, mode: mode, prompt: prompt,
                                             customName: customName, model: model, profile: profile)
        finish(sessionManager.launch(request))
    }

    private func launchEmptyTerminal() {
        guard let agent else { return }
        finish(sessionManager.launchEmptyTerminal(agentID: agent.id))
    }

    private func finish(_ route: SessionRoute?) {
        guard let route else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
        onLaunched(route)
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? Color.white : Palette.text)
                .background(selected ? Palette.tint : Palette.card, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Metrics.minTapTarget)
    }
}

private struct ProjectRow: View {
    let name: String
    let path: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.meta).lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.tint)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AdvancedField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(Palette.text)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Metrics.minTapTarget + 4)
    }
}
