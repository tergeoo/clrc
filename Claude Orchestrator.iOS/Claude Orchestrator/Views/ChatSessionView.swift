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

    /// `tool_use`/`tool_result` are emitted as separate events but paired by
    /// `tool_id` on the agent (see agent/chat_events.go) — look the result up
    /// once per turn rather than scanning `turn.events` per row. Later
    /// duplicates win, matching how `ChatTranscript` treats seq ordering.
    private var toolResultsByID: [String: ChatEvent] {
        Dictionary(
            turn.events.filter { $0.kind == .toolResult }.map { ($0.toolID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turn.events) { event in
                switch event.kind {
                case .text:
                    Text(event.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .userText:
                    UserTextBubble(text: event.text)

                case .toolUse:
                    ToolCallRow(event: event, result: toolResultsByID[event.toolID])

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

/// The user's own message, echoed back by the agent as a `user_text` event
/// so it lands in the buffer and replays correctly. Rendered as a trailing
/// bubble to read visually distinct from assistant `text`.
struct UserTextBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ToolCallRow: View {
    let event: ChatEvent
    /// The matching `tool_result` for this `tool_use`, if it has arrived yet
    /// (M4) — looked up by `tool_id` in the parent `ChatTurnView`.
    let result: ChatEvent?
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
                    Text("input truncated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let result {
                    Text(result.output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            result.ok == false
                                ? Color.red.opacity(0.12)
                                : Color(.secondarySystemBackground)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if result.truncated {
                        Text("output truncated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
