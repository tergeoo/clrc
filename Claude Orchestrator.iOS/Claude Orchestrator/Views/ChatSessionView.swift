import SwiftUI
import ClrcCore

struct ChatSessionView: View {
    @ObservedObject var session: ChatSession
    @EnvironmentObject var relay: RelayWebSocket
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.transcript.turns) { turn in
                            ChatTurnView(turn: turn)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: session.transcript.lastSeq) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            ChatComposer(
                draft: $draft,
                isWorking: session.isWorking,
                onSend: {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    relay.sendChatMessage(sessionID: session.id, text: text)
                    draft = ""
                },
                onStop: { relay.sendChatInterrupt(sessionID: session.id) }
            )
        }
    }
}

struct ChatTurnView: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turn.events) { event in
                switch event.kind {
                case .text:
                    Text(event.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .toolUse:
                    ToolCallRow(event: event)

                case .error:
                    Label(event.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)

                case .turnEnd:
                    if event.costUSD > 0 {
                        Text(String(format: "%.3f $ · %d ms", event.costUSD, event.durationMS))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                case .turnStart, .toolResult, .unknown:
                    EmptyView()
                }
            }
        }
    }
}

struct ToolCallRow: View {
    let event: ChatEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(event.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(event.input)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if event.truncated {
                    Text("truncated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ChatComposer: View {
    @Binding var draft: String
    let isWorking: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)

            if isWorking {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(.bar)
    }
}
