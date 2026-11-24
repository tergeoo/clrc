# iOS 2.0.0 Redesign — Stage 1–2 (Design system, Tab shell, Inbox, New Task) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the session-tabs UI with the 2.0.0 shell: a 4-tab bar (Входящие · Ревью · Проекты · Настройки), the Inbox (variant 1a, sorted by urgency, one-tap answers with undo) and the New Task sheet.

**Architecture:** All decisions that can be tested live in the `ClrcCore` SwiftPM package as pure value types (status derivation, inbox sectioning, tool labels, undo queue, launch planning) and are covered by `swift test`. The app target (no test target exists) only renders them: a small design-system folder, `MainTabView`, `InboxView`, `NewTaskSheet`. Session screens (`ChatSessionView`, terminal) are reused as-is and pushed full-screen from the Inbox; their redesign is stage 3–4. No protocol, relay or agent changes.

**Tech Stack:** Swift 6 / SwiftUI, iOS 17, `ClrcCore` (Swift Testing / XCTest as already used in `ClrcCoreTests`), Xcode project with file-system-synchronized groups (new files under `Claude Orchestrator/` are picked up automatically).

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` (screens 5.2, 5.3, "Визуальная система") and `docs/design/2.0.0/uploads/2026-11-24-ux-redesign-brief.md` (§2, §4, §5.2, §5.3, §7). Mockups: `docs/design/2.0.0/Inbox.dc.html`, `NewTask.dc.html`, `TabBar.dc.html` (open in a browser).

## Global Constraints

- iOS 17 minimum (unchanged); no new third-party dependencies.
- UI copy is Russian, verbatim from the spec/mockups (e.g. «Входящие», «Ждёт вас», «Новая задача», «Запустить в <проект>», «Пустой терминал», «Отменить»). Hardcoded strings, no string catalog in this stage.
- Status colors/glyphs identical everywhere: ждёт ответа — orange `?`; ошибка — red `!`; работает — blue (ring with dot); готово — green `✓`; неизвестно/idle — gray. Always icon + text (VoiceOver label carries the text).
- Palette (from `Inbox.dc.html`): light `bg #F2F2F7, card #FFFFFF, text #000, sec #3C3C43, meta #6C6C70, fill #E5E5EA, tint #007AFF, green #248A3D, orange #C93400, red #D70015`; dark `bg #000, card #1C1C1E, text #FFF, sec #C7C7CC, meta #8E8E93, fill #2C2C2E, tint #0A84FF, green #30D158, orange #FF9F0A, red #FF453A`. Status dot/working blue `#007AFF`. Code/terminal surfaces always `#1C1C21`.
- Cards: corner radius 12, padding 12; tap targets ≥ 44 pt; primary actions in the bottom third; transitions ≤ 0.25 s.
- SF Pro for UI, SF Mono (`.monospaced`) for paths, commands, tool names.
- No screen opens the keyboard on its own (Inbox never; New Task only on tap into the task field).
- Inbox answers are delayed sends: the card moves to «Работает» immediately, the `chat_send` goes out after 3 s unless «Отменить» is tapped (spec decision 4 — a sent message cannot be recalled, so "undo" must mean "not yet sent").
- Every `ClrcCore` change is test-first; `cd "Claude Orchestrator.iOS/ClrcCore" && swift test` stays green. Every app task ends with a green `xcodebuild` build.
- Out of scope for this plan: swipe actions, voice input/mic, variants 1b/1c, Review/Projects/Settings redesign (tabs host existing or placeholder screens), push/Live Activity, «Без подтверждений (опасно)».

## Review Focus

1. **Agent goes offline while its card has a pending 3 s answer** — the send must be dropped (not fired into a dead route) and the toast must say it was not sent. Test: `PendingAnswerQueueTests.test_dropsAnswersForOfflineAgent` (Task 4).
2. **Report with 0 questions but status `needs_input`** — the card still lands in «Ждёт вас» and shows the generic «Ответить…» button only. Test: `InboxBuilderTests.test_needsInputWithoutQuestions` (Task 3).
3. **Tool input that is truncated / not valid JSON** (agent truncates large inputs) — label falls back to the bare tool name, never crashes or shows raw JSON. Test: `ToolLabelTests.test_invalidJSONFallsBackToName` (Task 2).
4. **Session working but last report says `done` from the previous turn** — status must be «работает» (live turn wins over a stale report). Test: `SessionStatusTests.test_workingOverridesStaleReport` (Task 1).
5. **Task text with quotes/`$`/newlines in terminal mode** — the shell command must keep it literal. Test: `NewTaskPlannerTests.test_terminalPromptIsShellQuoted` (Task 5).

