# iOS 2.0.0 Redesign — Stage 6a (git status & diff: protocol + Diff, Review «От Claude») Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the phone see what Claude changed: two new agent requests (`git_status`, `git_diff`) routed by the relay like `fs_*`, and on iOS the diff screen, a turn's changes (from the report card «Diff ›» and the «Покажи diff» chip), a project's «Изменения» section with its branch, and the Review tab's «От Claude» list.

**Architecture:** Agent: `agent/git_ops.go` runs `git` with a timeout inside the home-confined folder (`fsResolve`), validates file arguments, caps output. Relay: `git_status`/`git_diff` forwarded with `agent_id` stripped and `*_result` correlated by `request_id` (same as `fs_*`). iOS: `ClrcCore` parses `git status` results and unified diffs; app screens render them through an async client like `FSClient`.

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.7 (От Claude), §5.8 (ход Claude, Diff файла), §5.9 (Изменения, ветка); brief §5.7, §5.8, §8 (backend: diff хода, git-статус и ветка); mockups `ReviewList.dc.html`, `MergeRequest.dc.html` (kind claude), `Diff.dc.html`.

## Global Constraints

- Protocol (CLAUDE.md: keep relay/agent/iOS in sync; all fields optional, old peers interoperate):
  - client → relay `git_status` `{agent_id, request_id, path}` → agent `{request_id, path}`; agent → `git_status_result` `{request_id, branch, upstream, ahead, behind, files:[{path, status}], error}`.
  - client → relay `git_diff` `{agent_id, request_id, path, files?:[string]}` → agent `{request_id, path, files}`; agent → `git_diff_result` `{request_id, diff, truncated, error}`.
- Agent security: `path` through `fsResolve` (home confinement); `files` must be relative, cleaned, without `..`, not starting with `-`; absolute file paths inside the repo are converted to relative, others rejected; `git` runs with `--no-pager`, `-c core.quotepath=off`, no external diff/textconv (`--no-ext-diff --no-textconv`), `GIT_TERMINAL_PROMPT=0`, 10 s timeout; diff output capped at 512 KB (`truncated`).
- Untracked files appear in `git_status` as `??` and in `git_diff` as additions (`git diff --no-index /dev/null <file>`). A repo without commits diffs against the empty tree.
- Not a repo → `error: "not a git repository"`; iOS shows «Не git-репозиторий» and hides «Изменения».
- iOS: diff always dark (`Palette.code`), SF Mono 12–13 pt, old/new line numbers, +/− row backgrounds, hunk headers; «Перенос ✓» toggle; ‹ ханк k/n › and «Файл ›». Out of scope here: word-diff, split view in landscape, minimap, inline comments (GitLab in 6b), syntax highlighting.

## Review Focus

1. **`files` argument injection** (`--output=/etc/x`, `../../etc/passwd`, absolute path outside repo) — rejected before running git. Test: `TestGitDiffRejectsUnsafeFiles`.
2. **Huge diff** (lockfile) — capped at 512 KB with `truncated`, app shows «Diff обрезан». Test: `TestGitDiffCapsOutput` + `UnifiedDiffTests.truncatedInputParsesWhatItHas`.
3. **Renames, deletions, binary files, "\ No newline at end of file"** — parser keeps file names/status and never crashes. Test: `UnifiedDiffTests`.
4. **Fresh repo without commits / untracked files** — status and diff still work. Test: `TestGitStatusFreshRepo`, `TestGitDiffIncludesUntracked`.
5. **Relay strips `agent_id` and correlates results** for both new types. Test: `TestGitRequestsUseRequestCorrelation`.

---

### Task 1: Agent git ops
Create `agent/git_ops.go`, `agent/git_ops_test.go`; wire `git_status`/`git_diff` in `agent/ws_client.go` (handlers like `handleFSList`).
```go
type GitFile struct{ Path string `json:"path"`; Status string `json:"status"` }   // "M","A","D","R","??", etc. (porcelain XY collapsed: worktree char if not ' ', else index char)
type GitStatus struct{ Branch, Upstream string; Ahead, Behind int; Files []GitFile }
func gitStatus(ctx context.Context, path string) (GitStatus, error)          // git status --porcelain=v1 -b -z
func gitDiff(ctx context.Context, path string, files []string) (diff string, truncated bool, err error)
func safeRepoFiles(repo string, files []string) ([]string, error)            // validation described above
const gitTimeout = 10 * time.Second; const maxDiffBytes = 512 << 10
```
- [ ] Tests (temp HOME + `git init` repos): `TestGitStatusReportsBranchAndFiles`, `TestGitStatusFreshRepo`, `TestGitStatusNotARepo`, `TestGitDiffTrackedAndFiltered`, `TestGitDiffIncludesUntracked`, `TestGitDiffRejectsUnsafeFiles`, `TestGitDiffCapsOutput`, `TestGitOpsRejectOutsideHome`; handler test `TestGitStatusHandlerRespondsWithRequestID`. RED → GREEN; `go vet`; commit `feat(agent): git status and diff requests`.

