import SwiftUI
import ClrcCore

/// Read mode: quick-reply chips, the «Ответить…» pill and «Стоп».
/// Input mode: one row — hide, ＋, field, send. Sending closes the keyboard.
struct ChatBottomBar: View {
    let content: ChatContent
    let actions: ChatActions
    @Binding var draft: String
    @Binding var composing: Bool
    @FocusState private var focused: Bool

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if composing {
                inputRow
            } else {
                chips
                readRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(content.chips) { chip in
                    Button { actions.send(chip.text) } label: {
                        Text(chip.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .foregroundStyle(chip.isAnswer ? Palette.tint : Palette.text)
                            .background(chip.isAnswer ? Palette.tintSoft : Palette.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Metrics.minTapTarget)
                }
            }
            .padding(.horizontal, 4)
        }
        .disabled(content.isWorking)
        .opacity(content.isWorking ? 0.5 : 1)
    }

    private var readRow: some View {
        HStack(spacing: 8) {
            Button { composing = true } label: {
                Text(draft.isEmpty ? "Ответить…" : draft)
                    .font(.system(size: 16))
                    .lineLimit(1)
                    .foregroundStyle(draft.isEmpty ? Palette.meta : Palette.text)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .background(Palette.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            if content.isWorking {
                Button(action: actions.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Palette.red, in: Circle())
                }
                .accessibilityLabel("Стоп")
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            roundButton("chevron.down", label: "Спрятать клавиатуру") { composing = false }
            Menu {
                if !content.changedFiles.isEmpty {
                    Section("Вставить путь") {
                        ForEach(content.changedFiles, id: \.self) { path in
                            Button(path) { append(path) }
                        }
                    }
                }
                Section("Шаблоны") {
                    ForEach(NewTaskPlanner.templates, id: \.self) { template in
                        Button(template) { append(template) }
                    }
                }
            } label: {
                roundIcon("plus")
            }
            .accessibilityLabel("Вставить")
            TextField("Сообщение", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                // The field only exists in input mode, so focus it once it
                // is on screen; losing focus (swipe down) leaves input mode.
                .onAppear { DispatchQueue.main.async { focused = true } }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { composing = false }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Palette.tint : Palette.meta, in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Отправить")
        }
    }

    private func send() {
        guard canSend else { return }
        actions.send(draft)
        draft = ""
        composing = false
    }

    private func append(_ text: String) {
        draft = draft.isEmpty ? text : draft + " " + text
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundIcon(symbol) }.accessibilityLabel(label)
    }

    private func roundIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.sec)
            .frame(width: 34, height: 34)
            .background(Palette.fill, in: Circle())
    }
}
