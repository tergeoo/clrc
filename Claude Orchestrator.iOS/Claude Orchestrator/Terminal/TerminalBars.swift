import SwiftUI
import ClrcCore

/// View mode: «⌨︎ Клавиатура», ^C, ↑ (history), «Команды».
struct TerminalViewBar: View {
    let openKeyboard: () -> Void
    let interrupt: () -> Void
    let historyUp: () -> Void
    let commands: () -> Void

    private static let interruptWidth: CGFloat = 60
    private static let historyWidth: CGFloat = 48
    private static let commandsWidth: CGFloat = 100

    var body: some View {
        HStack(spacing: 8) {
            barButton(action: openKeyboard, fill: TerminalChrome.blue) {
                Label("Клавиатура", systemImage: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.white)
            }
            barButton(action: interrupt, fill: TerminalChrome.key) {
                Text("^C").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(TerminalChrome.red)
            }
            .frame(width: Self.interruptWidth)
            .accessibilityLabel("Control C")
            barButton(action: historyUp, fill: TerminalChrome.key) {
                Text("↑").font(.system(size: 17))
            }
            .frame(width: Self.historyWidth)
            .accessibilityLabel("Предыдущая команда")
            barButton(action: commands, fill: TerminalChrome.key) {
                Text("Команды").font(.system(size: 15)).lineLimit(1)
            }
            .frame(width: Self.commandsWidth)
        }
        .foregroundStyle(TerminalChrome.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TerminalChrome.bar)
    }

    private func barButton<L: View>(action: @escaping () -> Void, fill: Color,
                                    @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Input mode: the one row above the keyboard.
struct SpecialKeysRow: View {
    let ctrlOn: Bool
    let send: (TerminalKey) -> Void
    let toggleCtrl: () -> Void
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("Esc") { send(.esc) }
                    key("Tab") { send(.tab) }
                    Button(action: toggleCtrl) {
                        keyLabel("Ctrl", highlighted: ctrlOn)
                    }
                    .accessibilityAddTraits(ctrlOn ? .isSelected : [])
                    ForEach([TerminalKey.up, .down, .left, .right, .pipe, .tilde, .slash, .dash], id: \.self) { k in
                        key(k.label) { send(k) }
                    }
                }
                .padding(.horizontal, 8)
            }
            Button(action: hide) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16))
                    .frame(width: Metrics.minTapTarget, height: 36)
            }
            .accessibilityLabel("Спрятать")
        }
        .foregroundStyle(TerminalChrome.text)
        .frame(height: Metrics.minTapTarget)
        .background(TerminalChrome.bar)
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { keyLabel(title, highlighted: false) }
    }

    private func keyLabel(_ title: String, highlighted: Bool) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(highlighted ? Color.white : TerminalChrome.text)
            .padding(.horizontal, 11)
            .frame(minWidth: 36, minHeight: 34)
            .background(highlighted ? TerminalChrome.blue : TerminalChrome.key, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// «Команды»: quick commands by group; a tap runs one.
struct CommandsSheet: View {
    let run: (TerminalCommand) -> Void

    var body: some View {
        NavigationStack {
            List(TerminalCommands.groups) { group in
                Section(group.title) {
                    ForEach(group.commands) { command in
                        Button { run(command) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.title).font(.system(size: 16, weight: .semibold))
                                if command.command != command.title {
                                    Text(command.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Команды")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
