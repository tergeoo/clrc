import SwiftUI
import ClrcCore

private let monoMeta = Font.system(size: 12, design: .monospaced)
private let rowHeight: CGFloat = 60

/// «Ждёт вас» card: status, title, summary, meta, one-tap answers.
struct WaitingCard: View {
    let card: InboxCard
    let now: Date
    let relayConnected: Bool
    let open: () -> Void
    let answer: (Int) -> Void

    private var canAnswer: Bool { relayConnected && card.snapshot.agentOnline }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 10) {
                    StatusIcon(status: card.snapshot.status)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(card.title)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(agoText(from: card.snapshot.updatedAt, now: now))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.meta)
                        }
                        if let summary = card.snapshot.report?.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.sec)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        MetaLine(meta: card.meta, contextOK: card.contextOK)
                            .padding(.top, 2)
                        // With the relay down every Mac looks offline; the
                        // banner already says so, a chip per card would mislead.
                        if relayConnected && !card.snapshot.agentOnline {
                            OfflineChip(agentName: card.snapshot.agentName)
                        }
                    }
                }
                .foregroundStyle(Palette.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(SessionStatus.accessibilityLabel(
                session: card.snapshot.name, status: card.snapshot.status,
                questionCount: card.snapshot.report?.questions.count ?? 0))

            HStack(spacing: 8) {
                if card.answers.isEmpty {
                    AnswerButton(title: "Ответить…", primary: true, enabled: true, action: open)
                } else {
                    ForEach(Array(card.answers.enumerated()), id: \.offset) { index, text in
                        AnswerButton(title: text, primary: index == 0, enabled: canAnswer) { answer(index) }
                    }
                    if card.moreAnswers {
                        AnswerButton(title: "Ещё…", primary: false, enabled: true, action: open)
                            .frame(maxWidth: 72)
                    }
                }
            }
        }
        .cardStyle()
        .opacity(card.snapshot.agentOnline && relayConnected ? 1 : 0.5)
    }
}

private struct AnswerButton: View {
    let title: String
    let primary: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .foregroundStyle(primary ? Color.white : Palette.tint)
                .background(primary ? Palette.tint : Palette.fill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct MetaLine: View {
    let meta: String
    let contextOK: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Text(meta).font(monoMeta).foregroundStyle(Palette.meta).lineLimit(1)
            if let contextOK {
                StatusDot(color: contextOK ? Palette.green : Palette.red)
                    .accessibilityLabel(contextOK ? "контекст в порядке" : "контекст не подтверждён")
            }
        }
    }
}

private struct OfflineChip: View {
    let agentName: String

    var body: some View {
        Text("\(agentName) не в сети")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.sec)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, 4)
    }
}

/// «Работает» row: what the turn is doing now and how long it has run.
struct WorkingRow: View {
    let card: InboxCard
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(status: .working, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let tool = card.snapshot.currentTool {
                    Text(tool).font(monoMeta).foregroundStyle(Palette.tint).lineLimit(1)
                }
                Text(card.meta).font(monoMeta).foregroundStyle(Palette.meta).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let started = card.snapshot.turnStartedAt {
                Text(timerText(from: started))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Palette.meta)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: rowHeight)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(card.snapshot.agentOnline ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }

    private func timerText(from start: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// «Готово» row.
struct DoneRow: View {
    let card: InboxCard
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(status: card.snapshot.status, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let summary = card.snapshot.report?.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 13)).foregroundStyle(Palette.sec).lineLimit(1)
                }
                MetaLine(meta: card.meta, contextOK: card.contextOK)
            }
            Spacer(minLength: 8)
            Text(agoText(from: card.snapshot.updatedAt, now: now))
                .font(.system(size: 13))
                .foregroundStyle(Palette.meta)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: rowHeight)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(card.snapshot.agentOnline ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}

struct TerminalRow: View {
    let terminal: InboxTerminalSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.sec)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(terminal.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(terminal.agentName).font(monoMeta).foregroundStyle(Palette.meta)
            }
            Spacer()
            Text(terminal.agentOnline ? (terminal.isWorking ? "работает" : "ожидает") : "не в сети")
                .font(.system(size: 13))
                .foregroundStyle(terminal.isWorking ? Palette.tint : Palette.meta)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Metrics.minTapTarget + 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct EndedSection: View {
    let ended: [InboxEndedSnapshot]
    @Binding var expanded: Bool
    let restart: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(ended) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 15, weight: .semibold))
                            Text(item.agentOnline ? (item.projectPath ?? item.agentName) : "\(item.agentName) не в сети")
                                .font(monoMeta).foregroundStyle(Palette.meta).lineLimit(1)
                        }
                        Spacer()
                        Button("Перезапустить") { restart(item.id) }
                            .font(.system(size: 14, weight: .semibold))
                            .frame(minHeight: Metrics.minTapTarget)
                            .disabled(!item.agentOnline)
                        Button { remove(item.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.meta)
                                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        }
                        .accessibilityLabel("Убрать")
                    }
                    .padding(.leading, 14)
                    .contextMenu {
                        Button("Убрать", systemImage: "xmark", role: .destructive) { remove(item.id) }
                    }
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        } label: {
            SectionHeader(title: "Завершённые", count: ended.count)
        }
        .tint(Palette.meta)
    }
}

struct ConnectionPill: View {
    let text: String
    let online: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: online ? Palette.green : Palette.red, size: 7)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.sec)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Palette.card, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct OfflineBanner: View {
    let lastSyncText: String?
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: Palette.red, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Нет связи с relay").font(.system(size: 14, weight: .semibold))
                if let lastSyncText {
                    Text(lastSyncText).font(.system(size: 13)).foregroundStyle(Palette.meta)
                }
            }
            Spacer()
            Button("Повторить", action: retry)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Palette.fill, in: Capsule())
                .frame(minHeight: Metrics.minTapTarget)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

struct InboxSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Palette.fill).frame(width: 110, height: 12)
            ForEach([0.7, 0.55, 0.62], id: \.self) { width in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Palette.fill).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 7).fill(Palette.fill).frame(width: geo.size.width * width, height: 14)
                        }
                        .frame(height: 14)
                        RoundedRectangle(cornerRadius: 6).fill(Palette.fill).frame(height: 11)
                    }
                }
                .cardStyle()
            }
            Text("Получаем статус…")
                .font(.system(size: 13))
                .foregroundStyle(Palette.meta)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .padding(.top, 6)
        .accessibilityLabel("Загрузка")
    }
}

struct InboxEmptyState: View {
    let recents: [RecentProject]
    let newTask: () -> Void
    let launch: (RecentProject) -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Palette.meta, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .frame(width: 56, height: 56)
                Text("Нет сессий").font(.system(size: 22, weight: .bold)).padding(.top, 6)
                Text("Поставьте задачу — статус всех сессий появится здесь.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.sec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                Button(action: newTask) {
                    Text("Новая задача")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .frame(height: 50)
                        .background(Palette.tint, in: Capsule())
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)

            if !recents.isEmpty {
                SectionHeader(title: "Недавние проекты · запуск в 1 тап")
                VStack(spacing: 0) {
                    ForEach(recents) { project in
                        Button { launch(project) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                                    Text(project.path).font(monoMeta).foregroundStyle(Palette.meta).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.tint)
                                    .frame(width: 32, height: 32)
                                    .background(Palette.tintSoft, in: Circle())
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
        }
    }
}

struct NewTaskButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Palette.tint, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .accessibilityLabel("Новая задача")
    }
}
