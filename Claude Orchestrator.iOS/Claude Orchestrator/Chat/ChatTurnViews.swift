import SwiftUI
import UIKit
import ClrcCore

private let codeText = Color(hex: 0xE6E6EB)

/// One turn in the feed. Chat: tools, text, report. Brief: report, tools,
/// text folded under «Подробности». The user's own messages close the turn
/// (they arrive just before the next `turn_start`).
struct ChatTurnView: View {
    let turn: ChatTurn
    let mode: ChatDisplayMode
    let isLast: Bool
    let isWorking: Bool
    let retryText: String?
    let actions: ChatActions

    @State private var showDetails = false

    private var userTexts: [ChatEvent] { turn.events.filter { $0.kind == .userText } }
    /// Answer buttons work only for the open question of the newest turn.
    private var answersActive: Bool { isLast && !isWorking && !turn.isAnswered }

    private var costText: String? {
        turn.endEvent.flatMap { turnCostText(costUSD: $0.costUSD, durationMS: $0.durationMS) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .brief, let report = turn.report {
                ReportCardView(report: report, costText: costText, answersActive: answersActive, actions: actions)
                tools
                if !turn.assistantText.isEmpty {
                    DisclosureGroup("Подробности", isExpanded: $showDetails) {
                        MarkdownView(text: turn.assistantText).padding(.top, 6)
                    }
                    .font(.system(size: 14))
                    .tint(Palette.sec)
                }
            } else {
                tools
                if !turn.assistantText.isEmpty { MarkdownView(text: turn.assistantText) }
                if let report = turn.report {
                    ReportCardView(report: report, costText: costText, answersActive: answersActive, actions: actions)
                }
            }
            outcome
            ForEach(userTexts) { UserBubble(text: $0.text) }
        }
    }

    @ViewBuilder
    private var tools: some View {
        if let summary = ToolSummary.of(turn.events) {
            ToolActivityRow(summary: summary, turn: turn)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if let message = turn.errorMessage {
            ErrorCard(message: message, retryText: isLast ? retryText : nil, send: actions.send)
        } else if turn.wasInterrupted {
            InterruptedRow(showContinue: isLast) { actions.send("Продолжай") }
        } else if isLast && isWorking && turn.endEvent == nil {
            TurnProgressRow(tool: turn.currentTool, startedAt: turn.startedAt)
        }
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Assistant text as blocks: paragraphs, headings, lists, code.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineMarkdown(text)).font(.system(size: 16)).foregroundStyle(Palette.text)
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: level <= 2 ? 18 : 16, weight: .semibold))
                .padding(.top, 4)
        case .bullet(let text):
            listRow(marker: "•", text: text)
        case .numbered(let number, let text):
            listRow(marker: "\(number).", text: text)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.system(size: 16)).foregroundStyle(Palette.sec).monospacedDigit()
            Text(inlineMarkdown(text)).font(.system(size: 16))
        }
    }
}

/// Dark code block with its language and «Копировать».
struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    private static let copiedFeedback: Duration = .milliseconds(1_500)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "код" : language)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x8E8E93))
                Spacer()
                Button(copied ? "Скопировано" : "Копировать") {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: Self.copiedFeedback)
                        copied = false
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0A84FF))
                .frame(minHeight: 32)
            }
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(codeText)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// «🔧 7 действий · Read ×3 · Edit ×2 · Bash ×2» — expands to each call.
struct ToolActivityRow: View {
    let summary: ToolSummary
    let turn: ChatTurn
    @State private var expanded = false

    private var results: [String: ChatEvent] {
        Dictionary(turn.events.filter { $0.kind == .toolResult }.map { ($0.toolID, $0) },
                   uniquingKeysWith: { _, latest in latest })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 13))
                    Text(summary.text).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                    if summary.failed > 0 {
                        Text("· \(summary.failed) ✕").font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.red)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Palette.sec)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(turn.toolEvents) { use in
                    ToolCallView(use: use, result: results[use.toolID])
                }
            }
        }
    }
}

private struct ToolCallView: View {
    let use: ChatEvent
    let result: ChatEvent?
    @State private var open = false
    @State private var full = false

    private static let previewLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                Label(ToolLabel.label(name: use.name, input: use.input), systemImage: ToolLabel.symbol(for: use.name))
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(use.input)
                    if let result { Text(result.output) }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(codeText)
                .lineLimit(full ? nil : Self.previewLines)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.code, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    if result?.ok == false {
                        Rectangle().fill(Palette.red).frame(width: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if !full {
                    Button("Показать полностью") { full = true }
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.tint)
                }
            }
        }
        .padding(.leading, 8)
    }
}

/// Live progress of the running turn: current tool and elapsed time.
struct TurnProgressRow: View {
    let tool: String?
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                StatusIcon(status: .working, size: 20)
                Text(tool ?? "Claude думает…")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.tint)
                    .lineLimit(1)
                Spacer()
                if let startedAt {
                    let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.meta)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct InterruptedRow: View {
    let showContinue: Bool
    let resume: () -> Void

    var body: some View {
        HStack {
            Label("Прервано", systemImage: "stop.circle").font(.system(size: 14)).foregroundStyle(Palette.sec)
            Spacer()
            if showContinue {
                Button("Продолжить", action: resume)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minHeight: Metrics.minTapTarget)
            }
        }
    }
}

struct ErrorCard: View {
    let message: String
    let retryText: String?
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                StatusIcon(status: .failed, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ход прерван ошибкой").font(.system(size: 15, weight: .semibold))
                    Text(message).font(.system(size: 14)).foregroundStyle(Palette.sec).textSelection(.enabled)
                }
            }
            if let retryText {
                Button { send(retryText) } label: {
                    Text("Повторить")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                        .background(Palette.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(Metrics.cardPadding)
        .background(Palette.red.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}
