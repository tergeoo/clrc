import SwiftUI

// MARK: - FSEntry model

struct FSEntry: Identifiable {
    let id = UUID()
    let name: String
    let isDir: Bool
    let size: Int64
    let modTime: Date

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let isDir = dict["is_dir"] as? Bool else { return nil }
        self.name = name
        self.isDir = isDir
        self.size = (dict["size"] as? Int).map(Int64.init) ?? 0
        let iso = ISO8601DateFormatter()
        self.modTime = (dict["mod_time"] as? String).flatMap { iso.date(from: $0) } ?? Date()
    }
}

// MARK: - Path segment (Identifiable for ForEach)

struct PathSegment: Identifiable {
    let id = UUID()
    let path: String
    let name: String
}

// MARK: - FileViewerItem

struct FileViewerItem: Identifiable {
    let id = UUID()
    let name: String
    let content: String
}

// MARK: - FileBrowserView

struct FileBrowserView: View {
    let agentID: String
    let agentName: String
    /// When true the view is shown inline (no NavigationStack, no Done button).
    var embedded: Bool = false
    let onLaunchClaude: (_ path: String, _ dangerous: Bool) -> Void

    @EnvironmentObject var relay: RelayWebSocket
    @Environment(\.dismiss) private var dismiss

    @State private var pathStack: [PathSegment] = [PathSegment(path: "~", name: "Home")]
    @State private var entries: [FSEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showMkdir = false
    @State private var newFolderName = ""
    @State private var mkdirError: String?
    @State private var isMkdirLoading = false

    @State private var viewingFile: FileViewerItem?
    @State private var entryToDelete: FSEntry?

    @State private var showPathInput = false
    @State private var customPath = ""

    var currentPath: String { pathStack.last?.path ?? "~" }

    /// True when we're NOT at the filesystem root "/"
    private var canGoUp: Bool {
        guard let p = pathStack.last?.path else { return false }
        return p != "/" && p != "~"
    }

    var body: some View {
        if embedded {
            fileBrowserContent
                .onAppear { loadDirectory("~") }
        } else {
            NavigationStack {
                fileBrowserContent
                    .navigationTitle(pathStack.last?.name ?? agentName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent }
            }
            .onAppear { loadDirectory("~") }
        }
    }

    // MARK: - Shared content

    private var fileBrowserContent: some View {
        ZStack(alignment: .bottom) {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                if embedded { embeddedActionBar; Divider() }
                breadcrumbBar
                Divider()
                contentArea
            }

            claudeLaunchBar
                .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showMkdir) { mkdirSheet }
        .sheet(isPresented: $showPathInput) { pathInputSheet }
        .sheet(item: $viewingFile) { item in FileViewerView(item: item) }
        .confirmationDialog(
            "Delete \"\(entryToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { if !$0 { entryToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let e = entryToDelete { performDelete(e) }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) { entryToDelete = nil }
        } message: {
            if entryToDelete?.isDir == true {
                Text("This will permanently delete the folder and all its contents.")
            }
        }
    }

    // MARK: - Embedded action bar (replaces NavigationStack toolbar)