---

## File Structure

`ClrcCore/Sources/ClrcCore/` (tests mirror under `ClrcCore/Tests/ClrcCoreTests/`):
- `SessionStatus.swift` — status enum, derivation, labels, VoiceOver text.
- `RussianPlural.swift` — `ru(_:one:few:many:)` plural helper + `agoText`.
- `ToolLabel.swift` — human label for a `tool_use` event; `ChatTurn.currentTool`, `ChatTurn.startedAt`.
- `InboxBuilder.swift` — snapshot types → `InboxSections` + summary line + connection pill.
- `PendingAnswerQueue.swift` — clock-injected delayed-send queue.
- `NewTaskPlanner.swift` — default Mac, launch request, terminal command with prompt, templates.

`Claude Orchestrator/` (app):
- `DesignSystem/Palette.swift` — `Palette` colors (light/dark via `UIColor { traits in }`), status → color.
- `DesignSystem/StatusBadge.swift` — `StatusIcon(status:)` circle with glyph; `StatusDot`.
- `DesignSystem/Card.swift` — `.cardStyle()` modifier, `SectionHeader(title:count:)`, `ToastView`.
- `Shell/MainTabView.swift` — tab bar, `AppTab2`, hides tab bar on pushed sessions.
- `Shell/SessionRoute.swift` — `SessionRoute` enum + `SessionScreen` destination (chat or terminal).
- `Views/TerminalScreen.swift` — the former private `TerminalTabContent`, moved out of `SessionTabsView.swift`.
- `Inbox/InboxModel.swift` — `@MainActor ObservableObject` gluing `SessionManager`/`RelayWebSocket` → `InboxBuilder`, owns `PendingAnswerQueue` + 1 s ticker.
- `Inbox/InboxView.swift`, `Inbox/InboxCards.swift` — screen, sections, cards, states, FAB, toast.
- `NewTask/NewTaskSheet.swift` — replaces `Views/NewTaskSheet.swift` and `Views/NewSessionSheet.swift`.
- Modify: `App/ClaudeTerminalApp.swift` (RootView → `MainTabView`), `Services/SessionManager.swift` (`launch(_:)`, `stop`), delete `Views/SessionTabsView.swift`, `Views/NewSessionSheet.swift`, old `Views/NewTaskSheet.swift` in Task 9.

Build check used by app tasks (run from `Claude Orchestrator.iOS/`):

```sh
xcodebuild -project "Claude Orchestrator.xcodeproj" -scheme "Claude Orchestrator" \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max' -quiet build
```
Expected: exits 0, no `error:` lines.

---

### Task 1: SessionStatus — one status for every session

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/SessionStatus.swift`, `ClrcCore/Sources/ClrcCore/RussianPlural.swift`
- Test: `ClrcCore/Tests/ClrcCoreTests/SessionStatusTests.swift`, `ClrcCore/Tests/ClrcCoreTests/RussianPluralTests.swift`

**Interfaces:**
- Produces:
  - `public enum SessionStatus: String, Sendable, CaseIterable { case needsInput, failed, working, done, idle }`
  - `public static func derive(isWorking: Bool, lastError: String?, report: TurnReport?) -> SessionStatus`
  - `public var label: String` («ждёт ответа», «ошибка», «работает», «готово», «нет данных»)
  - `public var glyph: String` (`?`, `!`, `""` (drawn as ring), `✓`, `–`)
  - `public var needsUser: Bool` (needsInput, failed)
  - `public static func accessibilityLabel(session: String, status: SessionStatus, questionCount: Int) -> String`
  - `public func ru(_ n: Int, one: String, few: String, many: String) -> String` → `"\(n) \(form)"`
  - `public func agoText(from: Date, now: Date) -> String` («сейчас» < 60 s, «N мин», «N ч», «N д»)

- [ ] **Step 1: Write failing tests**

```swift
@Test func workingOverridesStaleReport() {
    let r = TurnReport(status: .done)
    #expect(SessionStatus.derive(isWorking: true, lastError: nil, report: r) == .working)
}
@Test func errorWinsOverDoneReport() {
    #expect(SessionStatus.derive(isWorking: false, lastError: "boom", report: TurnReport(status: .done)) == .failed)
}
@Test func reportMapping() {
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .needsInput)) == .needsInput)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .failed)) == .failed)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .inProgress)) == .working)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .unknown)) == .idle)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: nil) == .idle)
}
@Test func voiceOverLabel() {
    #expect(SessionStatus.accessibilityLabel(session: "api", status: .needsInput, questionCount: 2)
            == "Сессия api: ждёт ответа, 2 вопроса")
    #expect(SessionStatus.accessibilityLabel(session: "web", status: .done, questionCount: 0)
            == "Сессия web: готово")
}
// RussianPluralTests
@Test func plurals() {
    #expect(ru(1, one: "файл", few: "файла", many: "файлов") == "1 файл")
    #expect(ru(3, one: "файл", few: "файла", many: "файлов") == "3 файла")
    #expect(ru(11, one: "файл", few: "файла", many: "файлов") == "11 файлов")
    #expect(ru(22, one: "Мак", few: "Мака", many: "Маков") == "22 Мака")
}
@Test func ago() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(agoText(from: now.addingTimeInterval(-30), now: now) == "сейчас")
    #expect(agoText(from: now.addingTimeInterval(-120), now: now) == "2 мин")
    #expect(agoText(from: now.addingTimeInterval(-7200), now: now) == "2 ч")
}
```

Tests use Swift Testing (`import Testing`, `@testable import ClrcCore`), like the existing `ClrcCoreTests`.

- [ ] **Step 2: Run** `cd "Claude Orchestrator.iOS/ClrcCore" && swift test --filter 'SessionStatus|RussianPlural'` — Expected: FAIL (types missing).
- [ ] **Step 3: Implement** both files. Precedence in `derive`: `isWorking` → `lastError != nil` → report status → `.idle`.
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ios-core): derive one session status for the inbox`

