# iOS 2.0.0 Redesign — Stage 4 (Terminal, Projects, Files) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the terminal session (5.6), the Projects tab (5.9: Маки → проекты → проект → файлы, folder picker) and the file viewer (5.10), without backend changes.

**Architecture:** As in stages 1–3: decisions in `ClrcCore` (key bytes, font clamp, command groups, path crumbs, listing order/filter, project index, file text decode/search), the app renders. New `Terminal/`, `Projects/`, `Files/` folders replace `Views/TerminalView.swift`'s bar, `Views/FileBrowserView.swift` and `Views/AgentListView.swift`.

**Tech Stack:** Swift 6 / SwiftUI, SwiftTerm (iOS `TerminalView`: `font`, `controlModifier`, `inputAccessoryView`), Swift Testing.

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.6, §5.9, §5.10; brief §5.6, §5.9, §5.10, §6; mockups `Terminal.dc.html`, `Projects.dc.html`, `FileViewer.dc.html`.

## Global Constraints

- Russian copy from spec/mockups: «⌨︎ Клавиатура», «^C», «Команды», «Спрятать», «Переподключение…», «Ввод заблокирован до восстановления связи», «Сессия завершена», «Перезапустить», «Новая задача здесь», «Терминал здесь», «Все папки…», «Выбрать «<имя>»», «Файл обрезан: первые 100 КБ», «Копировать путь», «Спросить Claude».
- Terminal: default font 13 pt, pinch 10…18 pt kept per session; keyboard only via «⌨︎ Клавиатура» (no auto first responder, no tap-to-focus); one special-key row above the keyboard: Esc, Tab, Ctrl (sticky), ↑ ↓ ← →, `|`, `~`, `/`, `-`, Спрятать; ^C drawn red. Terminal surface always dark (#1C1C21).
- Folder delete only behind «⋯»/context menu with a red confirmation; paths stay inside the agent's home confinement (agent enforces; the app never builds paths outside what `fs_list` returned).
- Mac level is skipped when exactly one Mac is known.
- Out of scope (backend): git branch/dirty state, «Изменения» (git status → diff), syntax highlighting, tap-on-path in terminal, editable command sets, landscape tuning.

## Review Focus

1. **File cut at 100 KB in the middle of a multi-byte character** — the viewer still shows the text (lossy decode) with the «обрезан» banner, never a blank/error. Test: `FileTextTests.truncatedMidCharacterStillDecodes` (Task 3).
2. **Sticky Ctrl then a special key** (e.g. Ctrl then «↑») — special keys send their own bytes and clear Ctrl; Ctrl+letter typed on the keyboard is handled by SwiftTerm. Test: `TerminalKeysTests.ctrlLetterBytes` + app wiring check (Task 1, 4).
3. **Project name search with Cyrillic / mixed case** — filter is case- and diacritic-insensitive on name and path. Test: `ProjectIndexTests.filterIsCaseInsensitive` (Task 2).
4. **Breadcrumbs for `/Users/g/dev/api` and `~/dev`** — every crumb's path navigates to that exact folder. Test: `PathCrumbsTests` (Task 2).
5. **Terminal session whose PTY died** — screen shows «Сессия завершена» + «Перезапустить», not a blank terminal. Covered by `SessionScreen` lookup of tombstones (Task 4, preview `terminalended`).

---

## File Structure

`ClrcCore/Sources/ClrcCore/`: `TerminalKeys.swift` (keys, font, command groups), `FileSystemModel.swift` (`FSItem`, `PathCrumbs`, listing order/filter), `ProjectIndex.swift`, `FileText.swift`. Tests mirror.

App: `Terminal/TerminalScreen.swift` (replaces `Views/TerminalScreen.swift`), `Terminal/TerminalBars.swift`, `Terminal/CommandsSheet.swift`; `Files/FolderBrowser.swift`, `Files/FileViewerScreen.swift`, `Files/FolderPickerSheet.swift`; `Projects/ProjectsView.swift`, `Projects/MacProjectsView.swift`, `Projects/ProjectView.swift`, `Projects/ProjectsRoutes.swift`. Modify `Views/TerminalView.swift` (remove auto focus/tap focus, pinch, font from session, no SwiftTerm accessory), `Models/TerminalSession.swift` (`fontSize`), `Services/RelayWebSocket.swift` (`sendFSRead` returns raw `Data`), `Shell/MainTabView.swift` (Projects tab), `Shell/SessionRoute.swift` (ended state), `NewTask/NewTaskSheet.swift` (picker + `preferredProject`/`initialPrompt`). Delete `Views/FileBrowserView.swift`, `Views/AgentListView.swift` (keep remote-session attach inside `MacProjectsView`).

Build: as stage 3 (`build.sh`, simulator `8C7F62DD-…`). Core: `swift test`.

---

### Task 1: TerminalKeys, TerminalFont, TerminalCommands

**Interfaces — Produces:**
```swift
public enum TerminalKey: String, CaseIterable, Sendable { case esc, tab, up, down, left, right, pipe, tilde, slash, dash
    public var label: String      // "Esc","Tab","↑","↓","←","→","|","~","/","-"
    public var bytes: [UInt8] }   // 1B / 09 / 1B5B41 / 1B5B42 / 1B5B44 / 1B5B43 / "|" / "~" / "/" / "-"
public enum TerminalKeys {
    public static let interrupt: [UInt8] = [0x03]
    public static let historyUp: [UInt8]   // == TerminalKey.up.bytes
    public static func ctrl(_ letter: Character) -> UInt8?   // a–z/A–Z → 0x01…0x1A, others nil
}
public enum TerminalFont { public static let defaultSize: CGFloat = 13; public static let range: ClosedRange<CGFloat> = 10...18
    public static func clamped(_ size: CGFloat) -> CGFloat
    public static func pinched(from base: CGFloat, scale: CGFloat) -> CGFloat  // clamped(base*scale) rounded to 0.5 }
public struct TerminalCommand: Equatable, Sendable, Identifiable { public let title, command: String; public var id: String { title }
    public var bytes: [UInt8] }  // command + "\n"
public struct TerminalCommandGroup: Equatable, Sendable, Identifiable { public let title: String; public let commands: [TerminalCommand]; public var id: String { title } }
public enum TerminalCommands { public static let groups: [TerminalCommandGroup] }
// Навигация: pwd, ls -la, cd ~, cd .. ; Git: git status, git diff --stat, git log --oneline -15, git pull ;
// Claude: claude, claude --continue, /compact (no newline? -> as command with \n) ; Система: clear, df -h, ps aux | head -20, top -l 1 | head -15
```
- [ ] Tests: `specialKeyBytes` (each case), `ctrlLetterBytes` (`c`→0x03, `Z`→0x1A, `1`→nil), `fontClampAndPinch` (9→10, 20→18, pinched(13, 1.5)=18, pinched(13, 0.9)=11.5), `commandGroups` (titles `["Навигация","Git","Claude","Система"]`, every command bytes end with 0x0A, no empty group). RED → implement → GREEN → commit `feat(ios-core): terminal keys, font range and command groups`.

### Task 2: File system model, path crumbs, project index

**Interfaces — Produces:**
```swift
public struct FSItem: Equatable, Sendable, Identifiable { public let name: String; public let isDir: Bool; public let size: Int64; public let modified: Date?
    public var id: String { name }
    public init?(dict: [String: Any])            // "name","is_dir","size","mod_time"(RFC3339) ; nil without name/is_dir
    public var kindSymbol: String }              // dir "folder.fill"; md "doc.richtext"; swift/go/ts/js/py/json/yml/yaml/sh "chevron.left.forwardslash.chevron.right"; image "photo"; else "doc"
public enum FSListing {
    public static func sorted(_ items: [FSItem]) -> [FSItem]          // dirs first, then localizedStandardCompare by name
    public static func filtered(_ items: [FSItem], query: String) -> [FSItem]  // case/diacritic-insensitive contains; blank → all
}
public struct PathCrumb: Equatable, Sendable, Identifiable { public let name, path: String; public var id: String { path } }
public enum PathCrumbs {
    /// "~/dev/api" → [~:"~", dev:"~/dev", api:"~/dev/api"]; "/Users/g/x" → [/:"/", Users:"/Users", g:"/Users/g", x:"/Users/g/x"]; "~" → [~]
    public static func crumbs(for path: String) -> [PathCrumb]
    public static func join(_ parent: String, _ child: String) -> String   // no double slash; "~" + "a" → "~/a"; "/" + "a" → "/a"
}
public enum ProjectIndex {
    public static func showsMacLevel(macCount: Int) -> Bool        // > 1
    public static func filter(_ paths: [String], query: String) -> [String]   // name or path, case/diacritic-insensitive
    /// Sessions whose folder is `path` (chat cwd or terminal project path), exact match after trimming a trailing "/".
    public static func sessionCount(path: String, folders: [String?]) -> Int
}
```
- [ ] Tests: `fsItemParsesAndRejects`, `listingDirsFirstNaturalOrder` (`["b","a10","a2"]` files + dir `"z"` → `z, a2, a10, b`), `listingFilter`, `kindSymbols`, `PathCrumbsTests` (cases above + join), `filterIsCaseInsensitive` (`"АПИ"` matches `"/u/апи"`), `sessionCountMatchesExactFolder` (`"/u/api"` vs `["/u/api/", "/u/api2", nil]` → 1), `macLevel`. RED → GREEN → commit `feat(ios-core): folder listing, path crumbs and project index`.

### Task 3: FileText

**Interfaces — Produces:**
```swift
public struct FileText: Equatable, Sendable {
    public static let agentReadLimit = 100 * 1024
    public let text: String
    public let truncated: Bool            // data.count >= agentReadLimit
    public init(data: Data)               // lossy UTF-8 (String(decoding:as:)); drops a trailing U+FFFD produced by a cut
    public var lines: [String]            // split on "\n", keeps empty lines
    public func matchingLines(_ query: String) -> [Int]   // 0-based line indices, case-insensitive; blank → []
    public static func isMarkdown(_ path: String) -> Bool // .md / .markdown, case-insensitive
}
```
- [ ] Tests: `decodesUTF8`, `truncatedMidCharacterStillDecodes` (100 KB of "я" cut by one byte → non-empty, `truncated`, no trailing "\u{FFFD}"), `notTruncatedBelowLimit`, `matchingLines` (`"Foo\nbar\nfoo"`, "FOO" → [0, 2]), `markdownDetection`. RED → GREEN → commit `feat(ios-core): decode and search previewed files`.

### Task 4: Terminal screen

Modify `Views/TerminalView.swift`: no `becomeFirstResponder` in `makeUIView`, remove the tap-to-focus recognizer; `tv.inputAccessoryView = nil` (our row replaces SwiftTerm's); font from `session.fontSize`; `UIPinchGestureRecognizer` → `TerminalFont.pinched` → `tv.font`, `session.fontSize`; expose `session.terminalView` (exists) for focus/Ctrl. `TerminalSession.fontSize: CGFloat = TerminalFont.defaultSize` (`@Published`).

`Terminal/TerminalScreen.swift`: dark header (back ‹ via nav bar, title «<name> · <Mac>» + mono cwd if known, right badge «13pt» showing `fontSize`), terminal, bottom:
- view mode bar (`#26262B`): «⌨︎ Клавиатура» (tint, wide) → `terminalView.becomeFirstResponder()`; «^C» red mono → `TerminalKeys.interrupt`; «↑» → `historyUp`; «Команды» → `CommandsSheet` (groups; tap sends `bytes`, dismisses).
- input mode (keyboard visible, from keyboard notifications): one scrolling row of `TerminalKey` buttons + «Ctrl» toggle (highlighted while `terminalView.controlModifier`; observe `.terminalViewControlModifierReset`… use polling-free: set `controlModifier = true`, clear highlight on SwiftTerm's reset notification `Notification.Name("SwiftTerm.TerminalView.controlModifierReset")`) + «Спрятать» (`resignFirstResponder`). Special keys send bytes via `relay.sendInput` and clear Ctrl.
- reconnect overlay when relay not connected or the session's Mac is offline: dimmed terminal, card «Переподключение…» / «Ввод заблокирован до восстановления связи»; bars disabled.
`Shell/SessionRoute.swift`: terminal id not live but in `tombstones` → ended card «Сессия завершена» + mono project path + «Перезапустить» (`restart(endedID:)`, then pop); otherwise «Сессия закрыта».
Previews: `-designPreview terminal|terminalinput|terminalreconnect|terminalended` (fake session fed with sample ANSI output).
- [ ] Build → exit 0; screenshots; commit `feat(ios): terminal with view/input modes, pinch font and reconnect state`.

### Task 5: Folder browser, file viewer, picker

`RelayWebSocket.sendFSRead` completion gets `Data?` (base64-decoded) instead of `String?`; callers decode with `FileText(data:)`.
`Files/FolderBrowser.swift` — `FolderBrowser(agentID: String, path: String, mode: .browse | .pick((String) -> Void))`: loads `fs_list` (spinner, error text + «Повторить»), shows crumbs row (tap → `onNavigate(crumb.path)`), `.searchable` filter (`FSListing.filtered`), rows: `kindSymbol` icon, name, size/date for files (12 pt meta); dirs push `FolderRoute`, files push `FileRoute` (browse mode only). Toolbar «⋯» menu: «Новая папка» (alert → `fs_mkdir` → reload). Context menu on rows: «Удалить» (red confirmation → `fs_delete` → reload). Pick mode: bottom bar «Выбрать «<last component>»».
`Files/FileViewerScreen.swift` — loads via `sendFSRead`; mono 13 pt with line-number gutter (meta), «Перенос» toggle (wrap vs horizontal scroll), search (toolbar magnifier → field, «N из M», ↑↓ jump, matched lines highlighted with `tintSoft`), markdown files render with `MarkdownView` and a «Исходник» toggle; truncated → banner «Файл обрезан: первые 100 КБ»; bottom bar: «Копировать путь», «Спросить Claude» (opens `NewTaskSheet(preferredAgentID:, preferredProject: folder, initialPrompt: "Объясни файл <path>")`), «$_» (`openTerminal(in: folder)` → `openSessionRoute`).
`Files/FolderPickerSheet.swift` — `NavigationStack` + `FolderBrowser(mode: .pick)`; `NewTaskSheet` uses it instead of `FileBrowserView`; `NewTaskSheet` gains `preferredProject: String?` and `initialPrompt: String?`.
Delete `Views/FileBrowserView.swift`.
Previews: `-designPreview folder|file|filesearch` (fixture listing/text, no relay).
- [ ] Build → exit 0; screenshots; commit `feat(ios): folder browser, file viewer and folder picker`.

### Task 6: Projects tab

`Projects/ProjectsView.swift` — tab root `NavigationStack(path:)` with destinations `ProjectsRoute` (`.mac(agentID)`, `.project(agentID, path)`, `.folder(agentID, path)`, `.file(agentID, path)`) and `SessionRoute`; `openSessionRoute` set for this stack. Root: when `ProjectIndex.showsMacLevel` is false → `MacProjectsView` of the only Mac; else Mac cards (name, «в сети»/«не в сети» dot, `ru(n, "сессия", "сессии", "сессий")` from app sessions of that Mac) + «Подключить ещё Мак» (sheet: one paragraph how to install `clrc` and run `clrc start`; mono commands). No Macs → `ContentUnavailableView`.
`MacProjectsView(agent)` — `.searchable` (`ProjectIndex.filter`) over `recentProjects(for:)`; rows: name, mono path, «N сессий» (`ProjectIndex.sessionCount` over chat cwds + terminal project paths of that Mac); «Все папки…» → `.folder(agentID, "~")`; section «Запущено на Маке» from `relay.requestSessionList` (sessions not in the app) → tap `attachSession` then push its route.
`ProjectView(agent, path)` — header: name 22 pt bold + mono path; two big buttons «Новая задача здесь» (NewTaskSheet with `preferredProject: path`) and «Терминал здесь» (`openTerminal` → push); «Сессии в проекте» (rows with `StatusIcon` → push route); «Файлы» → inline first level of `FolderBrowser(path)` (navigates within the stack).
`Shell/MainTabView.swift`: Projects tab → `ProjectsView()`. Delete `Views/AgentListView.swift`.
Previews: `-designPreview projects|macprojects|project` (fake relay agents + temp store as in `newtask`).
- [ ] Build → exit 0; `swift test`; screenshots; commit `feat(ios): projects tab — Macs, projects, project page`.

## After Task 6
Update `CLAUDE.md` iOS paragraph (Terminal/Projects/Files folders, preview states); whole-branch review; fix Important; ledger minors.
