import SwiftUI
import UIKit
import ClrcCore

/// Read-only file preview (spec 5.10): line numbers, wrap toggle, search,
/// rendered markdown, «обрезан» banner, actions at the bottom.
struct FileViewerScreen: View {
    let agentID: String
    let path: String

    @EnvironmentObject var relay: RelayWebSocket
    @State private var file: FileText?
    @State private var error: String?

    var body: some View {
        Group {
            if let file {
                FileContentView(path: path, file: file, agentID: agentID)
            } else if let error {
                ContentUnavailableView {
                    Label("Не удалось открыть", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Повторить") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            file = try await FSClient(relay: relay).read(agentID: agentID, path: path)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The loaded file. Separate from the loader so previews can feed text.
struct FileContentView: View {
    let path: String
    let file: FileText
    let agentID: String
    var initialQuery = ""

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.openSessionRoute) private var openSessionRoute
    @State private var wrap = true
    @State private var showSource = false
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndex = 0
    /// Matching line indices, recomputed only when the query changes.
    @State private var matches: [Int] = []
    @State private var matchSet: Set<Int> = []
    @State private var askClaude = false
    @State private var copied = false

    private var folder: String { (path as NSString).deletingLastPathComponent }
    private var isMarkdown: Bool { FileText.isMarkdown(path) }
    private var gutterWidth: CGFloat { CGFloat(String(file.lines.count).count) * 8 + 12 }

    var body: some View {
        VStack(spacing: 0) {
            if searching { searchBar }
            if file.truncated {
                Label("Файл обрезан: первые 100 КБ", systemImage: "scissors")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.sec)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.fill)
            }
            if isMarkdown && !showSource {
                ScrollView { MarkdownView(text: file.text).padding(16) }
            } else {
                code
            }
            actionsBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isMarkdown {
                    Button(showSource ? "Текст" : "Исходник") { showSource.toggle() }
                }
                Menu {
                    Toggle("Перенос строк", isOn: $wrap)
                } label: { Image(systemName: "text.alignleft") }
                .accessibilityLabel("Вид")
                Button { searching.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Поиск")
            }
        }
        .sheet(isPresented: $askClaude) {
            NewTaskSheet(preferredAgentID: agentID, preferredProject: folder,
                         initialPrompt: "Объясни файл \(path)", onLaunched: openSessionRoute)
        }
        .onAppear {
            if !initialQuery.isEmpty { query = initialQuery; searching = true }
        }
    }

    private var code: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .foregroundStyle(Color(hex: 0x6C6C70))
                                .frame(width: gutterWidth, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(Color(hex: 0xE6E6EB))
                                .fixedSize(horizontal: !wrap, vertical: true)
                                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(highlight(index))
                        .id(index)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.code)
            .onChange(of: matchIndex) { _, _ in scroll(proxy) }
            .onChange(of: query) { _, newQuery in
                matches = file.matchingLines(newQuery)
                matchSet = Set(matches)
                matchIndex = 0
                scroll(proxy)
            }
        }
    }

    private func highlight(_ index: Int) -> Color {
        guard matchSet.contains(index) else { return .clear }
        return matches[min(matchIndex, matches.count - 1)] == index
            ? Palette.tint.opacity(0.45) : Palette.tint.opacity(0.2)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        withAnimation { proxy.scrollTo(matches[min(matchIndex, matches.count - 1)], anchor: .center) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.meta)
            TextField("Найти в файле", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Text(matches.isEmpty ? "0 из 0" : "\(min(matchIndex, matches.count - 1) + 1) из \(matches.count)")
                    .font(.system(size: 13)).foregroundStyle(Palette.meta).monospacedDigit()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty)
                .accessibilityLabel("Предыдущее")
            Button { step(1) } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty)
                .accessibilityLabel("Следующее")
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.minTapTarget)
        .background(.bar)
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
    }

    private var actionsBar: some View {
        HStack(spacing: 8) {
            actionButton(copied ? "Скопировано" : "Копировать путь", symbol: "doc.on.doc") {
                UIPasteboard.general.string = path
                copied = true
            }
            actionButton("Спросить Claude", symbol: "sparkles") { askClaude = true }
            Button {
                if let route = sessionManager.openTerminal(in: folder, agentID: agentID) { openSessionRoute(route) }
            } label: {
                Text("$_")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .frame(width: 52, height: Metrics.minTapTarget)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityLabel("Открыть в терминале")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

extension View {
    /// Registers the file viewer for `FileRoute` in a navigation stack.
    func fileDestinations() -> some View {
        navigationDestination(for: FileRoute.self) { FileViewerScreen(agentID: $0.agentID, path: $0.path) }
    }
}