---

### Task 2: ToolLabel — what a working session is doing right now

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/ToolLabel.swift`
- Test: `ClrcCore/Tests/ClrcCoreTests/ToolLabelTests.swift`

**Interfaces:**
- Consumes: `ChatEvent`, `ChatTurn` (existing).
- Produces:
  - `public enum ToolLabel { public static func label(name: String, input: String) -> String; public static func symbol(for name: String) -> String }`
  - `extension ChatTurn { public var currentTool: String? ; public var startedAt: Date? }` — `currentTool` = label of the last `toolUse` in the turn **only if** the turn has no `turnEnd`; `startedAt` = ISO8601 (with and without fractional seconds) parse of the `turnStart` event's `ts`.

Label rules (input is the tool's JSON object as a string, possibly truncated):
- `Bash` → `"Bash: <first line of command>"`
- `Read`/`Edit`/`Write`/`MultiEdit`/`NotebookEdit` → `"<Name> <last 3 components of file_path>"` (fewer if the path is shorter)
- `Grep`/`Glob` → `"<Name> <pattern>"`; `WebFetch` → `"WebFetch <url>"`; `WebSearch` → `"WebSearch <query>"`
- unknown tool, missing key or unparsable JSON → `name`
- whole label capped at 60 characters, ending with `…` when cut.

Symbols: Read `doc.text`, Edit/Write/MultiEdit `pencil`, Bash `terminal`, Grep/Glob `magnifyingglass`, WebFetch/WebSearch `globe`, default `wrench.and.screwdriver`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func bash() { #expect(ToolLabel.label(name: "Bash", input: #"{"command":"make test\necho x"}"#) == "Bash: make test") }
@Test func editKeepsLastThreeComponents() {
    #expect(ToolLabel.label(name: "Edit", input: #"{"file_path":"/Users/g/web/src/routes/login.tsx"}"#) == "Edit src/routes/login.tsx")
}
@Test func invalidJSONFallsBackToName() { #expect(ToolLabel.label(name: "Edit", input: #"{"file_path":"/Users/g/we"#) == "Edit") }
@Test func longLabelIsTruncated() {
    let cmd = String(repeating: "a", count: 200)
    #expect(ToolLabel.label(name: "Bash", input: #"{"command":"\#(cmd)"}"#).count == 60)
}
@Test func currentToolOnlyWhileTurnOpen() {
    let open = ChatTurn(id: 1, events: [
        ChatEvent(kind: .turnStart, seq: 1, ts: "2026-11-24T10:00:00Z"),
        ChatEvent(kind: .toolUse, seq: 2, ts: "", name: "Bash", input: #"{"command":"ls"}"#)])
    #expect(open.currentTool == "Bash: ls")
    #expect(open.startedAt == ISO8601DateFormatter().date(from: "2026-11-24T10:00:00Z"))
    let closed = ChatTurn(id: 1, events: open.events + [ChatEvent(kind: .turnEnd, seq: 3, ts: "")])
    #expect(closed.currentTool == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter ToolLabel` — Expected: FAIL.
