#if DEBUG
import SwiftUI
import ClrcCore

/// Mockup data (docs/design/2.0.0/Chat.dc.html) for `-designPreview chat…`.
enum ChatFixtures {
    private static func tool(_ seq: UInt64, _ name: String, _ input: String, ok: Bool = true) -> [ChatEvent] {
        [ChatEvent(kind: .toolUse, seq: seq, ts: "", toolID: "t\(seq)", name: name, input: input),
         ChatEvent(kind: .toolResult, seq: seq + 1, ts: "", toolID: "t\(seq)", output: ok ? "ok" : "exit status 1", ok: ok)]
    }

    static let reply = """
    Переименовал модель и написал обратимую миграцию.

    ## Что сделано
    - `User` → `Account` во всех моделях
    - миграция `0042_accounts` с откатом

    ```sql
    ALTER TABLE users RENAME TO accounts;
    ALTER INDEX users_email_key RENAME TO accounts_email_key;
    ```
    """

    static let report = TurnReport(
        status: .needsInput, title: "Миграция users → accounts",
        summary: "Модели обновлены, миграция обратимая. Запустить на staging или сначала показать SQL?",
        questions: ["Запусти на staging", "Сначала покажи SQL"],
        nextSteps: ["прогнать тесты после миграции"],
        changedFiles: ["internal/models/account.go", "internal/models/user.go",
                       "db/migrations/0042_accounts.up.sql", "db/migrations/0042_accounts.down.sql", "go.sum"],
        header: "tergeo · personal", contextOK: true)

    static func events(_ state: String) -> [ChatEvent] {
        var e: [ChatEvent] = [ChatEvent(kind: .userText, seq: 1, ts: "", text: "Переименуй таблицу users в accounts и сделай миграцию"),
                              ChatEvent(kind: .turnStart, seq: 2, ts: "2026-11-24T09:30:00Z")]
        e += tool(3, "Read", #"{"file_path":"/Users/g/dev/api/internal/models/user.go"}"#)
        e += tool(5, "Read", #"{"file_path":"/Users/g/dev/api/db/schema.sql"}"#)
        e += tool(7, "Edit", #"{"file_path":"/Users/g/dev/api/internal/models/user.go"}"#)
        e += tool(9, "Bash", #"{"command":"go build ./..."}"#)
        e += tool(11, "Read", #"{"file_path":"/Users/g/dev/api/go.mod"}"#)
        e += tool(13, "Edit", #"{"file_path":"/Users/g/dev/api/db/migrations/0042_accounts.up.sql"}"#)
        e += tool(15, "Bash", #"{"command":"go test ./internal/models/..."}"#, ok: state != "chaterror")
        e.append(ChatEvent(kind: .text, seq: 17, ts: "", text: reply))
        if state == "chaterror" {
            e.append(ChatEvent(kind: .error, seq: 18, ts: "", message: "claude exited with status 1: context window exceeded"))
            e.append(ChatEvent(kind: .turnEnd, seq: 19, ts: "", stopReason: "error"))
            return e
        }
        e.append(ChatEvent(kind: .report, seq: 18, ts: "", report: report))
        e.append(ChatEvent(kind: .turnEnd, seq: 19, ts: "", costUSD: 0.42, durationMS: 72_000))
        if state == "chatworking" {
            e.append(ChatEvent(kind: .userText, seq: 20, ts: "", text: "1"))
            e.append(ChatEvent(kind: .turnStart, seq: 21, ts: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-18))))
            e.append(ChatEvent(kind: .toolUse, seq: 22, ts: "", toolID: "t22", name: "Bash", input: #"{"command":"pg_dump users > backup.sql"}"#))
        }
        return e
    }

    static func content(_ state: String) -> ChatContent {
        let transcript = ChatTranscript().applying(events(state))
        var c = ChatContent()
        c.name = "api"
        c.mode = state == "brief" ? .brief : .chat
        c.subtitle = "~/dev/api · " + (c.mode == .brief ? "Brief" : "Chat")
        c.isWorking = state == "chatworking"
        c.turns = transcript.turns
        c.contextOK = true
        c.contextHeader = "tergeo · personal"
        c.status = SessionStatus.derive(isWorking: c.isWorking, lastError: state == "chaterror" ? "x" : nil,
                                        report: transcript.latestReport)
        if let errorSeq = transcript.turns.last?.events.last(where: { $0.kind == .error })?.seq {
            c.retryText = transcript.retryText(beforeErrorSeq: errorSeq)
        }
        let last = transcript.turns.last
        c.chips = QuickReplies.chips(for: last?.isAnswered == false ? last?.report : nil)
        c.changedFiles = report.changedFiles
        c.lastSeq = transcript.lastSeq
        return c
    }
}

/// `-designPreview chat|brief|chatworking|chaterror|chatinput`.
struct ChatPreviewHost: View {
    let state: String
    @State private var draft = ""
    @State private var composing = false

    var body: some View {
        NavigationStack {
            ChatContentView(content: ChatFixtures.content(state), actions: ChatActions(fillDraft: { draft = $0; composing = true }),
                            draft: $draft, composing: $composing)
        }
        .task {
            guard state == "chatinput" else { return }
            draft = "Запусти, но сначала сделай бэкап таблицы users"
            composing = true
        }
    }

    static let states: Set<String> = ["chat", "brief", "chatworking", "chaterror", "chatinput"]

    /// Feeds fixture turns into a live session (for the Review preview).
    static func fill(_ session: ChatSession, state: String) {
        session.apply(history: ChatFixtures.events(state))
    }
}
#endif
