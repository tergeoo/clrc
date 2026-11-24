import SwiftUI
import UIKit
import ClrcCore

/// Settings (spec 5.11): connection, Claude, terminal & code, integrations
/// (later), about, and a red «Опасная зона» at the bottom.
struct SettingsScreen: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager

    @AppStorage(RelayAddress.storageKey) private var relayURLString = RelayAddress.fallback
    /// The field's text; written to `relayURLString` only once it is valid.
    @State private var urlDraft = ""
    @AppStorage(ChatDisplayMode.storageKey) private var displayMode: ChatDisplayMode = .chat
    @AppStorage(SessionLaunchMode.terminalStorageKey) private var claudeInTerminal = false
    @AppStorage(ChatDisplayMode.profileStorageKey) private var profile = ""
    @AppStorage(UserPreferences.terminalFontKey) private var terminalFont = Double(TerminalFont.defaultSize)
    @AppStorage(UserPreferences.fileWrapKey) private var fileWrap = true

    @State private var showConnectMac = false
    @State private var confirmCloseAll = false
    @State private var confirmSignOut = false
    @State private var urlError: String?

    private var openSessions: Int { sessionManager.sessions.count + sessionManager.chatSessions.count }

    var body: some View {
        NavigationStack {
            Form {
                connection
                claude
                terminalAndCode
                integrations
                about
                dangerZone
            }
            .navigationTitle("Настройки")
            .onAppear { urlDraft = relayURLString }
            .sheet(isPresented: $showConnectMac) { ConnectMacSheet() }
            .confirmationDialog("Закрыть все сессии (\(openSessions))?", isPresented: $confirmCloseAll, titleVisibility: .visible) {
                Button("Закрыть все", role: .destructive) { sessionManager.closeEverything() }
            } message: {
                Text("Процессы на Маках будут остановлены.")
            }
            .confirmationDialog("Выйти?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    // Drop the socket too: the relay then detaches, so the
                    // PTYs keep running and reattach after the next sign-in.
                    PushManager.shared.unregister()
                    relay.disconnect()
                    authService.logout()
                }
            } message: {
                Text("Сессии на Маке продолжат работать — их можно будет открыть после входа.")
            }
        }
    }

    // MARK: - Groups

    private var connection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Relay URL", text: $urlDraft)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(applyURL)
                if let urlError {
                    Text(urlError).font(.system(size: 12)).foregroundStyle(Palette.red)
                }
            }
            HStack(spacing: 8) {
                StatusDot(color: statusColor, size: 9)
                Text(statusText).foregroundStyle(Palette.sec)
                Spacer()
                if relay.connectionState != .connected {
                    Button("Переподключить", action: applyURL)
                }
            }
            ForEach(relay.agents) { agent in
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").foregroundStyle(Palette.sec)
                    Text(agent.name)
                    Spacer()
                    StatusDot(color: agent.connected ? Palette.green : Palette.meta, size: 7)
                    Text(agent.connected ? "в сети" : "не в сети").font(.system(size: 13)).foregroundStyle(Palette.meta)
                }
            }
            Button("Подключить Мак", systemImage: "plus") { showConnectMac = true }
        } header: {
            Text("Подключение")
        }
    }

    private var claude: some View {
        Section {
            Picker("Вид по умолчанию", selection: launchMode) {
                Text("Chat").tag(SessionLaunchMode.chat)
                Text("Brief").tag(SessionLaunchMode.brief)
                Text("Terminal").tag(SessionLaunchMode.terminal)
            }
            TextField("Профиль (необязательно)", text: $profile)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            NavigationLink("Быстрые ответы") {
                ListEditor(title: "Быстрые ответы", key: UserPreferences.quickRepliesKey, defaults: QuickReplies.permanent)
            }
            NavigationLink("Шаблоны задач") {
                ListEditor(title: "Шаблоны задач", key: UserPreferences.templatesKey, defaults: NewTaskPlanner.templates)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text(profileFooter)
        }
    }

    private var terminalAndCode: some View {
        Section("Терминал и код") {
            Stepper(value: $terminalFont, in: Double(TerminalFont.range.lowerBound)...Double(TerminalFont.range.upperBound), step: 1) {
                HStack {
                    Text("Шрифт терминала")
                    Spacer()
                    Text("\(Int(terminalFont)) pt").foregroundStyle(Palette.meta).monospacedDigit()
                }
            }
            Toggle("Перенос строк в файлах", isOn: $fileWrap)
        }
    }

    private var integrations: some View {
        Section("Интеграции") {
            NavigationLink {
                GitLabSettingsView()
            } label: {
                LabeledContent {
                    Text(GitLabCredentials.api == nil ? "не подключён" : "подключён").foregroundStyle(Palette.meta)
                } label: {
                    Label("GitLab", systemImage: "arrow.triangle.branch")
                }
            }
            NavigationLink {
                NotificationSettingsView()
            } label: {
                Label("Уведомления", systemImage: "bell")
            }
        }
    }

    private var about: some View {
        Section("О приложении") {
            LabeledContent("Версия", value: version)
            Button {
                UIPasteboard.general.string = "clrc logs"
            } label: {
                LabeledContent("Логи агента") {
                    Text("clrc logs").font(.system(size: 14, design: .monospaced))
                }
            }
            .foregroundStyle(Palette.text)
        }
    }

    private var dangerZone: some View {
        Section {
            Button("Закрыть все сессии", role: .destructive) { confirmCloseAll = true }
                .disabled(openSessions == 0)
            Button("Выйти", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Опасная зона").foregroundStyle(Palette.red)
        }
    }

    // MARK: - Helpers

    private func soonRow(_ title: String, symbol: String) -> some View {
        LabeledContent {
            Text("скоро").foregroundStyle(Palette.meta)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var launchMode: Binding<SessionLaunchMode> {
        Binding(
            get: { SessionLaunchMode(displayMode: displayMode, inTerminal: claudeInTerminal) },
            set: { mode in
                claudeInTerminal = mode == .terminal
                if let display = mode.displayMode { displayMode = display }
            })
    }

    private var profileFooter: String {
        let trimmed = profile.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, normalizedProfile(trimmed) == nil {
            return "Только строчные латинские буквы, цифры и дефис — это значение не будет использовано."
        }
        return "Пустой профиль — профиль Мака по умолчанию (CLRC_PROFILE). Действует для новых сессий."
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var statusColor: Color {
        switch relay.connectionState {
        case .connected: return Palette.green
        case .connecting: return Palette.orange
        case .disconnected: return Palette.red
        }
    }

    private var statusText: String {
        switch relay.connectionState {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .disconnected: return "Нет связи"
        }
    }

    private func applyURL() {
        guard let url = RelayURL.normalize(urlDraft) else {
            urlError = "Проверьте адрес: например, http://192.168.1.5:8080"
            return
        }
        urlError = nil
        urlDraft = url.absoluteString
        relayURLString = url.absoluteString
        authService.updateRelayURL(url)
        relay.updateRelayURL(url)
        relay.connect()
    }
}

/// Reorder, delete and add items of a stored list.
struct ListEditor: View {
    let title: String
    let key: String
    let defaults: [String]

    @State private var items: [String] = []
    @State private var newItem = ""

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.self) { Text($0) }
                    .onDelete { items.remove(atOffsets: $0); save() }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1); save() }
            }
            Section {
                HStack {
                    TextField("Добавить", text: $newItem).onSubmit(add)
                    Button("Добавить", action: add)
                        .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Button("Вернуть стандартные") {
                    items = defaults
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        .navigationTitle(title)
        .toolbar { EditButton() }
        .onAppear { items = StoredList.decode(UserDefaults.standard.string(forKey: key), defaults: defaults) }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !items.contains(item) else { return }
        items.append(item)
        newItem = ""
        save()
    }

    private func save() {
        UserDefaults.standard.set(StoredList.encode(items), forKey: key)
    }
}

/// Settings → Уведомления: which report statuses send a push.
struct NotificationSettingsView: View {
    @AppStorage(PushNotify.storageKey) private var stored = PushNotify.encode(PushNotify.allStatuses)

    private static let labels = ["needs_input": "Ждёт ответа", "failed": "Ошибка", "done": "Готово"]

    var body: some View {
        Form {
            Section {
                ForEach(PushNotify.allStatuses, id: \.self) { status in
                    Toggle(Self.labels[status] ?? status, isOn: binding(status))
                }
            } footer: {
                Text("Push приходит, когда Claude заканчивает ход с этим статусом. На вопросы можно ответить прямо из уведомления. Нужен relay с настроенными APNS_*.")
            }
        }
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ status: String) -> Binding<Bool> {
        Binding(
            get: { PushNotify.decode(stored).contains(status) },
            set: { on in
                var set = Set(PushNotify.decode(stored))
                if on { set.insert(status) } else { set.remove(status) }
                stored = PushNotify.encode(PushNotify.allStatuses.filter(set.contains))
                PushManager.shared.registerWithRelay()
            })
    }
}
