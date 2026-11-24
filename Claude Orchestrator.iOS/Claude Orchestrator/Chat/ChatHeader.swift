import SwiftUI
import ClrcCore

/// 44 pt header (32 pt while typing): back, name with a session menu,
/// context dot and the «работает» badge.
struct ChatHeader: View {
    let content: ChatContent
    let compact: Bool
    let actions: ChatActions

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmClose = false
    @State private var showContext = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: actions.back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: compact ? 17 : 20, weight: .semibold))
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            }
            .accessibilityLabel("Назад")

            Menu { menuItems } label: { title }
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                if content.isWorking {
                    WorkingBadge(text: "работает")
                } else if content.isSending {
                    WorkingBadge(text: "отправка…")
                }
                if let ok = content.contextOK {
                    Button { showContext = true } label: {
                        StatusDot(color: ok ? Palette.green : Palette.red, size: 8)
                            .frame(width: 28, height: Metrics.minTapTarget)
                    }
                    .accessibilityLabel(ok ? "Контекст в порядке" : "Нет шапки контекста")
                    .popover(isPresented: $showContext) {
                        Text(ContextExplanation.text(ok: ok, header: content.contextHeader))
                            .font(.system(size: 14))
                            .padding()
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .frame(minWidth: Metrics.minTapTarget, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: compact ? 32 : 44)
        .background(.bar)
        .foregroundStyle(Palette.text)
        .alert("Имя сессии", isPresented: $renaming) {
            TextField("Имя", text: $newName)
            Button("Сохранить") { actions.rename(newName) }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Закрыть сессию?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Закрыть", role: .destructive, action: actions.close)
        } message: {
            Text("Процесс на Маке будет остановлен.")
        }
    }

    @ViewBuilder
    private var title: some View {
        if compact {
            HStack(spacing: 6) {
                Text(content.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(content.mode == .brief ? "Brief" : "Chat").font(.system(size: 12)).foregroundStyle(Palette.meta)
            }
        } else {
            VStack(spacing: 1) {
                Text(content.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(content.subtitle + " ▾")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.sec)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Переименовать", systemImage: "pencil") {
            newName = content.name
            renaming = true
        }
        Picker("Вид", selection: Binding(get: { content.mode }, set: actions.setMode)) {
            Text("Chat").tag(ChatDisplayMode.chat)
            Text("Brief").tag(ChatDisplayMode.brief)
        }
        Button("Терминал здесь", systemImage: "terminal", action: actions.openTerminal)
        Divider()
        Button("Закрыть сессию", systemImage: "xmark", role: .destructive) { confirmClose = true }
    }
}

struct WorkingBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: Palette.blue, size: 6)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Palette.tint)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.tintSoft, in: Capsule())
    }
}

/// What the context dot means, shown on tap.
enum ContextExplanation {
    static func text(ok: Bool, header: String) -> String {
        if ok { return header.isEmpty ? "Контекст в порядке" : header }
        if header.isEmpty {
            return "Сессия запущена без профиля или стиля clrc — проверьте CLRC_PROFILE на Маке"
        }
        return "Неожиданная шапка «\(header)» — проверьте CLRC_PROFILE на Маке"
    }
}
