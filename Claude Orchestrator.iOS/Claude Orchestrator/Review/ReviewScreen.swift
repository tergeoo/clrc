import SwiftUI
import ClrcCore

/// «Ревью» tab (spec 5.7): «От Claude» — turns that changed files — and
/// «GitLab» merge requests.
struct ReviewScreen: View {
    enum Source: Hashable { case claude, gitlab }

    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @State private var path = NavigationPath()
    @State private var source: Source = .claude

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Источник", selection: $source) {
                    Text("От Claude").tag(Source.claude)
                    Text("GitLab").tag(Source.gitlab)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                switch source {
                case .claude: ClaudeReviewList()
                case .gitlab: GitLabReviewPlaceholder()
                }
            }
            .background(Palette.bg)
            .navigationTitle("Ревью")
            .diffDestinations()
            .fileDestinations()
        }
        .environment(\.openDiff) { path.append($0) }
    }
}

/// Viewed review items, kept between launches (bounded).
enum ReviewedTurns {
    static let key = "reviewed_turns"
    static let limit = 500

    static func load() -> Set<String> {
        Set(StoredList.decode(UserDefaults.standard.string(forKey: key), defaults: []))
    }

    static func mark(_ id: String) {
        var items = StoredList.decode(UserDefaults.standard.string(forKey: key), defaults: [])
        guard !items.contains(id) else { return }
        items.append(id)
        UserDefaults.standard.set(StoredList.encode(Array(items.suffix(limit))), forKey: key)
    }
}

struct ClaudeReviewList: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.openDiff) private var openDiff
    @State private var viewed = ReviewedTurns.load()
    @State private var project: String?

    private var items: [ReviewItem] {
        ReviewItems.build(sessions: sessionManager.chatSessions.map {
            ReviewSessionSnapshot(sessionID: $0.id, agentID: $0.agent.id, agentName: $0.agent.name,
                                  cwd: $0.cwd, turns: $0.transcript.turns)
        }, viewed: viewed)
    }

    var body: some View {
        let all = items
        let shown = ReviewItems.filter(all, project: project)
        if all.isEmpty {
            ContentUnavailableView("Нечего ревьюить", systemImage: "checkmark.seal",
                                   description: Text("Здесь появятся ходы Claude, которые меняли файлы."))
        } else {
            List {
                if ReviewItems.projects(all).count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip("Все", selected: project == nil) { project = nil }
                            ForEach(ReviewItems.projects(all), id: \.self) { name in
                                filterChip(name, selected: project == name) { project = name }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(shown) { item in
                    Button { open(item) } label: { ReviewRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func open(_ item: ReviewItem) {
        ReviewedTurns.mark(item.id)
        viewed.insert(item.id)
        openDiff(DiffRoute(agentID: item.agentID, repo: item.cwd,
                           files: DiffPaths.relative(item.files, to: item.cwd), title: item.title))
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .foregroundStyle(selected ? Color.white : Palette.text)
                .background(selected ? Palette.tint : Palette.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                label
            }
            Text("\(item.project) · \(item.agentName) · ход \(item.turnNumber) · "
                 + ru(item.files.count, one: "файл", few: "файла", many: "файлов"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.meta)
        }
        .padding(.vertical, 4)
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var label: some View {
        switch item.label {
        case .waiting: tag("ждёт ответа", Palette.orange)
        case .new: tag("новое", Palette.tint)
        case .viewed: tag("просмотрено", Palette.meta)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Until GitLab is connected (stage 6b).
struct GitLabReviewPlaceholder: View {
    var body: some View {
        ContentUnavailableView("Подключите GitLab", systemImage: "arrow.triangle.branch",
                               description: Text("Укажите адрес GitLab и токен в Настройках."))
    }
}