- [ ] **Step 3: Implement** with `JSONSerialization` (`[String: Any]`); any throw → `name`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ios-core): label the tool a working turn is running`

---

### Task 3: InboxBuilder — sections, summary line, connection pill

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/InboxBuilder.swift`
- Test: `ClrcCore/Tests/ClrcCoreTests/InboxBuilderTests.swift`

**Interfaces:**
- Consumes: `SessionStatus`, `TurnReport`, `ru`.
- Produces:

```swift
public struct InboxChatSnapshot: Sendable, Equatable {
    public let id, name, agentID, agentName, project: String   // project = last path component of cwd, "~" → "домашняя папка"
    public let status: SessionStatus
    public let report: TurnReport?
    public let currentTool: String?
    public let turnStartedAt: Date?
    public let updatedAt: Date          // ts of the latest event, else session createdAt
    public let agentOnline: Bool
}
public struct InboxTerminalSnapshot: Sendable, Equatable { public let id, name, agentName: String; public let isWorking: Bool; public let agentOnline: Bool }
public struct InboxEndedSnapshot: Sendable, Equatable { public let id, name, agentName: String; public let projectPath: String? }

public struct InboxCard: Sendable, Equatable, Identifiable {
    public let id: String
    public let snapshot: InboxChatSnapshot
    public let answers: [String]      // ≤ 2 report questions; [] when none
    public let moreAnswers: Bool      // true when questions.count > 2
    public let meta: String           // "api · mbp-work · 4 файла" (files part omitted when 0)
    public let contextOK: Bool?       // nil when no report
}
public struct InboxSections: Sendable, Equatable {
    public let waiting: [InboxCard]   // needsInput + failed, newest updatedAt first
    public let working: [InboxCard]   // oldest turnStartedAt first
    public let done: [InboxCard]      // done + idle, newest first
    public let terminals: [InboxTerminalSnapshot]
    public let ended: [InboxEndedSnapshot]
    public var isEmpty: Bool          // no chats, terminals or ended
    public var summaryLine: String    // "2 ждут вас · 2 работают · 1 готово"; omit zero parts; "Всё спокойно" when all zero
}
public enum InboxBuilder {
    public static func build(chats: [InboxChatSnapshot], terminals: [InboxTerminalSnapshot],
                             ended: [InboxEndedSnapshot], pendingAnswerIDs: Set<String>) -> InboxSections
    public static func connectionPill(relayConnected: Bool, onlineMacs: Int) -> String  // "нет связи" | "нет Маков" | "1 Мак" | "2 Мака"
}
```
A chat whose id is in `pendingAnswerIDs` is placed in `working` regardless of its status (spec state "ответ отправлен"). Summary verbs: `ждёт вас`/`ждут вас`, `работает`/`работают`, `готово` (invariant) — use `ru` only for the number agreement of the verb: 1 → singular, else plural.

- [ ] **Step 1: Write failing tests** — `test_sectionsByUrgency` (one each of needsInput/failed/working/done/idle → counts 2/1/2), `test_waitingNewestFirst`, `test_pendingAnswerMovesToWorking`, `test_needsInputWithoutQuestions` (`answers == []`, still in `waiting`), `test_answersCappedAtTwo` (3 questions → 2 answers, `moreAnswers == true`), `test_metaOmitsZeroFiles` (`"api · mbp-work"`), `test_summaryLine` (`"2 ждут вас · 1 работает · 1 готово"`, all-zero → `"Всё спокойно"`), `test_connectionPill` (`(false, 2) → "нет связи"`, `(true, 0) → "нет Маков"`, `(true, 1) → "1 Мак"`, `(true, 2) → "2 Мака"`).
- [ ] **Step 2: Run** `swift test --filter InboxBuilder` — Expected: FAIL.
- [ ] **Step 3: Implement** `InboxBuilder.swift`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ios-core): group sessions into inbox sections by urgency`

---

### Task 4: PendingAnswerQueue — 3 s undo for inbox answers

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/PendingAnswerQueue.swift`
- Test: `ClrcCore/Tests/ClrcCoreTests/PendingAnswerQueueTests.swift`

**Interfaces:**
- Produces:

```swift
public struct PendingAnswer: Sendable, Equatable { public let sessionID, agentID, text: String; public let dueAt: Date }
public struct PendingAnswerQueue: Sendable, Equatable {
    public static let undoWindow: TimeInterval = 3
    public private(set) var items: [PendingAnswer]
    public init()
    public mutating func enqueue(sessionID: String, agentID: String, text: String, now: Date)  // replaces an existing item for the same session
    public mutating func cancel(sessionID: String) -> PendingAnswer?
    /// Removes and returns items due at `now` whose agent is online, and separately those dropped because their agent is offline.
    public mutating func drain(now: Date, onlineAgentIDs: Set<String>) -> (send: [PendingAnswer], dropped: [PendingAnswer])
    public var sessionIDs: Set<String>
}
```

