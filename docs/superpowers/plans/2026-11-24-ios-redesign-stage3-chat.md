# iOS 2.0.0 Redesign — Stage 3 (Chat session) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the chat session screen per spec 5.4: compact header with session menu, feed with block markdown / collapsed tool line / redesigned report card, read-mode bottom bar (quick-reply chips + «Ответить…» pill + «Стоп») and a one-row input mode that closes after sending.

**Architecture:** Same split as stages 1–2: every decision that can be tested lives in `ClrcCore` (markdown blocks, tool summary, turn outcome, quick replies, cost text, shell `cd` command); the app renders. `ChatSessionView` is replaced by `Chat/ChatScreen.swift` plus focused subviews; `ChatReportViews.swift` is rewritten. No protocol/agent changes.

**Tech Stack:** Swift 6 / SwiftUI (app iOS 26, `ClrcCore` iOS 17 / macOS 14), Swift Testing.

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.4 + «Клавиатура — как реализовано»; brief `docs/design/2.0.0/uploads/2026-11-24-ux-redesign-brief.md` §5.4, §6; mockup `docs/design/2.0.0/Chat.dc.html`.

## Global Constraints

- Russian UI copy, verbatim from spec/mockup: «Ответить…», «Продолжай», «Да», «Нет», «Покажи diff», «Запусти тесты», «Закоммить», «Подробности», «Дальше:», «Копировать», «Повторить», «Продолжить», «Прервано», «работает».
- Header 44 pt in read mode, 32 pt while the keyboard is up. No auto-focus ever; keyboard only after tapping «Ответить…»; after send the keyboard closes and the feed scrolls to the bottom.
- One accessory row in input mode: hide (⌄) · ＋ (insert a changed-file path / template) · field (1…5 lines) · send ↑.
- Code blocks, tool input/output: `Palette.code` (#1C1C21) background, SF Mono, light text, always dark.
- Status colors/icons from `DesignSystem` (`StatusIcon`, `Palette.status`); cards `.cardStyle()`; tap targets ≥ 44 pt.
- Question answers send the question number (`TurnReport.answerDraft`) as today; long-press puts it in the field instead.
- Out of scope (later stages / backend): diff screen («Diff ›» and «Покажи diff» chip send text to Claude for now), voice input/mic, variant 2c «закреплённый итог», «Сжать и продолжить», per-session display mode, editable chip set in Settings, date separators.

## Review Focus

1. **Unterminated code fence** (Claude streaming or truncated text ends mid-block) — rest of text renders as code, nothing lost. Test: `MarkdownBlocksTests.unterminatedFenceKeepsAllText` (Task 1).
2. **Turn interrupted by the user** (`turn_end` with `stop_reason: "interrupted"`) — shows «Прервано» + «Продолжить», not an error card. Test: `TurnOutcomeTests.interruptedTurn` (Task 3).
3. **Error after the session already has an older report** — «Повторить» resends the *last user message*, not a stale one; nil when there is none. Test: `TurnOutcomeTests.retryTextIsLastUserMessage` (Task 3).
4. **Report with more questions than fit in chips** — chips show all questions as «1», «2»… first, then the permanent set; no duplicates when a question equals a permanent chip. Test: `QuickRepliesTests.questionsFirstThenPermanentDeduped` (Task 4).
5. **Project path with quotes / spaces for «Терминал здесь»** — `cd` stays literal. Test: `ShellCommandTests.cdQuotesPath` (Task 4).

---

## File Structure

`ClrcCore/Sources/ClrcCore/` (tests mirror in `Tests/ClrcCoreTests/`):
- `MarkdownBlocks.swift` — block-level split of assistant text.
- `ToolSummary.swift` — «7 действий · Read ×3 · Edit ×2 · Bash ×2».
- `TurnOutcome.swift` — per-turn end info (cost/duration text, interrupted, error) + transcript helpers.
- `QuickReplies.swift` — chip list; `ShellCommand.cd(_:)`.

`Claude Orchestrator/Chat/` (app):
- `ChatScreen.swift` — screen: header, feed, bottom bar, keyboard handling (replaces `Views/ChatSessionView.swift`).
- `ChatHeader.swift` — 44/32 pt header + session menu.
- `ChatTurnViews.swift` — turn rendering, `MarkdownView`, `CodeBlockView`, `ToolActivityRow`, user bubble.
- `ReportCardView.swift` — report card (replaces `Views/ChatReportViews.swift`; keeps `ContextBadge` logic as `ContextExplanation`).
- `ChatBottomBar.swift` — read-mode chips + pill + stop; input-mode row.
- `ChatFixtures.swift` (DEBUG) — fixtures; `-designPreview chat|brief|chatworking|chaterror|chatinput`.
- Modify: `Shell/SessionRoute.swift` (use `ChatScreen`, keep nav bar hidden), `Shell/MainTabView.swift` (`openSessionRoute` environment), `Services/SessionManager.swift` (`renameChat`, `openTerminal(in:agentID:)`).

Build check (app tasks): `xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" -destination 'platform=iOS Simulator,id=8C7F62DD-DFBB-4BCA-AEEA-83144FAECB8B' -quiet build` from `Claude Orchestrator.iOS/` → exit 0. Core: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test` → all pass.

---

### Task 1: MarkdownBlocks

**Files:** Create `ClrcCore/Sources/ClrcCore/MarkdownBlocks.swift`; Test `ClrcCore/Tests/ClrcCoreTests/MarkdownBlocksTests.swift`

**Interfaces — Produces:**
```swift
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)                  // consecutive non-empty lines joined by "\n"
    case heading(level: Int, text: String)  // "#".."######" + space
    case bullet(String)                     // "- " / "* " / "+ " (leading spaces ≤ 3)
    case numbered(Int, String)              // "1. " / "12) "
    case code(language: String, text: String) // ``` or ~~~ fence; language = info string (may be "")
}
public enum MarkdownBlocks { public static func parse(_ text: String) -> [MarkdownBlock] }
```
Rules: blank lines end a paragraph; fenced code keeps inner lines verbatim (no trimming, no inline parsing); an unterminated fence runs to the end of text; `\r\n` treated as `\n`; empty input → `[]`.

- [ ] **Step 1: Failing tests** — `paragraphsSplitOnBlankLines` (`"a\nb\n\nc"` → `[.paragraph("a\nb"), .paragraph("c")]`), `headings` (`"## Итог"` → `.heading(level: 2, text: "Итог")`, `"#no"` → paragraph), `lists` (`"- x\n* y\n3. z"` → `[.bullet("x"), .bullet("y"), .numbered(3, "z")]`), `fencedCode` (`"```go\nfunc a() {}\n  x\n```"` → `[.code(language: "go", text: "func a() {}\n  x")]`), `unterminatedFenceKeepsAllText` (`"t\n```\nline1\nline2"` → `[.paragraph("t"), .code(language: "", text: "line1\nline2")]`), `emptyInput`.
- [ ] **Step 2: Run** `swift test --filter Markdown` → FAIL (missing type).
- [ ] **Step 3: Implement** a single line-by-line pass.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(ios-core): split assistant text into markdown blocks`

