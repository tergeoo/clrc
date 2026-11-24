import SwiftUI
import ClrcCore

/// A file opened from a folder listing.
struct FileRoute: Hashable {
    let agentID: String
    let path: String
}

/// Browses a Mac's folders in place: crumbs on top (tap to go up), search,
/// folders first. Files push a `FileRoute` in browse mode; pick mode ends
/// with «Выбрать «<папка>»».
struct FolderBrowser: View {
    enum Mode {
        case browse
        case pick((String) -> Void)
    }

    let agentID: String
    var mode: Mode = .browse
    @State var path: String
    /// Fixture listing (previews): shown instead of asking the Mac.
    var preloaded: [FSItem]?

    @EnvironmentObject var relay: RelayWebSocket
    @State private var items: [FSItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var deleteTarget: FSItem?

    private var client: FSClient { FSClient(relay: relay) }
    private var isPicking: Bool { if case .pick = mode { return true } else { return false } }

    var body: some View {
        List {
            Section {
                crumbs
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(Palette.red).font(.system(size: 14))
                    Button("Повторить") { Task { await load() } }
                }
            }
            Section {
                ForEach(FSListing.filtered(items, query: query)) { item in
                    row(item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Поиск по имени")
        .navigationTitle(PathCrumbs.crumbs(for: path).last?.name ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Новая папка", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        creatingFolder = true
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Ещё")
            }
        }
        .safeAreaInset(edge: .bottom) { pickBar }
        .task(id: path) { await load() }
        .refreshable { await load() }
        .alert("Новая папка", isPresented: $creatingFolder) {
            TextField("Имя", text: $newFolderName)
            Button("Создать") { Task { await makeFolder() } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await deleteTargetItem() } }
        } message: {
            Text("Это нельзя отменить.")
        }
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(PathCrumbs.crumbs(for: path)) { crumb in
                    Button(crumb.name) { path = crumb.path }
                        .font(.system(size: 14, weight: crumb.path == path ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(crumb.path == path ? Palette.text : Palette.tint)
                        .buttonStyle(.plain)
                        .frame(minHeight: 32)
                    if crumb.path != path {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.meta)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: FSItem) -> some View {
        let itemPath = PathCrumbs.join(path, item.name)
        let label = FSItemRow(item: item)
        if item.isDir {
            Button { path = itemPath } label: { label }
                .buttonStyle(.plain)
                .contextMenu { deleteButton(item) }
        } else if isPicking {
            label.foregroundStyle(Palette.meta)
        } else {
            NavigationLink(value: FileRoute(agentID: agentID, path: itemPath)) { label }
                .contextMenu { deleteButton(item) }
        }
    }

    private func deleteButton(_ item: FSItem) -> some View {
        Button("Удалить", systemImage: "trash", role: .destructive) { deleteTarget = item }
    }

    @ViewBuilder
    private var pickBar: some View {
        if case .pick(let choose) = mode {
            Button { choose(path) } label: {
                Text("Выбрать «\(PathCrumbs.crumbs(for: path).last?.name ?? path)»")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var deleteTitle: String { "Удалить «\(deleteTarget?.name ?? "")»?" }
    private var deleteShown: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - Requests

    private func load() async {
        if let preloaded {
            items = FSListing.sorted(preloaded)
            return
        }
        loading = true
        defer { loading = false }
        do {
            items = try await client.list(agentID: agentID, path: path).items
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        await perform { try await client.mkdir(agentID: agentID, path: PathCrumbs.join(path, name)) }
    }

    private func deleteTargetItem() async {
        guard let item = deleteTarget else { return }
        deleteTarget = nil
        await perform { try await client.delete(agentID: agentID, path: PathCrumbs.join(path, item.name)) }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FSItemRow: View {
    let item: FSItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kindSymbol)
                .font(.system(size: 16))
                .foregroundStyle(item.isDir ? Palette.tint : Palette.sec)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 16)).foregroundStyle(Palette.text).lineLimit(1)
                if !item.isDir {
                    Text(details).font(.system(size: 12)).foregroundStyle(Palette.meta)
                }
            }
            Spacer()
            if item.isDir {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.meta)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        guard let modified = item.modified else { return size }
        return size + " · " + modified.formatted(date: .abbreviated, time: .shortened)
    }
}

/// «Выбрать папку…» from the New Task sheet.
struct FolderPickerSheet: View {
    let agentID: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderBrowser(agentID: agentID, mode: .pick { path in
                choose(path)
                dismiss()
            }, path: "~")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
