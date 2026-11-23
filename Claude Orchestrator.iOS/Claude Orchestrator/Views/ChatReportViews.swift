import SwiftUI
import ClrcCore

/// The structured result of a turn: status, title, summary, changed files
/// and questions that can be answered with one tap.
struct ReportCard: View {
    let report: TurnReport
    /// Called with the composer text for a tapped question.
    let onAnswer: (String) -> Void
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: report.status.symbol)
                    .foregroundStyle(report.status.tint)
                Text(report.title.isEmpty ? report.status.label : report.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !report.summary.isEmpty {
                Text(report.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !report.changedFiles.isEmpty {
                changedFiles
            }

            if !report.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(report.nextSteps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !report.questions.isEmpty {
                questions
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(report.status.tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(report.status.tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showFiles.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFiles ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("\(report.changedFiles.count) file\(report.changedFiles.count == 1 ? "" : "s") changed")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showFiles {
                ForEach(report.changedFiles, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(report.questions.enumerated()), id: \.offset) { index, question in
                Button {
                    onAnswer(report.answerDraft(forQuestionAt: index))
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit()
                        Text(question).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Shows whether the session's replies carry the expected context header:
/// green when the agent reported `context_ok`, red when the header was
/// missing or wrong, hidden before the first report arrives.
struct ContextBadge: View {
    let report: TurnReport?

    var body: some View {
        if let report {
            HStack(spacing: 4) {
                Circle()
                    .fill(report.contextOK ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(label(for: report))
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(report.contextOK ? Color.secondary : Color.red)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(report.contextOK ? "Context loaded" : "Context header missing")
        }
    }

    /// The header itself when it is fine; otherwise a hint at the usual cause:
    /// the session runs without the clrc output style or in another profile.
    private func label(for report: TurnReport) -> String {
        if report.contextOK { return report.header }
        if report.header.isEmpty {
            return "No context header: check the output style and CLRC_PROFILE on the Mac"
        }
        return "Unexpected header \"\(report.header)\": check CLRC_PROFILE on the Mac"
    }
}

extension TurnReportStatus {
    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .needsInput: return "questionmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .inProgress: return "pause.circle.fill"
        case .unknown: return "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .done: return .green
        case .needsInput: return .orange
        case .failed: return .red
        case .inProgress: return .blue
        case .unknown: return .gray
        }
    }

    var label: String {
        switch self {
        case .done: return "Done"
        case .needsInput: return "Needs input"
        case .failed: return "Failed"
        case .inProgress: return "In progress"
        case .unknown: return "Finished"
        }
    }
}
