import SwiftUI
import UIKit
import ClrcCore

/// One merge request (spec 5.8): branches, pipeline, description, files
/// with +/− and «просмотрен»; Approve · Комментарий · «···» (Merge,
/// Закрыть, Открыть в браузере) with confirmations.
struct MergeRequestScreen: View {
    let route: MergeRequestRoute
    /// Fixture data (previews): skips the requests.
    var preloaded: (GitLabMR, [GitLabDiffEntry], [GitLabDiscussion])?

    @Environment(\.dismiss) private var dismiss
    @State private var mr: GitLabMR?
    @State private var entries: [GitLabDiffEntry] = []
    @State private var discussions: [GitLabDiscussion] = []
    @State private var error: String?
    @State private var showHidden = false
    @State private var showDescription = false
    @State private var viewed: Set<String> = []
    @State private var openIndex: Int?
    @State private var composing = false
    @State private var comment = ""
    @State private var confirm: ConfirmAction?
    @State private var toast: String?
    @State private var askClaude = false

    enum ConfirmAction: Identifiable {
        case merge, close
        var id: Int { self == .merge ? 0 : 1 }
    }

    private var visibleEntries: [GitLabDiffEntry] { showHidden ? entries : entries.filter { !GitLabDiffs.isHidden($0) } }
    private var hiddenCount: Int { entries.filter(GitLabDiffs.isHidden).count }
    private var files: [DiffFile] { GitLabDiffs.files(visibleEntries) }
    private var threadCount: Int { discussions.filter { $0.notes.contains { !$0.system } }.count }

    var body: some View {
        Group {
            if let mr {
                content(mr)
            } else if let error {
                ContentUnavailableView {
                    Label(error, systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Повторить") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("!\(route.iid)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .navigationDestination(item: $openIndex) { index in
            GitLabFileDiff(files: files, index: index, viewed: $viewed, discussions: discussions,
                           refs: mr?.diffRefs, projectID: route.projectID, iid: route.iid) {
                Task { await reloadDiscussions() }
            }
        }
        .alert("Комментарий", isPresented: $composing) {
            TextField("Текст", text: $comment, axis: .vertical)
            Button("Отправить") { Task { await perform(.note(project: route.projectID, iid: route.iid, body: comment), done: "Комментарий отправлен") } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(confirmTitle, isPresented: confirmShown, titleVisibility: .visible) {
            if confirm == .merge {
                Button("Слить", role: .destructive) { Task { await perform(.merge(project: route.projectID, iid: route.iid), done: "MR слит") } }
            } else {
                Button("Закрыть MR", role: .destructive) { Task { await perform(.close(project: route.projectID, iid: route.iid), done: "MR закрыт") } }
            }
        }
        .sheet(isPresented: $askClaude) {
            if let mr {
                NewTaskSheet(initialPrompt: "Сделай ревью merge request \(mr.reference) (\(mr.sourceBranch) → \(mr.targetBranch)): \(mr.webURL)")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(text: toast).padding(.bottom, 80).transition(.opacity)
            }
        }
    }

    private func content(_ mr: GitLabMR) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(mr.title).font(.system(size: 20, weight: .bold))
                    Text("\(mr.reference) · \(mr.author.name)").font(.system(size: 13)).foregroundStyle(Palette.sec)
                    Text("\(mr.sourceBranch) → \(mr.targetBranch)")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.meta)
                    if let pipeline = mr.headPipeline {
                        if let link = pipeline.webURL.flatMap(URL.init(string:)) {
                            Link(destination: link) { PipelineBadge(status: pipeline.status) }
                        } else {
                            PipelineBadge(status: pipeline.status)
                        }
                    }
                }
                .padding(.vertical, 4)
                if let description = mr.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MarkdownView(text: description).lineLimit(showDescription ? nil : 4)
                        Button(showDescription ? "Свернуть" : "Ещё") { showDescription.toggle() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                Button("Попросить Claude сделать ревью", systemImage: "sparkles") { askClaude = true }
            }
            Section {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    Button { openIndex = index } label: { ChangedFileRow(file: file, viewed: viewed.contains(file.id)) }
                        .buttonStyle(.plain)
                }
                if hiddenCount > 0 {
                    Button(showHidden ? "Скрыть lock-файлы" : "Показать скрытые (\(hiddenCount))") { showHidden.toggle() }
                }
            } header: {
                Text("\(viewed.count) из \(files.count) просмотрено"
                     + (threadCount > 0 ? " · " + ru(threadCount, one: "обсуждение", few: "обсуждения", many: "обсуждений") : ""))
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { bottomBar(mr) }
        .refreshable { await load() }
    }

    private func bottomBar(_ mr: GitLabMR) -> some View {
        HStack(spacing: 8) {
            Button { Task { await perform(.approve(project: route.projectID, iid: route.iid), done: "Одобрено") } } label: {
                Label("Approve", systemImage: "hand.thumbsup")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Palette.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button { comment = ""; composing = true } label: {
                Label("Комментарий", systemImage: "bubble.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Menu {
                Button("Слить (Merge)", systemImage: "arrow.triangle.merge") { confirm = .merge }
                Button("Закрыть MR", systemImage: "xmark.circle", role: .destructive) { confirm = .close }
                if let url = URL(string: mr.webURL) {
                    Link(destination: url) { Label("Открыть в браузере", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel("Ещё действия")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var confirmTitle: String { confirm == .merge ? "Слить !\(route.iid) в целевую ветку?" : "Закрыть !\(route.iid) без слияния?" }
    private var confirmShown: Binding<Bool> { Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }) }

    // MARK: - Requests

    private func load() async {
        if let preloaded {
            (mr, entries, discussions) = preloaded
            return
        }
        guard let client = GitLabClient() else { error = GitLabError.notConfigured.localizedDescription; return }
        do {
            async let detail = client.send(.mergeRequest(project: route.projectID, iid: route.iid), as: GitLabMR.self)
            async let diffs = client.send(.diffs(project: route.projectID, iid: route.iid), as: [GitLabDiffEntry].self)
            async let threads = client.send(.discussions(project: route.projectID, iid: route.iid), as: [GitLabDiscussion].self)
            (mr, entries, discussions) = try await (detail, diffs, threads)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reloadDiscussions() async {
        guard preloaded == nil, let client = GitLabClient() else { return }
        if let threads = try? await client.send(.discussions(project: route.projectID, iid: route.iid), as: [GitLabDiscussion].self) {
            discussions = threads
        }
    }

    private func perform(_ endpoint: GitLabEndpoint, done: String) async {
        guard let client = GitLabClient() else { return }
        do {
            try await client.send(endpoint)
            show(done)
            if case .merge = endpoint { dismiss() } else if case .close = endpoint { dismiss() } else { await load() }
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if toast == text { toast = nil } }
        }
    }
}