- [ ] **Step 1: Write failing tests** — `test_notDueBeforeThreeSeconds` (drain at +2.9 s → empty, item kept), `test_dueAtThreeSeconds` (drain at +3 s → send 1, items empty), `test_cancelRemoves`, `test_enqueueReplacesSameSession`, `test_dropsAnswersForOfflineAgent` (due, agent not in set → `dropped` 1, `send` 0, items empty).
- [ ] **Step 2: Run** `swift test --filter PendingAnswer` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ios-core): queue inbox answers behind a 3 second undo`

---

### Task 5: NewTaskPlanner — default Mac, launch request, templates

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/NewTaskPlanner.swift`
- Modify: `ClrcCore/Sources/ClrcCore/SessionLaunchMode.swift` (add `terminalCommand(cwd:prompt:)`; keep `terminalCommand(cwd:)` delegating with `prompt: nil`)
- Test: `ClrcCore/Tests/ClrcCoreTests/NewTaskPlannerTests.swift`, extend `SessionLaunchModeTests.swift`

**Interfaces:**
- Produces:

```swift
public struct LaunchRequest: Sendable, Equatable {
    public let agentID: String
    public let cwd: String?            // nil = home
    public let mode: SessionLaunchMode
    public let prompt: String?         // trimmed; nil when empty
    public let name: String            // custom name, else last path component of cwd, else "claude"
    public let model: String?          // trimmed, nil when empty
    public let profile: String?        // via normalizedProfile
}
public enum NewTaskPlanner {
    public static let templates = ["Почини тесты", "Сделай ревью ветки", "Объясни код", "Обнови зависимости"]
    /// preferred (if online) → agent of the most recent project → first online → nil.
    public static func defaultAgentID(onlineAgentIDs: [String], preferred: String?, lastProjectAgentID: String?) -> String?
    public static func request(agentID: String, cwd: String?, mode: SessionLaunchMode, prompt: String,
                               customName: String, model: String, profile: String) -> LaunchRequest
    /// Tapping a recent project launches at once only when the task field is empty (brief §5.3).
    public static func launchesOnProjectTap(prompt: String) -> Bool
}
extension SessionLaunchMode { public static func terminalCommand(cwd: String?, prompt: String?) -> String }
```
Terminal with prompt: `cd '<cwd>' && claude '<prompt>'` (same single-quote escaping as the existing `cd` part); no cwd → `claude '<prompt>'`.

- [ ] **Step 1: Write failing tests** — `test_defaultPrefersOnlinePreferred`, `test_defaultSkipsOfflinePreferred` (falls to lastProjectAgentID), `test_defaultNilWhenNoneOnline`, `test_requestTrimsAndNames` (`prompt: "  "` → `nil`; cwd `/u/g/api`, empty name → `"api"`; `profile: "Bad Name"` → `nil`), `test_launchesOnProjectTap` (`""`/`"  "` → true, `"x"` → false), `test_terminalPromptIsShellQuoted`:

```swift
#expect(SessionLaunchMode.terminalCommand(cwd: "/u/it's", prompt: #"fix "$HOME" now"#)
        == #"cd '/u/it'\''s' && claude 'fix "$HOME" now'"#)
#expect(SessionLaunchMode.terminalCommand(cwd: nil, prompt: "a'b") == #"claude 'a'\''b'"#)
```
- [ ] **Step 2: Run** `swift test --filter 'NewTaskPlanner|SessionLaunchMode'` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run full** `swift test` — Expected: all PASS.
- [ ] **Step 5: Commit** `feat(ios-core): plan new-task launches and default Mac`

---

### Task 6: Design system — palette, status icon, card, toast

**Files:**
- Create: `Claude Orchestrator/DesignSystem/Palette.swift`, `StatusBadge.swift`, `Card.swift`