### Task 2: ToolSummary

**Files:** Create `ClrcCore/Sources/ClrcCore/ToolSummary.swift`; Test `ToolSummaryTests.swift`

**Interfaces — Produces:**
```swift
public struct ToolSummary: Equatable, Sendable {
    public let count: Int
    public let text: String     // "7 действий · Read ×3 · Edit ×2 · Bash ×2"; one tool once: "1 действие · Read"
    public let failed: Int      // tool_results with ok == false
    public static func of(_ events: [ChatEvent]) -> ToolSummary?   // nil when no tool_use
}
```
Ordering: by count desc, ties by first appearance. `×N` only when N > 1. Count word via `ruForm(n, one: "действие", few: "действия", many: "действий")`. At most 3 tool names listed, then `· ещё N` (N = remaining distinct tools).

- [ ] **Step 1: Failing tests** — `countsAndOrders` (Read,Edit,Read,Bash,Read,Edit,Bash → `"7 действий · Read ×3 · Edit ×2 · Bash ×2"`), `singleTool` (`"1 действие · Read"`), `capsAtThreeNames` (5 distinct → `"5 действий · A · B · C · ещё 2"`), `countsFailedResults`, `nilWithoutTools`.
- [ ] **Step 2–4:** run FAIL → implement → PASS (`swift test --filter ToolSummary`).
- [ ] **Step 5: Commit** `feat(ios-core): summarize a turn's tool calls in one line`

### Task 3: TurnOutcome

**Files:** Create `ClrcCore/Sources/ClrcCore/TurnOutcome.swift`; Test `TurnOutcomeTests.swift`

**Interfaces — Produces:**
```swift
extension ChatTurn {
    public var endEvent: ChatEvent? { get }          // the turn_end, if any
    public var wasInterrupted: Bool { get }          // endEvent?.stopReason == "interrupted"
    public var errorMessage: String? { get }         // last .error message in the turn
    public var assistantText: String { get }         // all .text events joined with "\n\n"
    public var toolEvents: [ChatEvent] { get }       // .toolUse in order
}
extension ChatTranscript {
    public var lastUserText: String? { get }         // most recent .userText across turns
}
public func turnCostText(costUSD: Double, durationMS: Int) -> String?
// nil when both 0; "$0.42 · 1 мин 12 с"; "$0.01 · 8 с"; cost omitted when 0 → "8 с"; duration omitted when 0 → "$0.42"
```

