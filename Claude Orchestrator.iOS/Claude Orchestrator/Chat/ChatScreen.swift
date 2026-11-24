import SwiftUI
import ClrcCore

/// A chat session full screen (spec 5.4). Reads the live `ChatSession` into
/// `ChatContent` and wires actions to the relay and session manager.
struct ChatScreen: View {
    @ObservedObject var session: ChatSession
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSessionRoute) private var openSessionRoute
    @AppStorage(ChatDisplayMode.storageKey) private var displayMode: ChatDisplayMode = .chat

    @State private var draft = ""
    @State private var composing = false

    var body: some View {
        ChatContentView(content: content, actions: actions, draft: $draft, composing: $composing)
    }

    private var content: ChatContent {
        let transcript = session.transcript
        let latest = transcript.latestReport
        var content = ChatContent()
        content.name = session.customName
        content.mode = displayMode
        content.subtitle = ChatContent.shortPath(session.cwd) + " · " + (displayMode == .brief ? "Brief" : "Chat")
        content.status = SessionStatus.derive(isWorking: session.isWorking, lastError: session.lastError, report: latest)
        content.contextOK = latest?.contextOK
        content.contextHeader = latest?.header ?? ""
        content.turns = transcript.turns
        content.isWorking = session.isWorking
        content.retryText = transcript.lastUserText
        // Only the newest turn's questions are still open, until answered.
        let lastTurn = transcript.turns.last
        content.chips = QuickReplies.chips(for: lastTurn?.isAnswered == false ? lastTurn?.report : nil)
        content.changedFiles = latest?.changedFiles ?? []
        content.lastSeq = transcript.lastSeq
        return content
    }

    private var actions: ChatActions {
        ChatActions(
            send: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                relay.sendChatMessage(sessionID: session.id, text: trimmed)
            },
            fillDraft: { text in
                draft = text
                composing = true
            },
            stop: { sessionManager.stop(session) },
            back: { dismiss() },
            rename: { sessionManager.renameChat(session, to: $0) },
            setMode: { displayMode = $0 },
            openTerminal: {
                if let route = sessionManager.openTerminal(in: session.cwd, agentID: session.agent.id) {
                    openSessionRoute(route)
                }
            },
            close: {
                sessionManager.closeChat(session)
                dismiss()
            }
        )
    }
}

/// The pure chat layout: header, feed, bottom bar.
struct ChatContentView: View {
    let content: ChatContent
    let actions: ChatActions
    @Binding var draft: String
    /// Input mode: the one-row composer with the keyboard up.
    @Binding var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(content: content, compact: composing, actions: actions)
            Divider()
            feed
            ChatBottomBar(content: content, actions: actions, draft: $draft, composing: $composing)
        }
        .background(Palette.bg)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: Metrics.transition), value: composing)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(content.turns) { turn in
                        ChatTurnView(turn: turn, mode: content.mode,
                                     isLast: turn.id == content.turns.last?.id,
                                     isWorking: content.isWorking,
                                     retryText: content.retryText,
                                     actions: actions)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: content.lastSeq) { _, _ in
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: composing) { _, isComposing in
                if isComposing { withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) } }
            }
        }
    }

    private let bottomID = "chat-bottom"
}