**Interfaces:**
- Consumes: `SessionStatus` (Task 1).
- Produces:
  - `enum Palette { static let bg, card, text, sec, meta, fill, tint, green, orange, red, blue: Color; static let code = Color(hex 0x1C1C21) ; static func status(_ s: SessionStatus) -> Color }` — dynamic light/dark from the Global Constraints values (`Color(UIColor { $0.userInterfaceStyle == .dark ? … : … })`). `working` → `blue #007AFF`, `idle` → `meta`.
  - `struct StatusIcon: View { let status: SessionStatus; var size: CGFloat = 26 }` — filled circle with white `glyph` (bold, size×0.58); `working` draws a 2 pt ring with a centre dot instead, with a calm pulse (`.easeInOut(duration: 1.2).repeatForever`); `.accessibilityLabel(status.label)`.
  - `struct StatusDot: View { let color: Color; var size: CGFloat = 6 }`
  - `extension View { func cardStyle() -> some View }` — padding 12, `Palette.card`, radius 12 (continuous).
  - `struct SectionHeader: View { let title: String; let count: Int? }` — 13 pt uppercase, `Palette.meta`, text `"\(title) · \(count)"`.
  - `struct ToastView: View { let text: String; let actionTitle: String?; let action: () -> Void }` — capsule on `.regularMaterial` above the tab bar.

- [ ] **Step 1: Create the three files.** Add a `#Preview` in `StatusBadge.swift` showing all five statuses in light and dark.
- [ ] **Step 2: Build** (command above) — Expected: exit 0.
- [ ] **Step 3: Commit** `feat(ios): add 2.0 design system primitives`

---

### Task 7: App shell — tab bar and full-screen session route

**Files:**
- Create: `Claude Orchestrator/Shell/MainTabView.swift`, `Claude Orchestrator/Shell/SessionRoute.swift`, `Claude Orchestrator/Views/TerminalScreen.swift`
- Modify: `Claude Orchestrator/App/ClaudeTerminalApp.swift` (`RootView`: authenticated → `MainTabView()`), `Claude Orchestrator/Views/SessionTabsView.swift` (remove `TerminalTabContent`, which moves to `TerminalScreen`)

**Interfaces:**
- Produces:
  - `enum MainTab: Hashable { case inbox, review, projects, settings }` — labels/symbols: Входящие `tray.full`, Ревью `checklist`, Проекты `folder`, Настройки `gearshape`.
  - `enum SessionRoute: Hashable { case chat(id: String), terminal(id: String) }`
  - `struct SessionScreen: View { let route: SessionRoute }` — looks up the session in `SessionManager`; chat → `ChatSessionView(session:)`, terminal → `TerminalScreen(session:)`; missing → «Сессия закрыта» placeholder. Applies `.toolbar(.hidden, for: .tabBar)` (brief §4: tab bar hidden inside a session).
  - `MainTabView` holds `@State var tab: MainTab = .inbox` and `@State var inboxPath = NavigationPath()`. Tabs: inbox → `NavigationStack(path:) { InboxView() }` with `.navigationDestination(for: SessionRoute.self) { SessionScreen(route: $0) }` (until Task 8 lands, a `Text("Входящие")` placeholder); review → `ContentUnavailableView("Ревью появится в следующем этапе", systemImage: "checklist")`; projects → existing `AgentListView()`; settings → existing `SettingsView()`. Passes `authService`, `relay`, `sessionManager` environment objects through.
  - Global relay banner deferred to the Inbox (Task 8); no banner here.

- [ ] **Step 1: Move** `TerminalTabContent` to `TerminalScreen.swift` as `struct TerminalScreen: View` (internal), unchanged behaviour; `SessionTabsView` references the new name so it still compiles.
- [ ] **Step 2: Create** `SessionRoute.swift`, `MainTabView.swift`; switch `RootView`.
- [ ] **Step 3: Build** — Expected: exit 0.
- [ ] **Step 4: Smoke run** in the iPhone 15 Pro Max simulator: sign in, see 4 tabs, Projects shows the Mac list, Settings opens. (Use the `run` skill or `xcrun simctl` install/launch.) Note the result in the commit body.
- [ ] **Step 5: Commit** `feat(ios): 4-tab shell with full-screen session route`

---

### Task 8: Inbox screen (variant 1a)

**Files:**
- Create: `Claude Orchestrator/Inbox/InboxModel.swift`, `Inbox/InboxView.swift`, `Inbox/InboxCards.swift`
- Modify: `Claude Orchestrator/Services/SessionManager.swift` (add `func stop(_ chat: ChatSession)` → `relay.sendChatInterrupt`; add `func restart(endedID: String)` delegating to `restartTombstone`), `Shell/MainTabView.swift` (use `InboxView`)