- [ ] **Step 1: Failing tests** — `interruptedTurn` (turn_end stop_reason "interrupted" → `wasInterrupted`, `errorMessage == nil`), `errorTurn`, `assistantTextJoinsTextEvents`, `retryTextIsLastUserMessage` (user_text "a" in turn 1, "b" in turn 2 → "b"; empty transcript → nil), `costText` (0.42/72_000 → "$0.42 · 1 мин 12 с"; 0.0123/8_000 → "$0.01 · 8 с"; 0/8_000 → "8 с"; 0/0 → nil).
- [ ] **Step 2–4:** FAIL → implement → PASS (`swift test --filter TurnOutcome`).
- [ ] **Step 5: Commit** `feat(ios-core): describe how a chat turn ended`

### Task 4: QuickReplies and ShellCommand

**Files:** Create `ClrcCore/Sources/ClrcCore/QuickReplies.swift`; Test `QuickRepliesTests.swift`

**Interfaces — Produces:**
```swift
public struct QuickReply: Equatable, Sendable, Identifiable {
    public let title: String   // chip label
    public let text: String    // what is sent
    public let isAnswer: Bool  // a report question (drawn tinted)
    public var id: String { title }
}
public enum QuickReplies {
    public static let permanent = ["Продолжай", "Да", "Нет", "Покажи diff", "Запусти тесты", "Закоммить"]
    /// Report questions first as answer chips («1 · <question>», text = answerDraft), then the
    /// permanent chips, skipping any permanent title equal (case-insensitive) to a question.
    public static func chips(for report: TurnReport?) -> [QuickReply]
}
public enum ShellCommand {
    /// "cd '<path>'" with single-quote escaping; "~"/empty → "cd ~".
    public static func cd(_ path: String?) -> String
}
```
Answer chip title is truncated to 28 chars with «…».

- [ ] **Step 1: Failing tests** — `permanentOnlyWithoutReport` (6 chips, all `isAnswer == false`), `questionsFirstThenPermanentDeduped` (questions ["Да", "Покажи SQL"] → titles `["1 · Да", "2 · Покажи SQL", "Продолжай", "Нет", "Покажи diff", "Запусти тесты", "Закоммить"]`, texts of first two `"1"`, `"2"`), `longQuestionTitleTruncated`, `cdQuotesPath` (`"/u/it's x"` → `"cd '/u/it'\''s x'"`; nil → `"cd ~"`).
- [ ] **Step 2–4:** FAIL → implement → PASS (`swift test --filter 'QuickReplies|ShellCommand'`), then full `swift test`.
- [ ] **Step 5: Commit** `feat(ios-core): quick-reply chips and project cd command`

### Task 5: SessionManager — rename chat, terminal in project; route opener

**Files:** Modify `Services/SessionManager.swift`, `Shell/MainTabView.swift`, `Shell/SessionRoute.swift`

**Interfaces — Produces:**
- `SessionManager.renameChat(_ session: ChatSession, to name: String)` — trims; empty → no-op; updates `customName` and the persisted entry (`store.upsert` with same id/kind/cwd).
- `SessionManager.openTerminal(in cwd: String, agentID: String) -> SessionRoute?` — `createSession(initialCommand: ShellCommand.cd(cwd))`, returns `.terminal(id:)`; nil when the Mac is offline.
- `EnvironmentValues.openSessionRoute: (SessionRoute) -> Void` (default no-op), set in `MainTabView` to `inboxPath.append`.

- [ ] **Step 1:** implement; **Step 2:** build → exit 0; **Step 3:** commit `feat(ios): rename chats and open a terminal in their project`

### Task 6: Chat screen

**Files:** Create `Chat/ChatScreen.swift`, `Chat/ChatHeader.swift`, `Chat/ChatTurnViews.swift`, `Chat/ReportCardView.swift`, `Chat/ChatBottomBar.swift`, `Chat/ChatFixtures.swift`; Delete `Views/ChatSessionView.swift`, `Views/ChatReportViews.swift`; Modify `Shell/SessionRoute.swift` (chat → `ChatScreen(session:)`, `.toolbar(.hidden, for: .navigationBar)` for chat), `App/ClaudeTerminalApp.swift`/`Inbox/InboxFixtures.swift` (route new preview states).

**Interfaces — Consumes:** Tasks 1–5, `StatusIcon`, `Palette`, `SessionStatus.derive`, `ChatTurn.currentTool/startedAt`.

