import SwiftUI
import ClrcCore

/// The turn's result card: status, cost/time, title, summary, changed
/// files, next steps and one-tap answers (long press edits instead).
struct ReportCardView: View {
    let report: TurnReport
    let costText: String?
    /// false once answered or superseded: questions show as plain text.
    var answersActive = true
    let actions: ChatActions

    @State private var showAllFiles = false
    private static let visibleFiles = 4

    private var status: SessionStatus { SessionStatus.derive(isWorking: false, lastError: nil, report: report) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusIcon(status: status, size: 22)
                Text(status.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.status(status))
                Spacer()
                if let costText {
                    Text(costText).font(.system(size: 12)).foregroundStyle(Palette.meta)
                }
            }
            if !report.title.isEmpty {
                Text(report.title).font(.system(size: 17, weight: .semibold))
            }
            if !report.summary.isEmpty {
                Text(report.summary).font(.system(size: 15)).foregroundStyle(Palette.sec).textSelection(.enabled)
            }
            if !report.changedFiles.isEmpty { files }
            ForEach(Array(report.nextSteps.enumerated()), id: \.offset) { _, step in
                Text("Дальше: \(step)").font(.system(size: 14)).foregroundStyle(Palette.meta)
            }
            ForEach(Array(report.questions.enumerated()), id: \.offset) { index, question in
                if answersActive {
                    answerButton(index: index, question: question)
                } else {
                    Text("\(index + 1). \(question)").font(.system(size: 14)).foregroundStyle(Palette.meta)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .contain)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ru(report.changedFiles.count, one: "файл изменён", few: "файла изменено", many: "файлов изменено"))
                .font(.system(size: 13, weight: .semibold))
            let shown = showAllFiles ? report.changedFiles : Array(report.changedFiles.prefix(Self.visibleFiles))
            ForEach(shown, id: \.self) { path in
                Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.sec).lineLimit(1)
                    .truncationMode(.head)
            }
            if !showAllFiles && report.changedFiles.count > Self.visibleFiles {
                Button("ещё \(report.changedFiles.count - Self.visibleFiles)") { showAllFiles = true }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tint)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func answerButton(index: Int, question: String) -> some View {
        let answer = report.answerDraft(forQuestionAt: index)
        return Text("\(index + 1). \(question)")
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.leading)
            .foregroundStyle(index == 0 ? Color.white : Palette.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(index == 0 ? Palette.tint : Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { actions.send(answer) }
            .onLongPressGesture { actions.fillDraft(answer) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Удерживайте, чтобы отредактировать ответ")
    }
}
