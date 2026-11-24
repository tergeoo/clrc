import SwiftUI
import ClrcCore

/// A merge request opened from the list.
struct MergeRequestRoute: Hashable {
    let projectID: Int
    let iid: Int
    let title: String
}

/// «Ревью → GitLab»: open merge requests by scope.
struct MergeRequestList: View {
    @State private var scope: GitLabScope = .assigned
    @State private var items: [GitLabMR] = []
    @State private var loading = false
    @State private var error: String?
    /// Fixture list (previews).
    var preloaded: [GitLabMR]?

    var body: some View {
        if GitLabClient() == nil && preloaded == nil {
            GitLabReviewPlaceholder()
        } else {
            List {
                Picker("Фильтр", selection: $scope) {
                    Text("Назначены мне").tag(GitLabScope.assigned)
                    Text("Мои").tag(GitLabScope.mine)
                    Text("Все").tag(GitLabScope.all)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                if let error {
                    Section {
                        Text(error).foregroundStyle(Palette.red).font(.system(size: 14))
                        Button("Повторить") { Task { await load() } }
                    }
                }
                if items.isEmpty && !loading && error == nil {
                    Text("Открытых merge request нет").foregroundStyle(Palette.meta)
                }
                ForEach(items) { mr in
                    NavigationLink(value: MergeRequestRoute(projectID: mr.projectID, iid: mr.iid, title: mr.title)) {
                        MergeRequestRow(mr: mr)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { if loading && items.isEmpty { ProgressView() } }
            .task(id: scope) { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        if let preloaded { items = preloaded; return }
        guard let client = GitLabClient() else { return }
        let requested = scope
        loading = true
        defer { loading = false }
        do {
            let list = try await client.send(.mergeRequests(requested), as: [GitLabMR].self)
            guard requested == scope else { return }
            items = list
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MergeRequestRow: View {
    let mr: GitLabMR

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if mr.draft {
                    Text("Draft").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.meta)
                        .padding(.horizontal, 6).frame(height: 18).background(Palette.fill, in: Capsule())
                }
                Text(mr.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
            }
            Text("\(mr.reference) · \(mr.author.name)")
                .font(.system(size: 12)).foregroundStyle(Palette.sec).lineLimit(1)
            HStack(spacing: 8) {
                Text("\(mr.sourceBranch) → \(mr.targetBranch)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.meta).lineLimit(1).truncationMode(.middle)
                if mr.userNotesCount > 0 {
                    Label("\(mr.userNotesCount)", systemImage: "bubble.left").font(.system(size: 12)).foregroundStyle(Palette.meta)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pipeline status as icon + word (never color alone).
struct PipelineBadge: View {
    let status: String

    var body: some View {
        let (symbol, text, color) = style
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    private var style: (String, String, Color) {
        switch status {
        case "success": return ("checkmark.circle.fill", "пайплайн прошёл", Palette.green)
        case "failed": return ("xmark.circle.fill", "пайплайн упал", Palette.red)
        case "running", "pending", "created", "preparing", "waiting_for_resource":
            return ("circle.dashed", "пайплайн идёт", Palette.tint)
        case "canceled", "skipped": return ("minus.circle", "пайплайн отменён", Palette.meta)
        default: return ("circle", status, Palette.meta)
        }
    }
}