**Pure render split (as Inbox):** `ChatScreen(session:)` owns live state and actions; it renders `ChatContentView(content: ChatContent, actions: ChatActions, draft: Binding<String>, inputFocused: FocusState<Bool>.Binding)` so fixtures can drive it. `ChatContent` = `{ name, subtitle ("~/dev/api · Chat"), mode: ChatDisplayMode, status: SessionStatus, contextOK: Bool?, contextHeader: String, turns: [ChatTurn], isWorking, lastError: String?, retryText: String?, chips: [QuickReply], changedFiles: [String], now: Date }`.

Header (`ChatHeader`): back chevron (dismiss), centre: name 17 pt semibold + subtitle 12 pt mono `sec` with «▾»; right: context `StatusDot` (tap → popover with `ContextExplanation`: ok → header text; missing → «Сессия запущена без профиля или стиля clrc — проверьте CLRC_PROFILE на Маке»), «работает» capsule when working. Whole centre is a `Menu`: Переименовать (alert with field), Вид: Chat / Brief (writes `ChatDisplayMode.storageKey`), Терминал здесь (`openTerminal` → `openSessionRoute`), Закрыть сессию (destructive, confirm → `closeChat` + dismiss). Height 44, 32 when `inputFocused` (subtitle hidden, name 15 pt).

Feed (`ScrollView` + `LazyVStack`, `.scrollDismissesKeyboard(.interactively)`, auto-scroll to bottom on `lastSeq` change and after send):
- user text → right bubble (tint bg, white, radius 18, max 80% width).
- tool line (`ToolActivityRow`): wrench symbol + `ToolSummary.text`, chevron; expanded → each call: `ToolLabel.label` + symbol, tap → input/output on `Palette.code` mono 12 pt, `lineLimit(12)` with «Показать полностью»; failed result → 3 pt red leading strip.
- assistant text (`MarkdownView`): blocks from `MarkdownBlocks.parse`; paragraphs/list items through `inlineMarkdown`; headings 17/15 pt semibold; `CodeBlockView` with language label + «Копировать» (`UIPasteboard`, label flips to «Скопировано» for 1.5 s), horizontal scroll, no wrap.
- report card per mode: Chat → tools, text, card; Brief → card, tools, «Подробности» disclosure with text.
- working turn: inline row `StatusIcon(.working)` + current tool (tint mono) + timer `m:ss`.
- interrupted: grey row «Прервано» + button «Продолжить» (sends «Продолжай»).
- error: red-tinted card (`Palette.red` 12% bg) with message + «Повторить» (sends `retryText`, hidden when nil).

Report card (`ReportCardView`): top row `StatusIcon(size: 22)` + status label (`SessionStatus` mapping of report status) + right `turnCostText` (12 pt meta); title 17 pt semibold; summary 15 pt `sec`; files block (fill bg, radius 10): header «N файлов изменено» (ru plural; no «Diff ›» until the diff screen exists), then up to 4 mono paths, «ещё N» expands the rest; «Дальше: <step>» lines 14 pt meta; questions → full-width buttons 50 pt «1. …» (tint bg first, fill others), tap → `actions.send(answerDraft)`, long press → `actions.fillDraft(answerDraft)`.

Bottom bar (`ChatBottomBar`):
- read mode: horizontal chips (`QuickReplies.chips(for: latestReport)`; answer chips tint-soft, others card) — tap sends `chip.text`; row below: pill «Ответить…» (fill, 40 pt, tap → focus) and, when working, red «Стоп» (stop.fill, 40 pt circle) instead of nothing.
- input mode (focused): one row — ⌄ (unfocus), ＋ `Menu` (Вставить путь: changedFiles; Шаблоны: `NewTaskPlanner.templates`) appends to draft, `TextField(axis: .vertical).lineLimit(1...5)`, send ↑ (tint circle, disabled when blank). Send → `relay.sendChatMessage`, clear draft, unfocus.
- chips/answers disabled (0.5 opacity) while `isWorking`, except «Стоп».

- [ ] **Step 1:** create the core-driven view files and `ChatContent`/`ChatActions`; wire `ChatScreen` to `ChatSession` + `SessionManager` + `RelayWebSocket`.
- [ ] **Step 2:** fixtures + `-designPreview chat|brief|chatworking|chaterror|chatinput` (input state focuses the field on appear — DEBUG fixture only).
- [ ] **Step 3:** delete old views, fix references; build → exit 0; `swift test` → pass.
- [ ] **Step 4:** screenshots of each preview state (light; `chat` also dark); compare to `Chat.dc.html`; fix visible deviations.
- [ ] **Step 5:** commit `feat(ios): chat session screen with report card, quick replies and one-row input`