**Interfaces:**
- Consumes: `InboxBuilder`, `InboxSections`, `PendingAnswerQueue`, `ToolLabel` (`ChatTurn.currentTool`, `.startedAt`), `SessionStatus`, design system, `SessionRoute`, `agoText`.
- Produces:
  - `@MainActor final class InboxModel: ObservableObject` — `@Published private(set) var sections: InboxSections`, `@Published var toast: Toast?`, `@Published private(set) var now: Date`; `init(sessionManager:relay:)`; `func answer(_ card: InboxCard, text: String)`; `func undo()`; `func retryConnection()` (→ `relay.connect()`). Rebuilds `sections` on `sessionManager.objectWillChange`, every chat session's `objectWillChange`, `relay.$agents`, `relay.$connectionState`, and a 1 s `Timer.publish` tick (the tick also drains the queue and updates the working timers). Snapshot mapping: `status = SessionStatus.derive(isWorking:lastError:report: transcript.latestReport)`, `currentTool/turnStartedAt` from `transcript.turns.last`, `agentOnline` from `relay.agents`.
  - `struct Toast: Equatable { let text: String; let canUndo: Bool }` — «Ответ отправлен · Отменить» during the window; «Не отправлено: <Мак> не в сети» for dropped answers (auto-hide 3 s).

Screen (match `Inbox.dc.html`, variant `a`):
- Header: large title «Входящие», connection pill (`InboxBuilder.connectionPill`, dot green/red), summary line.
- Relay offline (`connectionState != .connected` after first connect): banner card «Нет связи с relay» + «Повторить»; cards at 0.5 opacity, answer buttons disabled.
- Loading (`connecting` and no agents yet): 3 skeleton cards + «Получаем статус…».
- Empty (`sections.isEmpty`): «Нет сессий», text «Поставьте задачу — статус всех сессий появится здесь.», «Новая задача» button, «Недавние проекты · запуск в 1 тап» list (from `sessionManager.recentProjects(for:)` of online Macs, max 5; tap → `sessionManager.launch` with the stored mode, Task 9 provides `launch`; until then open the sheet).
- Sections in order «Ждёт вас · N», «Работает · N», «Готово · N», «Терминалы · N», «Завершённые · N» (collapsed `DisclosureGroup`, row button «Перезапустить»). Empty sections are hidden.
- Waiting card: `StatusIcon`, title (report title, else session name), `agoText`, summary 2 lines, mono meta + context `StatusDot` (green/red, hidden when nil), «<Мак> не в сети» chip when offline, answer buttons (height 44, radius 10; first answer tinted, others `fill`), «Ответить…» when no questions (opens the session), «···» `Menu` (Открыть, Стоп/Закрыть).
- Working row: blue `StatusIcon`, title, current tool in tint mono, meta, right-aligned timer `m:ss` since `turnStartedAt`.
- Done row: green icon, title, summary 1 line, ago.
- Terminal row: `terminal` symbol, name, Мак, «работает»/«ожидает».
- Tap a card → push `SessionRoute`. `.contextMenu`: Открыть, Стоп (working chat), Закрыть (confirmation dialog).
- FAB «Новая задача» bottom-right (56 pt circle, `plus`, tint), opens the New Task sheet; above it the `ToastView`.

- [ ] **Step 1: Implement** `InboxModel` and wire it as `@StateObject` in `InboxView`.
- [ ] **Step 2: Implement** `InboxView` + `InboxCards` per the list above; add `#Preview`s fed by hand-built `InboxSections` (normal, offline, empty, loading).
- [ ] **Step 3: Build** — Expected: exit 0.
- [ ] **Step 4: Manual check** against the local relay+agent (`make dev`): start a chat in the old flow or via a terminal session; verify card moves Работает → Готово/Ждёт вас; tap an answer → card in Работает + toast; «Отменить» within 3 s → nothing sent (agent log `make logs` shows no `chat_send`); after 3 s → message appears in the chat; stop the agent → cards dimmed + «не в сети». Record what was checked in the commit body.
- [ ] **Step 5: Commit** `feat(ios): inbox sorted by urgency with one-tap answers`

---

### Task 9: New Task sheet and SessionManager.launch

**Files:**
- Create: `Claude Orchestrator/NewTask/NewTaskSheet.swift`
- Modify: `Claude Orchestrator/Services/SessionManager.swift` (add `launch(_:)`, `createChatSession` gains `style:model:profile:` and `firstMessage:`), `Inbox/InboxView.swift` (FAB + empty-state recents use the sheet / `launch`)
- Rename: `Claude Orchestrator/Views/NewTaskSheet.swift` → `Views/TerminalPromptSheet.swift`, type `NewTaskSheet` → `TerminalPromptSheet` (it sends a prompt into a running terminal from `ActivityFeedView.swift:50`; the name is freed for the new sheet)
- Modify: `Claude Orchestrator/Views/AgentListView.swift:72` (`NewSessionSheet(preferredAgentID:)` → `NewTaskSheet(preferredAgentID:onLaunched:)`)
- Delete: `Claude Orchestrator/Views/NewSessionSheet.swift`, `Claude Orchestrator/Views/SessionTabsView.swift` (and private views only they used; keep `AgentListView`, `FileBrowserView`, `SettingsView`, `ActivityFeedView`)

