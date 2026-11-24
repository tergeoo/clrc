# iOS 2.0.0 Redesign — Stage 5 (Settings, Onboarding, «Без подтверждений») Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring back the dangerous launch as the brief's «Без подтверждений (опасно)» toggle in New Task, redesign Settings (5.11) and the sign-in / onboarding screen (5.1).

**Architecture:** As before: decisions in `ClrcCore` (dangerous command, editable lists, relay URL normalisation), the app renders. Settings and Onboarding replace `Views/SettingsView.swift` and `LoginView` in `App/ClaudeTerminalApp.swift`.

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.1, §5.11, §5.3; brief §5.1, §5.3 («Без подтверждений (опасно)» — красный переключатель с подтверждением), §5.11, §2 п.6; mockups `Settings.dc.html`, `Onboarding.dc.html`, `NewTask.dc.html`.

## Global Constraints

- The agent always runs chat sessions with `--permission-mode bypassPermissions` (`agent/chat_session.go:160`): the toggle only changes Terminal mode (`claude --dangerously-skip-permissions`). In Chat/Brief the sheet says so instead of offering a toggle that does nothing.
- The toggle is red, off by default, **not remembered** between launches, and turning it on asks for confirmation. The session name gets the existing «⚠» marker (`SessionNaming.autoName`).
- Russian copy; dangerous actions red and in a separate «Опасная зона» at the bottom of Settings.
- No backend: GitLab and notifications groups are shown as «скоро» rows, not built.
- Onboarding: no camera (simulator) → manual entry directly; wrong password → inline error under the field; relay unreachable → «Мак или relay не отвечает» + «Повторить». Keyboard only in manual mode; URL field `.URL`, no autocorrection.

## Review Focus

1. **Prompt + dangerous flag in Terminal mode** — flag before the quoted prompt, prompt still literal. Test: `SessionLaunchModeTests.dangerousFlagPrecedesPrompt` (Task 1).
2. **Dangerous flag requested in Chat mode** — ignored (request carries `skipPermissions == false`). Test: `NewTaskPlannerTests.skipPermissionsOnlyInTerminal` (Task 1).
3. **Edited quick-reply list emptied or with blank lines/duplicates** — blanks dropped, duplicates removed, empty → defaults. Test: `StoredListTests` (Task 1).
4. **Relay URL typed without scheme / with spaces / trailing slash** — normalised to `http://host:port`, invalid → nil with an inline error. Test: `RelayURLTests` (Task 1).
5. **Signing out while sessions run** — confirmation explains sessions keep running on the Mac. (Task 3, visual.)

---

### Task 1: Core — dangerous command, stored lists, relay URL

**Interfaces — Produces:**
```swift
extension SessionLaunchMode {
    public static let skipPermissionsFlag = "--dangerously-skip-permissions"
    public static func terminalCommand(cwd: String?, prompt: String?, skipPermissions: Bool) -> String
    // "cd ~/'x' && claude --dangerously-skip-permissions 'prompt'"; existing overloads delegate with false
}
// LaunchRequest gains `public let skipPermissions: Bool`;
// NewTaskPlanner.request(…, skipPermissions: Bool = false) sets it only when mode == .terminal.
public enum StoredList {
    public static func decode(_ raw: String?, defaults: [String]) -> [String]  // newline-separated; trims; drops blanks; dedups (first wins); empty → defaults
    public static func encode(_ items: [String]) -> String
}
// QuickReplies.chips(for:permanent:) — `permanent` defaults to QuickReplies.permanent.
public enum RelayURL {
    /// Trims; adds "http://" when no scheme; requires http/https and a host; drops a trailing "/"; nil if invalid or contains spaces.
    public static func normalize(_ raw: String) -> URL?
}
```
- [ ] Tests (RED first): `dangerousFlagPrecedesPrompt`, `dangerousWithoutPrompt`, `skipPermissionsOnlyInTerminal`, `StoredListTests` (decode/encode/round-trip/defaults), `chipsUseCustomPermanentList`, `RelayURLTests` (`"192.168.1.5:8080"` → `http://192.168.1.5:8080`; `"https://r.example.com/"` → `https://r.example.com`; `"ftp://x"`, `"a b"`, `""` → nil). GREEN; commit `feat(ios-core): dangerous terminal launch, editable lists, relay URL check`.