### Task 2: Relay routing
`relay/hub.go`: client types `git_status`, `git_diff` → `handleClientGitRequest` (forward payload minus `agent_id`, store `request_id`); agent results `git_status_result`, `git_diff_result` in the correlation list.
- [ ] Test `TestGitRequestsUseRequestCorrelation` (both types; `files` forwarded; `agent_id` stripped; empty `request_id` not forwarded). RED → GREEN; commit `feat(relay): route git status and diff requests`.

### Task 3: ClrcCore — GitStatusInfo, UnifiedDiff
```swift
public struct GitStatusInfo: Equatable, Sendable { branch, upstream: String; ahead, behind: Int; files: [GitFileStatus]; var isDirty: Bool
    public init?(payload: [String: Any]) }   // nil when "error" non-empty
public struct GitFileStatus: Equatable, Sendable, Identifiable { path, status: String; var id: String { path }
    var kind: ChangeKind }                    // .added (A, ??), .modified, .deleted (D), .renamed (R), .other
public enum ChangeKind: String, Sendable { case added = "A", modified = "M", deleted = "D", renamed = "R", other = "?" }
public struct DiffLine: Equatable, Sendable { enum Kind { case context, added, removed, noNewline }; kind; oldNumber, newNumber: Int?; text: String }
public struct DiffHunk: Equatable, Sendable { header: String; lines: [DiffLine] }
public struct DiffFile: Equatable, Sendable, Identifiable { oldPath, newPath: String; var path: String; kind: ChangeKind; isBinary: Bool; hunks: [DiffHunk]; additions, deletions: Int; id = path }
public enum UnifiedDiff { public static func parse(_ text: String) -> [DiffFile] }
public enum DiffPaths { public static func relative(_ files: [String], to repo: String) -> [String] }  // strip repo prefix ("/u/api/x" → "x"; "~/dev/api/x" with repo "~/dev/api" → "x"); keep relative as is
```
- [ ] Tests `UnifiedDiffTests`: modified with two hunks (numbers), added file (`new file mode`, `/dev/null`), deleted, rename (`rename from/to`), binary (`Binary files … differ`), `\ No newline at end of file`, untracked via `--no-index` header, `truncatedInputParsesWhatItHas`; `GitStatusInfoTests`; `DiffPathsTests`. RED → GREEN; commit `feat(ios-core): parse git status and unified diffs`.

### Task 4: iOS — GitClient, Diff screens, entry points
- `RelayWebSocket`: `sendGitStatus`, `sendGitDiff` (+ result types in the pending map).
- `Files/GitClient.swift`: async `status(agentID:path:)`, `diff(agentID:path:files:)` (10 s timeout as `FSClient`, 20 s for diff).
- `Diff/ChangesScreen.swift` — `ChangesScreen(agentID, repo, files, title)`: loads `git_diff`, list of `DiffFile` (badge A/M/D/R, path mono, +N −M, «просмотрен» check), progress «k из n», banner when truncated; tap → `DiffFileScreen`.
- `Diff/DiffFileScreen.swift` — header path/+/−, wrap toggle, unified lines (dark; old/new numbers; +/− backgrounds `#1E3A2A`/`#3A1E22`; hunk header rows), bottom «‹ ханк k/n ›», «Просмотрен», «Файл ›».
- Entry points: report card «N файлов изменено · Diff ›» (chat) → `ChangesScreen(repo: chat cwd, files: DiffPaths.relative(changedFiles))`; «Покажи diff» chip opens the same (no message sent) when the report has files, else falls back to sending text; Project page: branch + «есть изменения» under the title, section «Изменения» (git_status files; tap → `ChangesScreen(files:[path])`, «Все изменения» → files nil).
- Previews `-designPreview changes|difffile`.
- [ ] Build; screenshots; commit `feat(ios): diff screens for a turn's and a project's changes`.

### Task 5: Review tab — «От Claude»
`Review/ReviewScreen.swift` replaces the placeholder tab: segment «От Claude» / «GitLab» (GitLab shows «Подключите GitLab» until 6b); «От Claude» lists turns with `changedFiles` from all chat sessions (newest first): title, project · Мак, «ход N», «N файлов», label «ждёт ответа» (open questions) / «новое» / «просмотрено» (viewed turn ids in UserDefaults `reviewed_turns`, capped 500); filter chips by project; empty «Нечего ревьюить». Tap → `ChangesScreen` and mark viewed. Pure part in ClrcCore: `ReviewItems.build(sessions:[ReviewSessionSnapshot], viewed:Set<String>) -> [ReviewItem]` (id = "\(sessionID):\(turnID)").
- [ ] Core tests `ReviewItemsTests` (only turns with files; newest first; labels; project filter). Build; preview `-designPreview review`; commit `feat(ios): review tab lists Claude's turns with changes`.

## After Task 5
CLAUDE.md: protocol section (new message types), iOS folders; whole-branch review; fix Critical/Important.
