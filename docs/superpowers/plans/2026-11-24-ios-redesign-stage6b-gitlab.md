# iOS 2.0.0 Redesign — Stage 6b (GitLab review) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** «Ревью → GitLab»: merge requests list (Назначены мне / Мои / Все), MR overview (branches, pipeline, description, files with +/−, discussions count), file diffs with existing line discussions, comment on a line, general comment, Approve, and Merge / Закрыть / Открыть в браузере behind «···» with confirmation; «Попросить Claude сделать ревью».

**Architecture:** The phone calls the GitLab REST API v4 directly (brief §8: «запросы с телефона напрямую в GitLab API»), token in the iOS Keychain. `ClrcCore` holds the API surface as pure values (endpoint → URLRequest, JSON models, diff entries → `DiffFile`), tested without network. The app adds `GitLabClient` (URLSession), Settings → GitLab, and the screens reusing `DiffFileScreen`.

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.7, §5.8; brief §5.7, §5.8, §5.11 (GitLab group), §8; mockups `ReviewList.dc.html`, `MergeRequest.dc.html`, `Diff.dc.html`.

## Global Constraints

- API v4, header `PRIVATE-TOKEN`; base URL normalised (https when no scheme, no trailing `/`); token only in Keychain (`kSecClassGenericPassword`, service `clrc.gitlab`), never in UserDefaults or logs.
- Endpoints: `GET /merge_requests?scope=assigned_to_me|created_by_me|all&state=opened&per_page=50&order_by=updated_at`; `GET /projects/:id/merge_requests/:iid`; `GET …/diffs?per_page=100`; `GET …/discussions?per_page=100`; `POST …/approve`; `POST …/notes {body}`; `POST …/discussions {body, position{position_type:text, base_sha, start_sha, head_sha, old_path, new_path, new_line|old_line}}`; `PUT …/merge`; `PUT /projects/:id/merge_requests/:iid {state_event: close}`.
- Lock/generated files hidden by default (`generated_file` or name in package-lock.json, yarn.lock, pnpm-lock.yaml, go.sum, Cargo.lock, Podfile.lock, Gemfile.lock, composer.lock), with «Показать скрытые (N)».
- Merge and Close only from «···», each with a red confirmation. Approve and Комментарий in the bottom bar.
- Errors: 401 → «Токен GitLab не подходит» (link to Settings); 403 → «Нет прав»; network → «GitLab не отвечает».
- Out of scope: suggestions («Предложить правку»), resolving discussions, pipeline jobs list, editing/deleting notes.

## Review Focus

1. **Token leakage** — not in URL query, not logged, not in UserDefaults. Test: `GitLabAPITests.tokenOnlyInHeader`.
2. **Line comment on a removed line vs added/context line** — position uses `old_line` for removed, `new_line` for added, both for context. Test: `GitLabAPITests.linePositionPerLineKind`.
3. **Project ids with namespaces / special characters** — numeric `project_id` used, never the path. Test: `GitLabAPITests.usesNumericProjectID`.
4. **Renamed/new/deleted/binary diff entries from GitLab** (no `diff --git` header in `diff`) — converted to `DiffFile` with the right kind. Test: `GitLabDiffsTests`.
5. **Empty token / invalid base URL** — client refuses to send. Test: `GitLabAPITests.refusesWithoutTokenOrURL`.

---

