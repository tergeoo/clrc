import SwiftUI
import ClrcCore

/// A note shown under a diff line.
struct LineNote: Identifiable, Equatable {
    let id: Int
    let author: String
    let body: String
}

/// A merge request file diff: existing line discussions under their lines,
/// long-press a line to comment on it (spec 5.8 «Комментарий»).
struct GitLabFileDiff: View {
    let files: [DiffFile]
    let index: Int
    @Binding var viewed: Set<String>
    let discussions: [GitLabDiscussion]
    let refs: GitLabDiffRefs?
    let projectID: Int
    let iid: Int
    let onCommented: () -> Void

    @State private var target: CommentTarget?

    struct CommentTarget: Identifiable {
        let file: DiffFile
        let line: DiffLine
        var id: String { file.id + (GitLabDiscussions.key(for: line) ?? "") }
    }

    var body: some View {
        DiffFileScreen(files: files, index: index, viewed: $viewed,
                       lineNotes: { file in
                           GitLabDiscussions.notes(on: file, in: discussions).mapValues { notes in
                               notes.map { LineNote(id: $0.id, author: $0.author.name, body: $0.body) }
                           }
                       },
                       onLongPressLine: refs == nil ? nil : { file, line in target = CommentTarget(file: file, line: line) })
            .sheet(item: $target) { target in
                LineCommentSheet(target: target, refs: refs, projectID: projectID, iid: iid) {
                    onCommented()
                }
            }
    }
}

/// The highlighted line, a field and «Отправить».
private struct LineCommentSheet: View {
    let target: GitLabFileDiff.CommentTarget
    let refs: GitLabDiffRefs?
    let projectID: Int
    let iid: Int
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(lineLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xE6E6EB))
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.code, in: RoundedRectangle(cornerRadius: 10))
                TextField("Комментарий к строке", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(12)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Palette.red)
                }
                Spacer()
            }
            .padding(16)
            .background(Palette.bg)
            .navigationTitle((target.file.path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Отправить") { Task { await send() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var lineLabel: String {
        let number = target.line.newNumber ?? target.line.oldNumber ?? 0
        let mark = target.line.kind == .added ? "+" : target.line.kind == .removed ? "−" : " "
        return "\(number) \(mark) \(target.line.text)"
    }

    private func send() async {
        guard let refs, let client = GitLabClient() else { return }
        sending = true
        defer { sending = false }
        do {
            try await client.send(.lineComment(project: projectID, iid: iid, body: text, refs: refs,
                                               oldPath: target.file.oldPath, newPath: target.file.newPath, line: target.line))
            onSent()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