**Interfaces:**
- Consumes: `NewTaskPlanner`, `LaunchRequest`, `SessionLaunchMode`, `normalizedProfile`.
- Produces:
  - `SessionManager.launch(_ request: LaunchRequest) -> SessionRoute?` — chat/brief: `createChatSession(..., style: request.mode.displayMode!.outputStyle, model:, profile:)` then, if `prompt != nil`, `relay.sendChatMessage` right after the `connect` (the agent handles `connect` synchronously before reading the next frame, see `agent/ws_client.go:handleChatConnect`) and `ChatSession` logs nothing extra; terminal: `createSession(initialCommand: SessionLaunchMode.terminalCommand(cwd:prompt:))` then rename to `request.name`. Persists the chosen mode to the existing `@AppStorage` keys (`ChatDisplayMode.storageKey`, `SessionLaunchMode.terminalStorageKey`) so it is remembered. Returns the new session's route.
  - `SessionManager.launchEmptyTerminal(agentID: String) -> SessionRoute?` — plain `createSession`.
  - `struct NewTaskSheet: View { var preferredAgentID: String?; var onLaunched: (SessionRoute) -> Void }`

Sheet (match `NewTask.dc.html`): `.presentationDetents([.medium, .large], selection:)`, opens at `.medium`, field not focused.
1. «Мак» — chips of online Macs (hidden when one); default `NewTaskPlanner.defaultAgentID`.
2. «Проект» — up to 5 recent projects of the selected Mac (name bold + mono path); last row «Выбрать папку…» → existing `FileBrowserView(agentID:agentName:embedded: false, showDangerousOption: false) { path, _ in … }` exactly as the old `NewSessionSheet.swift:64` calls it. Tap: if `launchesOnProjectTap(prompt:)` → launch immediately; else select.
3. «Задача» — `TextField(axis: .vertical)` placeholder «Что сделать? (необязательно)», template chips below (tap appends/replaces text).
4. «Режим» — segmented Chat · Brief · Terminal + one-line hint: Chat «Ответ текстом, итог в конце», Brief «Сначала итог, текст свёрнут», Terminal «claude в терминале, как на Маке».
5. «Дополнительно» `DisclosureGroup`: Имя сессии, Модель, Профиль Claude (prefilled from `ChatDisplayMode.profileStorageKey`).
6. Bottom bar: primary «Запустить в <проект>» (disabled until a project is selected or «~»), secondary «Пустой терминал».
- On focus: detent → `.large`; Мак/проект/режим collapse into one chip row above the field; keyboard toolbar (`ToolbarItemGroup(placement: .keyboard)`): «спрятать» (`keyboard.chevron.compact.down`), Spacer, «Запустить».
- After launch: dismiss, then `onLaunched(route)` → Inbox pushes the session.

- [ ] **Step 1: Add `launch(_:)` / `launchEmptyTerminal`** to `SessionManager`; adjust `createChatSession` signature and its two callers.
- [ ] **Step 2: Implement** `NewTaskSheet`; hook FAB and empty-state recents in `InboxView`.
- [ ] **Step 3: Rename, delete, fix references** as listed in Files; then `grep -rn "NewSessionSheet\|SessionTabsView\|NewTaskSheet(session" "Claude Orchestrator"` — Expected: no matches.
- [ ] **Step 4: Build** — Expected: exit 0. Then `cd ClrcCore && swift test` — Expected: all PASS.
- [ ] **Step 5: Manual check** with `make dev`: recent project tap with empty field launches in 1 tap and pushes the chat; typed task in Chat mode arrives as the first message; Terminal mode runs `claude '<task>'` in the folder; mode is remembered on reopen; keyboard appears only after tapping the field. Record results in the commit body.
- [ ] **Step 6: Commit** `feat(ios): new task sheet launching chat, brief or terminal in a project`

---

## After Task 9

- Update `CLAUDE.md` (iOS section: tab shell, Inbox, design system folder, removed `SessionTabsView`) in the same branch.
- Whole-branch review (`git diff release/1.0.0...HEAD`), then stage 3 (Chat redesign) gets its own plan.