### Task 1: ClrcCore GitLab API surface
`GitLabModels.swift`, `GitLabAPI.swift`, tests.
```swift
public enum GitLabScope: String, CaseIterable, Sendable { case assigned = "assigned_to_me", mine = "created_by_me", all = "all" }
public struct GitLabUser: Decodable, Equatable, Sendable { name, username: String }
public struct GitLabPipeline: Decodable, Equatable, Sendable { status: String; webURL: String? }  // web_url
public struct GitLabMR: Decodable, Equatable, Sendable, Identifiable { id, iid, projectID: Int; title, sourceBranch, targetBranch, webURL, reference: String (references.full); author: GitLabUser; draft: Bool; userNotesCount: Int; updatedAt: Date?; description: String?; headPipeline: GitLabPipeline?; diffRefs: GitLabDiffRefs? }
public struct GitLabDiffRefs: Decodable, Equatable, Sendable { baseSHA, headSHA, startSHA: String }
public struct GitLabDiffEntry: Decodable, Equatable, Sendable { oldPath, newPath, diff: String; newFile, renamedFile, deletedFile: Bool; generatedFile: Bool? }
public struct GitLabNote: Decodable, Equatable, Sendable, Identifiable { id: Int; body: String; author: GitLabUser; system: Bool; position: GitLabPosition?; createdAt: Date? }
public struct GitLabPosition: Decodable, Equatable, Sendable { newPath, oldPath: String?; newLine, oldLine: Int? }
public struct GitLabDiscussion: Decodable, Equatable, Sendable, Identifiable { id: String; notes: [GitLabNote] }
public enum GitLabJSON { public static let decoder: JSONDecoder }   // snake_case keys, ISO8601 with fractional seconds
public enum GitLabEndpoint: Equatable, Sendable { case mergeRequests(GitLabScope), mergeRequest(project: Int, iid: Int), diffs(project: Int, iid: Int), discussions(project: Int, iid: Int), approve(project: Int, iid: Int), note(project: Int, iid: Int, body: String), lineComment(project: Int, iid: Int, body: String, refs: GitLabDiffRefs, oldPath: String, newPath: String, line: DiffLine), merge(project: Int, iid: Int), close(project: Int, iid: Int) }
public struct GitLabAPI: Sendable { public init?(baseURL: String, token: String)   // nil without token or valid http(s) URL
    public func request(_ endpoint: GitLabEndpoint) -> URLRequest }
public enum GitLabDiffs { public static func files(_ entries: [GitLabDiffEntry]) -> [DiffFile]
    public static func isHidden(_ entry: GitLabDiffEntry) -> Bool }
public enum GitLabDiscussions { public static func notes(on file: DiffFile, in discussions: [GitLabDiscussion]) -> [String: [GitLabNote]] }  // key "o<old>"/"n<new>"
```
- [ ] Tests RED→GREEN; commit `feat(ios-core): GitLab API requests, models and MR diffs`.

### Task 2: App — Keychain, GitLabClient, Settings → GitLab
`GitLab/GitLabCredentials.swift` (Keychain get/set/delete token; base URL in UserDefaults `gitlab_url`), `GitLab/GitLabClient.swift` (async `send<T: Decodable>`, `send(_:)` for empty replies; maps 401/403/network to `GitLabError` with Russian text). Settings «Интеграции → GitLab» row opens `GitLabSettingsView` (URL, token SecureField, «Проверить» → `GET /user`, «Отключить»).
- [ ] Build; commit `feat(ios): connect GitLab with a token kept in the Keychain`.

### Task 3: App — MR list, MR overview, file diff with discussions, actions
`GitLab/MergeRequestList.swift` (scope chips, rows: title, `!iid`, reference, author, branches, notes count, draft; pull to refresh; «Подключите GitLab» when not configured), `GitLab/MergeRequestScreen.swift` (header, pipeline status, description collapsed «Ещё», files list with A/M/D/R, +/−, «просмотрен», hidden lock files toggle, discussions count; bottom Approve · Комментарий · «···» Merge/Закрыть/Открыть в браузере with confirmations; «Попросить Claude сделать ревью» → NewTaskSheet with prompt), file diff → `DiffFileScreen` extended with optional per-line notes and «Комментировать строку» (long-press a line → sheet with line preview and field → `lineComment`). Review tab shows the list under «GitLab». Previews `-designPreview gitlablist|gitlabmr`.
- [ ] Build; screenshots; commit `feat(ios): GitLab merge requests — list, overview, diff comments, approve and merge`.