### Task 2: New Task — «Без подтверждений (опасно)»

`NewTask/NewTaskSheet.swift`: in «Дополнительно», Terminal mode only: red `Toggle("Без подтверждений (опасно)")`; turning on shows an alert «Claude будет менять файлы и запускать команды без вопросов. Включить?» [«Включить» destructive / «Отмена»]; when on, the launch button turns red and reads «Запустить без подтверждений». Chat/Brief: a footnote «В Chat и Brief Claude работает без подтверждений: агент запускает его с bypassPermissions.» Pass `skipPermissions` into `NewTaskPlanner.request`; `SessionManager.launch` uses `terminalCommand(cwd:prompt:skipPermissions:)`. Toggle resets on every sheet open. Preview `-designPreview newtaskdanger`.
- [ ] Build; screenshot; commit `feat(ios): «Без подтверждений (опасно)» for terminal launches`.

### Task 3: Settings

`Settings/SettingsScreen.swift` replaces `Views/SettingsView.swift` (NavigationStack, `.insetGrouped`, Russian):
1. **Подключение** — relay URL (mono), status dot + text («Подключено / Подключение… / Нет связи»), «Переподключить»; Маки: list of agents with online dot; «Подключить Мак» → `ConnectMacSheet`.
2. **Claude** — «Вид по умолчанию» Chat/Brief/Terminal (the same two stored keys as New Task), «Профиль» field with validation footer, «Быстрые ответы» and «Шаблоны задач» → `ListEditor` screens (reorder, delete, add; stored with `StoredList`, keys `quick_replies`, `task_templates`), used by `ChatScreen` chips and `NewTaskSheet`/composer templates.
3. **Терминал и код** — «Размер шрифта терминала» stepper 10–18 (key `terminal_font_size`, new `TerminalSession`s start from it), «Перенос строк в файлах» toggle (key `file_wrap`, FileContentView initial value).
4. **Интеграции** — «GitLab» and «Уведомления» rows with «скоро».
5. **О приложении** — version from bundle, «Логи агента: clrc logs» (mono, copy on tap).
6. **Опасная зона** (red) — «Закрыть все сессии» (confirmation with count of chats + terminals; closes both kinds), «Выйти» (confirmation «Сессии на Маке продолжат работать»).
Preview `-designPreview settings`.
- [ ] Build; screenshot; commit `feat(ios): settings in groups with editable quick replies and danger zone`.

### Task 4: Onboarding / sign in

`Onboarding/OnboardingView.swift` replaces `LoginView`: start state — app icon tile, «clrc», «Управляйте Claude Code на своём Маке с iPhone», primary «Сканировать QR с Мака» (opens `ScanToPairView`; on scan fills URL+password and signs in), hint «На Маке: clrc pair», link «Ввести вручную». Manual state — «Relay URL» (mono, `.URL`) + «Пароль» (`SecureField`), «Войти» in a bottom bar that rides above the keyboard; URL validated with `RelayURL.normalize` (inline «Проверьте адрес»). Errors: wrong password → red border + text under password; unreachable → card «Мак или relay не отвечает» + «Повторить»; rate limited → text under password. No camera → start in manual state. `AuthError.errorDescription` texts in Russian.
Previews `-designPreview onboarding|onboardingmanual|onboardingerror`.
- [ ] Build; screenshot; commit `feat(ios): onboarding with QR first and inline sign-in errors`.

## After Task 4
CLAUDE.md iOS paragraph (Settings/Onboarding folders); whole-branch review; fix Critical/Important.