    private var embeddedActionBar: some View {
        HStack(spacing: 4) {
            // "/" root
            Button { navigateTo("/") } label: {
                Text("/")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Current dir title
            Text(pathStack.last?.name ?? agentName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            // Go up
            Button { goUp() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canGoUp)
            .opacity(canGoUp ? 1 : 0.35)

            // Jump to path
            Button { customPath = currentPath; showPathInput = true } label: {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // New folder
            Button { newFolderName = ""; mkdirError = nil; isMkdirLoading = false; showMkdir = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: - Path input sheet

    private var pathInputSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Enter absolute path")) {
                    TextField("/path/to/directory", text: $customPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section {
                    Button("/  — Root") { navigateTo("/") }
                    Button("~  — Home") { navigateTo("~") }
                }
            }
            .navigationTitle("Go to Path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPathInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { navigateTo(customPath) }
                        .disabled(customPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func navigateTo(_ path: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        showPathInput = false
        let name: String
        if p == "/" { name = "/" }
        else if p == "~" { name = "Home" }
        else { name = URL(fileURLWithPath: p).lastPathComponent }
        pathStack = [PathSegment(path: p, name: name)]
        loadDirectory(p)
    }

    // MARK: - Breadcrumb

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // "/" root shortcut
                    Button {
                        navigateTo("/")
                    } label: {
                        Text("/")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    ForEach(Array(pathStack.enumerated()), id: \.element.id) { idx, seg in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        let isLast = idx == pathStack.count - 1
                        Button {
                            guard !isLast else { return }
                            pathStack = Array(pathStack.prefix(idx + 1))
                            loadDirectory(seg.path)
                        } label: {
                            Text(seg.name)
                                .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                                .foregroundStyle(isLast ? Color.primary : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    isLast
                                        ? Color(UIColor.secondarySystemGroupedBackground)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: pathStack.count) { _, _ in
                withAnimation { proxy.scrollTo(pathStack.count - 1) }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { loadDirectory(currentPath) }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Empty folder")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(entries) { entry in
                    entryRow(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                entryToDelete = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .refreshable { loadDirectory(currentPath) }
            .padding(.bottom, 80)
        }
    }

    // MARK: - Entry row

    private func entryRow(_ entry: FSEntry) -> some View {
        Button {
            if entry.isDir {
                let newPath = joinPath(currentPath, entry.name)
                pathStack.append(PathSegment(path: newPath, name: entry.name))
                loadDirectory(newPath)
            } else {
                loadFile(entry)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground(entry))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName(entry))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconForeground(entry))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(entry.isDir ? formatDate(entry.modTime) : formatSize(entry.size))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                if entry.isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Claude launch bar

    private var claudeLaunchBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    onLaunchClaude(currentPath, false)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Claude here")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    onLaunchClaude(currentPath, true)
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Dangerous")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(Color.orange)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Go up one level
            Button {
                goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!canGoUp)

            // Jump to arbitrary path
            Button {
                customPath = currentPath
                showPathInput = true
            } label: {
                Image(systemName: "link")
            }

            // Create folder
            Button {
                newFolderName = ""
                mkdirError = nil
                isMkdirLoading = false
                showMkdir = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
        }
    }

    // MARK: - Navigation helpers

    private func goUp() {
        let path = currentPath
        guard path != "/" else { return }
        let parent: String
        if path == "~" {
            return
        } else {
            let url = URL(fileURLWithPath: path)
            parent = url.deletingLastPathComponent().path
        }
        let name = URL(fileURLWithPath: parent).lastPathComponent
        let displayName = parent == "/" ? "/" : name
        // Pop to matching existing segment or push new one
        if let idx = pathStack.firstIndex(where: { $0.path == parent }) {
            pathStack = Array(pathStack.prefix(idx + 1))
        } else {
            pathStack.append(PathSegment(path: parent, name: displayName))
        }
        loadDirectory(parent)
    }

    // MARK: - Mkdir sheet

    private var mkdirSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("New folder in \(pathStack.last?.name ?? "")")) {
                    TextField("Folder name", text: $newFolderName)
                        .autocorrectionDisabled()
                }
                if let err = mkdirError {
                    Section {
                        Text(err).foregroundStyle(Color.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Create Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMkdir = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isMkdirLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { performMkdir() }
                            .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Network

    private func loadDirectory(_ path: String) {
        isLoading = true
        errorMessage = nil
        let reqID = UUID().uuidString
        relay.sendFSList(agentID: agentID, path: path, requestID: reqID) { rawEntries, resolvedPath, error in
            self.isLoading = false
            if let error = error {
                self.errorMessage = error
                return
            }
            // Update the current path segment with the resolved path (e.g. "~" → "/Users/...")
            if let resolved = resolvedPath, !resolved.isEmpty,
               let lastIdx = self.pathStack.indices.last {
                let seg = self.pathStack[lastIdx]
                if seg.path != resolved {
                    self.pathStack[lastIdx] = PathSegment(path: resolved, name: seg.name)
                }
            }
            self.entries = rawEntries.compactMap { FSEntry(dict: $0) }
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if isLoading { isLoading = false; errorMessage = "Request timed out" }
        }
    }

    private func performMkdir() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isMkdirLoading = true
        let reqID = UUID().uuidString
        relay.sendFSMkdir(agentID: agentID, path: joinPath(currentPath, name), requestID: reqID) { error in
            self.isMkdirLoading = false
            if let error = error {
                self.mkdirError = error
            } else {
                self.showMkdir = false
                self.loadDirectory(self.currentPath)
            }
        }
    }

    private func performDelete(_ entry: FSEntry) {
        let reqID = UUID().uuidString
        relay.sendFSDelete(agentID: agentID, path: joinPath(currentPath, entry.name), requestID: reqID) { _ in
            self.loadDirectory(self.currentPath)
        }
    }

    private func loadFile(_ entry: FSEntry) {
        let reqID = UUID().uuidString
        relay.sendFSRead(agentID: agentID, path: joinPath(currentPath, entry.name), requestID: reqID) { content, error in
            if let content = content {
                self.viewingFile = FileViewerItem(name: entry.name, content: content)
            } else {
                self.errorMessage = error ?? "Cannot read file"
            }
        }
    }

    /// Joins a parent path and child name, handling "/" root correctly.
    private func joinPath(_ parent: String, _ child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }

    // MARK: - Icon helpers

    private func iconName(_ e: FSEntry) -> String {
        if e.isDir { return "folder.fill" }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "swift":                        return "swift"
        case "go":                           return "g.circle.fill"
        case "py":                           return "p.circle.fill"
        case "js", "ts", "jsx", "tsx":       return "j.circle.fill"
        case "json":                         return "curlybraces"
        case "md":                           return "doc.text.fill"
        case "txt":                          return "doc.text"
        case "png","jpg","jpeg","gif","svg","webp","heic": return "photo.fill"
        case "pdf":                          return "doc.richtext.fill"
        case "sh","bash","zsh":              return "terminal.fill"
        case "yaml","yml":                   return "list.bullet.indent"
        case "zip","tar","gz","xz":          return "archivebox.fill"
        case "html","css":                   return "globe"
        case "xcodeproj","xcworkspace":      return "hammer.fill"
        default:                             return "doc.fill"
        }
    }

    private func iconBackground(_ e: FSEntry) -> Color {
        if e.isDir { return Color.yellow.opacity(0.18) }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "swift":                        return Color.orange.opacity(0.15)
        case "go":                           return Color.cyan.opacity(0.15)
        case "py":                           return Color.blue.opacity(0.15)
        case "js","ts","jsx","tsx":          return Color.yellow.opacity(0.15)
        case "json","yaml","yml":            return Color.purple.opacity(0.12)
        case "md","txt":                     return Color.gray.opacity(0.12)
        case "png","jpg","jpeg","gif","svg","webp","heic": return Color.pink.opacity(0.12)
        case "sh","bash","zsh":              return Color.green.opacity(0.12)
        default:                             return Color(UIColor.secondarySystemGroupedBackground)
        }
    }

    private func iconForeground(_ e: FSEntry) -> Color {
        if e.isDir { return .yellow }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "swift":                  return .orange
        case "go":                     return .cyan
        case "py":                     return .blue
        case "js","ts","jsx","tsx":    return Color(red: 0.9, green: 0.75, blue: 0.0)
        case "sh","bash","zsh":        return .green
        case "png","jpg","jpeg","gif","svg","webp","heic": return .pink
        default:                       return .secondary
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - FileViewerView

struct FileViewerView: View {
    let item: FileViewerItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView([.horizontal, .vertical]) {
                Text(item.content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
