import SwiftUI
import ClrcCore

private enum DiffColors {
    static let added = Color(hex: 0x1E3A2A)
    static let removed = Color(hex: 0x3A1E22)
    static let hunk = Color(hex: 0x25252E)
    static let number = Color(hex: 0x6C6C70)
    static let text = Color(hex: 0xE6E6EB)
    static let addedMark = Color(hex: 0x30D158)
    static let removedMark = Color(hex: 0xFF453A)
}

/// One file's unified diff (spec 5.8 «Diff файла»): dark, old/new line
/// numbers, +/− backgrounds, hunk headers; ‹ ханк › and «Файл ›» below.
struct DiffFileScreen: View {
    let files: [DiffFile]
    @State var index: Int
    @Binding var viewed: Set<String>

    @State private var wrap = true
    @State private var hunkIndex = 0

    init(files: [DiffFile], index: Int, viewed: Binding<Set<String>>) {
        self.files = files
        _index = State(initialValue: index)
        _viewed = viewed
    }

    private var file: DiffFile { files[index] }
    private var numberWidth: CGFloat {
        let maxLine = file.hunks.flatMap(\.lines).compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        return CGFloat(String(maxLine).count) * 8 + 6
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            bottomBar
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $wrap) { Text("Перенос") }
                    .toggleStyle(.button)
            }
        }
        .onChange(of: index) { _, _ in hunkIndex = 0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ChangeBadge(kind: file.kind)
            Text(file.kind == .renamed ? "\(file.oldPath) → \(file.newPath)" : file.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text("+\(file.additions)").foregroundStyle(Palette.green)
            Text("−\(file.deletions)").foregroundStyle(Palette.red)
            Text("файл \(index + 1) / \(files.count)").foregroundStyle(Palette.meta)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if file.isBinary {
            ContentUnavailableView("Бинарный файл", systemImage: "doc", description: Text("Изменения не показываются."))
                .frame(maxHeight: .infinity)
        } else if file.hunks.isEmpty {
            ContentUnavailableView("Без изменений в тексте", systemImage: "doc.text",
                                   description: Text(file.kind == .renamed ? "Файл переименован." : "Изменились только права или режим."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    // One flat list with unique ids: nested ForEach keyed by
                    // offsets collides across hunks and drops rows.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { item in
                            switch item.content {
                            case .header(let text):
                                Text(text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DiffColors.number)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                    .background(DiffColors.hunk)
                            case .line(let line):
                                row(line)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .background(Palette.code)
                .onChange(of: hunkIndex) { _, value in
                    withAnimation { proxy.scrollTo("hunk-\(value)", anchor: .top) }
                }
                .onChange(of: index) { _, _ in proxy.scrollTo("hunk-0", anchor: .top) }
            }
        }
    }

    private struct Row: Identifiable {
        enum Content { case header(String), line(DiffLine) }
        let id: String
        let content: Content
    }

    /// Hunk headers get the id "hunk-<n>" so ‹ › can scroll to them.
    private var rows: [Row] {
        file.hunks.enumerated().flatMap { h, hunk in
            [Row(id: "hunk-\(h)", content: .header(hunk.header))]
                + hunk.lines.enumerated().map { l, line in Row(id: "\(h)-\(l)", content: .line(line)) }
        }
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
            Text(marker(line.kind)).foregroundStyle(markerColor(line.kind)).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .noNewline ? DiffColors.number : DiffColors.text)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(DiffColors.number)
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(background(line.kind))
        .textSelection(.enabled)
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .noNewline: return "\\"
        case .context: return ""
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? DiffColors.addedMark : kind == .removed ? DiffColors.removedMark : DiffColors.number
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return DiffColors.added
        case .removed: return DiffColors.removed
        case .context, .noNewline: return .clear
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { hunkIndex = max(0, hunkIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(hunkIndex == 0)
                    .accessibilityLabel("Предыдущий ханк")
                Text(file.hunks.isEmpty ? "—" : "ханк \(min(hunkIndex, file.hunks.count - 1) + 1)/\(file.hunks.count)")
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minWidth: 80)
                Button { hunkIndex = min(file.hunks.count - 1, hunkIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(hunkIndex >= file.hunks.count - 1)
                    .accessibilityLabel("Следующий ханк")
            }
            .frame(minHeight: Metrics.minTapTarget)
            Spacer()
            Button {
                if viewed.contains(file.id) { viewed.remove(file.id) } else { viewed.insert(file.id) }
            } label: {
                Label("Просмотрен", systemImage: viewed.contains(file.id) ? "checkmark.circle.fill" : "circle")
            }
            .tint(viewed.contains(file.id) ? Palette.green : Palette.tint)
            Button {
                viewed.insert(file.id)
                index += 1
            } label: {
                Label("Файл", systemImage: "chevron.right").labelStyle(.titleAndIcon)
            }
            .disabled(index >= files.count - 1)
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }
}
