import SwiftUI
import ClrcCore

/// The files a turn or a project changed (spec 5.8 «Ход Claude»): status
/// badge, path, +/−, «просмотрен», progress; tap opens the file's diff.
struct ChangesScreen: View {
    let route: DiffRoute

    @EnvironmentObject var relay: RelayWebSocket
    @State private var diff: ProjectDiff?
    @State private var error: String?
    @State private var viewed: Set<String> = []
    @State private var openIndex: Int?

    var body: some View {
        Group {
            if let diff {
                list(diff)
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
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        // Once: coming back from a file must not re-request and re-parse.
        .task { if diff == nil { await load() } }
        .navigationDestination(item: $openIndex) { index in
            if let diff {
                DiffFileScreen(files: diff.files, index: index, viewed: $viewed)
            }
        }
    }

    private func list(_ diff: ProjectDiff) -> some View {
        List {
            Section {
                if diff.files.isEmpty {
                    Text("Изменений нет").foregroundStyle(Palette.meta)
                }
                ForEach(Array(diff.files.enumerated()), id: \.element.id) { index, file in
                    Button { openIndex = index } label: {
                        ChangedFileRow(file: file, viewed: viewed.contains(file.id))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if !diff.files.isEmpty {
                    Text("\(viewed.count) из \(diff.files.count) просмотрено · +\(diff.files.map(\.additions).reduce(0, +)) −\(diff.files.map(\.deletions).reduce(0, +))")
                }
            } footer: {
                if diff.truncated {
                    Label("Diff обрезан: показаны первые 512 КБ", systemImage: "scissors")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        error = nil
        do {
            diff = try await GitClient(relay: relay).diff(agentID: route.agentID, path: route.repo, files: route.files)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChangedFileRow: View {
    let file: DiffFile
    let viewed: Bool

    var body: some View {
        HStack(spacing: 10) {
            ChangeBadge(kind: file.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(file.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.meta)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if file.isBinary {
                Text("бинарный").font(.system(size: 12)).foregroundStyle(Palette.meta)
            } else {
                HStack(spacing: 4) {
                    Text("+\(file.additions)").foregroundStyle(Palette.green)
                    Text("−\(file.deletions)").foregroundStyle(Palette.red)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(viewed ? Palette.green : Palette.meta)
                .accessibilityLabel(viewed ? "просмотрен" : "не просмотрен")
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
    }
}

struct ChangeBadge: View {
    let kind: ChangeKind

    var body: some View {
        Text(kind.rawValue)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch kind {
        case .added: return Palette.green
        case .deleted: return Palette.red
        case .renamed: return Palette.orange
        case .modified: return Palette.tint
        case .other: return Palette.meta
        }
    }

    private var label: String {
        switch kind {
        case .added: return "добавлен"
        case .deleted: return "удалён"
        case .renamed: return "переименован"
        case .modified: return "изменён"
        case .other: return "изменён"
        }
    }
}
