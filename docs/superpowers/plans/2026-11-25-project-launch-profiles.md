# Project Launch Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saved projects (Mac + folder + profile + mode) whose launch from the iPhone behaves like `c <profile>` in that folder, on every Mac, never silently under another account.

**Architecture:** The agent learns `~/harness` profiles (list, `.env`, `HARNESS_PROFILE`) and answers a new `profiles_list` request; `connect` gains `profile_strict`. The relay forwards the new request and per-session `error`s. The iPhone stores project configs and per-session launch profiles in `SessionsStore`, resolves the profile for each launch in ClrcCore, and adds `launch_args` to the terminal `claude` command.

**Tech Stack:** Go 1.22 (`nhooyr.io/websocket`), Swift 6 / SwiftUI (iOS 26), Swift Testing, zsh (harness).

**Spec:** `docs/superpowers/specs/2026-11-25-project-launch-profiles-design.md`

## Global Constraints

- Profile names: `validIdent` (`^[a-z0-9-]+$`, ≤64) on agent; `normalizedProfile` on iOS.
- Harness root: `$HARNESS_ROOT` else `~/harness`; profile usable only if `~/.claude-<name>/.harness-state.json` exists; names starting with `_` are not profiles.
- `.env` values are never logged; skipped lines are logged by line number only.
- `CLAUDE_CONFIG_DIR`, `CLRC_SESSION=1`, `HARNESS_PROFILE` are set after `.env` vars and win over them.
- All new protocol fields optional; old agent/relay/app keep working.
- Strict only when the profile comes from a project config; strict failure spawns nothing and sends no `session_ready`.
- Strict error text: `профиль «<name>» не найден на этом Маке — harness sync <name>`.
- `profiles_list` iOS timeout: 10 s; fallback = today's text field.
- Picker default label: `По умолчанию (<p> — из настроек)` when Settings has a profile, else `Как на Маке (<default>)`, or `Как на Маке` when the Mac reports none.
- Go: `gofmt`, `go vet`, `go test -race`; Swift logic in ClrcCore with Swift Testing. Commit per task, `<type>: <description>` + Co-Authored-By trailer.

## Review Focus

1. A `.env` with `export`, quotes, comments, `=` inside values, and junk lines → parsed vars correct, junk skipped, no value in logs (Task 2 test `TestParseEnvFile`).
2. A project's saved profile deleted/unsynced on the Mac → terminal tab shows the agent's message, nothing typed (Task 3 `TestStrictProfileRefusesPTY`, Task 9 `sessionErrorMarksTerminalFailed`).
3. Old relay/agent: `profiles_list` never answers → picker falls back to text field after 10 s, no hang (Task 7 `profilesRequestTimesOut`).
4. App restart / agent restart after the project's profile was changed → sessions reattach with their original profile (Task 6 `persistedSessionKeepsProfile`, Task 8 reattach uses stored values).
5. Same folder saved on Mac A (`rtd`), opened on Mac B without `rtd` → prefill mode only, profile left default (Task 6 `suggestedConfigDropsMissingProfile`).

---

### Task 1: harness `mac-setup.sh` builds the agent from `main` with a version

**Files:**
- Modify: `~/harness/scripts/mac-setup.sh:17,95`

- [ ] **Step 1:** Change `clrc_branch="${CLRC_BRANCH:-feat/structured-output}"` to `clrc_branch="${CLRC_BRANCH:-main}"`.
- [ ] **Step 2:** Build with the version: in `setup_clrc` replace the `go build` line with
  `(cd "$clrc_src/agent" && go build -ldflags "-X main.version=$(git -C "$clrc_src" describe --tags --always)" -o "$HOME/.local/bin/clrc" ./cmd/)`.
- [ ] **Step 3: Verify:** `bash -n ~/harness/scripts/mac-setup.sh && ~/harness/bin/harness check` → no errors; `CLRC_SRC=$(mktemp -d)/clrc bash -c 'source <(sed -n "/^clone_or_update()/,/^}/p" ~/harness/scripts/mac-setup.sh); clone_or_update git@github.com:tergeoo/clrc.git "$CLRC_SRC" main'` clones successfully.
- [ ] **Step 4: Commit** in `~/harness`: `fix: mac-setup builds clrc from main with an embedded version`.

### Task 2: Agent — harness profile discovery and `.env` parsing

**Files:**
- Create: `agent/harness.go`, `agent/harness_test.go`

**Interfaces — Produces:**
- `type HarnessProfile struct { Name, Description string; LaunchArgs []string }`
- `func harnessRoot(home string) string` — `$HARNESS_ROOT` or `home/harness`.
- `func LoadHarnessProfiles(home, root string) []HarnessProfile` — synced profiles sorted by name; bad `profile.json` skipped + logged.
- `func harnessProfileDefined(root, name string) bool` — `profiles/<name>/profile.json` exists (synced or not).
- `func ParseEnvFile(data []byte) (vars []string, skippedLines []int)` — returns `KEY=value` entries.

- [ ] **Step 1: Failing tests** (`t.TempDir()` as home + root):
  - `TestLoadHarnessProfiles`: root has `profiles/rtd/profile.json` (`{"description":"RTD","launch_args":["--dangerously-skip-permissions"]}`), `profiles/dats` (not synced), `profiles/_template`, `profiles/Bad_Name`; home has `.claude-rtd/.harness-state.json`. Want exactly `[{rtd, "RTD", ["--dangerously-skip-permissions"]}]`.
  - `TestLoadHarnessProfilesMissingRoot`: nonexistent root → empty, no panic.
  - `TestHarnessProfileDefined`: `dats` → true, `nope` → false.
  - `TestParseEnvFile` (table): input
    ```
    # comment
    export A=1
    B="two words"
    C='x=y'
    D=plain=with=eq

    not a var
    1BAD=x
    ```
    want vars `["A=1","B=two words","C=x=y","D=plain=with=eq"]`, skipped `[7,8]`.
- [ ] **Step 2:** `cd agent && go test ./ -run 'Harness|ParseEnvFile'` → FAIL (undefined).
- [ ] **Step 3:** Implement in `agent/harness.go`. Keys must match `^[A-Za-z_][A-Za-z0-9_]*$`; only one level of matching outer quotes is stripped; no variable expansion.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5: Commit** `feat(agent): discover harness profiles and parse their env files`.

### Task 3: Agent — launch profile resolution, harness env, strict mode

**Files:**
- Modify: `agent/child_env.go`, `agent/pty_session.go`, `agent/chat_session.go` (ChatOptions/ensureProcess), `agent/ws_client.go` (`connectReq`, `sessionConfigDir`→`resolveLaunch`, PTY/chat connect), `agent/config.go`, `agent/cmd/main.go`
- Modify: `protocol/fixtures/connect.json` (add `"profile_strict": true`)
- Test: `agent/launch_profile_test.go`, existing `agent/child_env_test.go`, `agent/protocol_contract_test.go`

**Interfaces:**
- Consumes: Task 2.
- Produces:
  - `type LaunchProfile struct { Name, ConfigDir string; Harness bool; Env []string }` (zero value = no profile, CLI default).
  - `Config.Profile string` — raw `CLRC_PROFILE` (set in `cmd/main.go` next to `ClaudeConfigDir`).
  - `func (c *WSClient) resolveLaunch(profile string, strict bool) (LaunchProfile, error)` — empty profile → agent default (`Config.Profile`; harness treatment applies to it; if `CLRC_CLAUDE_CONFIG_DIR` is set it wins and `Harness=false`). Strict + (invalid name | not found | defined in harness but unsynced) → error with the Global Constraints text. Non-strict failure → agent default + error (today's behaviour).
  - `buildChildEnv(base []string, lp LaunchProfile) []string`, `childEnv(lp LaunchProfile)`, `ptyEnv(lp LaunchProfile)`.
  - `NewPTYSession(id, command string, cols, rows uint16, lp LaunchProfile, sendFn func(string, []byte))`; `ChatOptions.Launch LaunchProfile` replaces `ChatOptions.ConfigDir`.
  - `connectReq.ProfileStrict bool \`json:"profile_strict"\``.
  - `func (c *WSClient) sendSessionError(sessionID, message string)` → `{"type":"error","payload":{"session_id":…,"message":…}}`.

- [ ] **Step 1: Failing tests**
  - `TestBuildChildEnvHarness`: base `["PATH=/bin","TOKEN=old","CLAUDE_X=1"]`, lp `{Name:"rtd",ConfigDir:"/h/.claude-rtd",Harness:true,Env:["TOKEN=new","CLAUDE_CONFIG_DIR=/evil","HARNESS_PROFILE=evil"]}` → contains `TOKEN=new`, `HARNESS_PROFILE=rtd`, `CLAUDE_CONFIG_DIR=/h/.claude-rtd`, `CLRC_SESSION=1`; exactly one of each key; no `CLAUDE_X`.
  - `TestResolveLaunch` (table, temp home/root via `HARNESS_ROOT`): synced harness `rtd` → Harness, Env from `.env`; plain dir `.claude-solo` → Harness false; `""` with `Config.Profile="rtd"` → rtd with harness env; strict unsynced `dats` → error containing `harness sync dats`; strict missing `nope` → error; non-strict missing → default + error.
  - `TestStrictProfileRefusesPTY`: drive `handleConnect` with `{"session_id":<uuid>,"profile":"nope","profile_strict":true}` and a capturing send fn → no session in `c.sessions`, one `error` message with that `session_id`, no `session_ready`.
  - `TestStrictProfileRefusesChat`: same with `"kind":"chat"` → no entry in `c.chats`, a chat error for the session.
  - Update existing `TestBuildChildEnv` / `TestPTYEnvAdvertisesTerminal` to the new signatures (state in the commit message that only signatures changed, not expectations).
  - `TestContractConnectDecodesEveryField`: also require `req.ProfileStrict`.
- [ ] **Step 2:** `cd agent && go test ./...` → FAIL (build errors).
- [ ] **Step 3:** Implement. `.env` is read on every `resolveLaunch` (no cache). Chat strict failure: send the error and return before creating the session.
- [ ] **Step 4:** `cd agent && gofmt -l . && go vet ./... && go test -race ./...` → empty gofmt output, PASS.
- [ ] **Step 5: Commit** `feat(agent): launch sessions like 'c <profile>' and refuse missing strict profiles`.

### Task 4: Agent — `profiles_list` request

**Files:**
- Modify: `agent/ws_client.go` (`handleText` switch, new `handleProfilesList`)
- Create: `protocol/fixtures/profiles_list_result.json`; update `protocol/README.md` table
- Test: `agent/protocol_contract_test.go`

**Interfaces — Produces:** reply type `profiles_list_result`, payload `{request_id, default_profile, profiles:[{name, description, launch_args, harness}]}`; `func profilesListPayload(requestID, defaultProfile string, harness []HarnessProfile, plainDirs []string) map[string]any` (plain dirs = `~/.claude-<name>` with valid name, not harness profiles, `harness:false`, empty description, `launch_args: []`; whole list sorted by name).

- [ ] **Step 1: Fixture** `profiles_list_result.json`: request `req-2`, `default_profile` `personal`, profiles `personal` (harness, description `Personal`, `["--dangerously-skip-permissions"]`), `rtd` (harness, `RTD Lab (gitlab.rtdlab.cloud): Go backend monorepo`, same args), `solo` (plain).
- [ ] **Step 2: Failing test** `TestContractProfilesListMatchesFixture`: build via `profilesListPayload` from the fixture's values → `assertJSONEqual` with fixture payload.
- [ ] **Step 3:** `go test ./ -run Contract` → FAIL.
- [ ] **Step 4:** Implement `profilesListPayload` and `handleProfilesList` (`{request_id}` in; discovery via Task 2 + `os.ReadDir(home)` for `.claude-*` dirs).
- [ ] **Step 5:** `go test -race ./...` → PASS. **Commit** `feat(agent): answer profiles_list with this Mac's Claude profiles`.

### Task 5: Relay — forward `profiles_list`, route per-session errors

**Files:**
- Modify: `relay/hub.go` (client switch ~L618: add `profiles_list` to the `list_sessions` handling; agent switch ~L428: add `profiles_list_result` to the async-result list; new agent case `error`)
- Test: `relay/protocol_contract_test.go`, new `relay/session_error_test.go` (follow `chat_routing_test.go` harness style)

- [ ] **Step 1: Failing tests**
  - `TestProfilesListRoundTrip`: client sends `profiles_list{agent_id, request_id:"req-2"}` → agent receives it without `agent_id`; agent replies with the fixture → client receives it unchanged.
  - `TestAgentSessionErrorReachesOwningClient`: client A owns session S, client B connected; agent sends `error{session_id:S, message:"m"}` → A receives it, B does not.
  - `TestAgentErrorWithoutSessionIsNotForwarded`: `error{message:"m"}` → no client receives it.
- [ ] **Step 2:** `cd relay && go test ./...` → FAIL.
- [ ] **Step 3:** Implement (route with `hub.RouteTextToClient(sessionID, data)`).
- [ ] **Step 4:** `gofmt -l . && go vet ./... && go test -race ./...` → PASS. **Commit** `feat(relay): forward profiles_list and per-session agent errors`.

### Task 6: ClrcCore — profiles, project configs, launch resolution, session profile

**Files:**
- Create: `ClrcCore/Sources/ClrcCore/MacProfiles.swift`, `ProjectConfig.swift`, `LaunchProfileResolver.swift`
- Modify: `SessionsStore.swift` (StoreFile `configsByAgent`), `PersistedSession.swift` (+`profile`, `profileStrict`), `SessionLaunchMode.swift` (`terminalCommand(…, launchArgs:)`), `NewTaskPlanner.swift` (`LaunchRequest` +`profileStrict: Bool`, `launchArgs: [String]`)
- Test: `Tests/ClrcCoreTests/LaunchProfileTests.swift`, `ProtocolContractTests.swift`, `SessionsStoreTests.swift`

**Interfaces — Produces:**
- `struct MacProfile: Equatable, Sendable { name, description: String; launchArgs: [String]; harness: Bool }`
- `struct MacProfiles: Equatable, Sendable { defaultProfile: String?; profiles: [MacProfile]; init?(payload: [String: Any]); func profile(named: String?) -> MacProfile? }`
- `struct ProjectConfig: Codable, Equatable, Sendable { var profile: String?; var mode: SessionLaunchMode? }` (make `SessionLaunchMode` `Codable` if it is not).
- `SessionsStore`: `projectConfig(path:agentID:) -> ProjectConfig?`, `setProjectConfig(_:path:agentID:)` (nil removes), `savedProjects(forAgent:) -> [String]` (sorted by last path component), `suggestedConfig(path:forAgent:available:) -> ProjectConfig?` (same path saved on another agent; profile kept only if in `available`).
- `struct ResolvedProfile: Equatable { name: String?; strict: Bool }`; `enum LaunchProfileResolver { static func resolve(taskOverride: String?, project: ProjectConfig?, settingsProfile: String?) -> ResolvedProfile; static func defaultLabel(settingsProfile: String?, macDefault: String?) -> String }`
- `PersistedSession.profile: String?`, `profileStrict: Bool` (decode default false; init params default nil/false).

- [ ] **Step 1: Failing tests** (Swift Testing):
  - `profilesListFixtureDecodes` — from `profiles_list_result.json`: default `personal`, 3 profiles, `rtd.launchArgs == ["--dangerously-skip-permissions"]`, `solo.harness == false`.
  - `resolverPrecedence` (args): (task `x`, project `rtd`, settings `p`) → (`x`, false); (nil, `rtd`, `p`) → (`rtd`, true); (nil, project with nil profile, `p`) → (`p`, false); (nil, nil, nil) → (nil, false).
  - `defaultLabelNamesTheRealProfile`: (`rtd`, `personal`) → `По умолчанию (rtd — из настроек)`; (nil, `personal`) → `Как на Маке (personal)`; (nil, nil) → `Как на Маке`.
  - `terminalCommandAddsLaunchArgsOnce`: cwd `~/w/backend`, launchArgs `["--dangerously-skip-permissions","--model","opus 4"]`, skipPermissions true → `cd '~/w/backend' && claude --dangerously-skip-permissions --model 'opus 4'` (match existing quoting helpers' output; flag not duplicated).
  - `projectConfigsPersistAndOldFilesLoad`: set config, reload store from same dir → equal; a JSON file without `configsByAgent` loads with no configs.
  - `savedProjectsSurviveRecentsCap`: saved project + 9 newer recents → still in `savedProjects`.
  - `suggestedConfigDropsMissingProfile`: Mac A `~/w/backend` = (`rtd`, `.terminal`); for Mac B with available `["personal"]` → (`nil`, `.terminal`); with `["rtd"]` → (`rtd`, `.terminal`).
  - `persistedSessionKeepsProfile`: encode/decode round trip keeps `profile`/`profileStrict`; legacy JSON → nil/false.
- [ ] **Step 2:** `swift test` → FAIL (build).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → all pass. **Commit** `feat(core): project launch configs, profile resolution and per-session profile`.

### Task 7: App — relay API for profiles, strict connects, session errors

**Files:**
- Modify: `Claude Orchestrator/Services/RelayWebSocket.swift`
- Test: `ClrcCore` holds the logic; here verify by build + Task 9 preview.

**Interfaces — Produces:**
- `func requestProfiles(agentID: String, completion: @escaping (MacProfiles?) -> Void)` — `profiles_list`, 10 s timeout → `nil` (mirror `requestSessionList`'s pending-callback + timeout pattern).
- `sendConnect(agentID:sessionID:cols:rows:name:profile: String? = nil, profileStrict: Bool = false)`; `sendChatConnect(…, profileStrict: Bool = false)` — send `profile_strict` only when true.
- `var onSessionError: ((String, String) -> Void)?` — `error` with `session_id` → `(sessionID, message)`; without → existing `onError`.

- [ ] **Step 1:** Add a ClrcCore test `profilesRequestTimesOut` only if the timeout logic is extracted into ClrcCore (preferred: a tiny `PendingRequests<T>` with injected clock); otherwise skip and rely on Step 3.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** `xcodebuild … -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`. **Commit** `feat(ios): request Mac profiles, send strict profiles, route session errors`.

### Task 8: App — SessionManager uses resolved and stored profiles

**Files:**
- Modify: `Claude Orchestrator/Services/SessionManager.swift`, `Models/TerminalSession.swift`, `Models/ChatSession.swift`

**Interfaces:**
- Consumes: Tasks 6–7.
- Produces: `SessionManager.profiles(for agentID: String) -> MacProfiles?` (cache) and `loadProfiles(agentID:)`; `launch(_ request: LaunchRequest)` sends `request.profile`/`profileStrict` for **both** chat and terminal and stores them on the session + `PersistedSession`; `openTerminal(in:agentID:config:)` uses the project's resolved profile (strict); `reattachLive` and restore/restart use each session's stored profile, never Settings; `onSessionError` sets `TerminalSession.failure: String?` / shows the chat error.

- [ ] **Step 1:** Implement; terminal `initialCommand` built with `launchArgs` from `profiles(for:)?.profile(named: resolved ?? default)`.
- [ ] **Step 2:** Build (as Task 7 Step 3) → `BUILD SUCCEEDED`; `swift test` in ClrcCore → PASS. **Commit** `feat(ios): sessions launch and reattach with their own profile`.

### Task 9: App — Projects UI, project launch section, New Task picker, failure banner

**Files:**
- Modify: `Projects/MacProjectsView.swift` (section «Проекты» above «Недавние проекты», row badge), `Projects/ProjectView.swift` (section «Запуск»: picker «Профиль Claude», picker «Режим», «Убрать из проектов»; «нет на Маке» in `Palette.orange`), `NewTask/NewTaskSheet.swift` (picker replaces text field when profiles loaded; prefill from project config / `suggestedConfig`), `Terminal/TerminalScreen.swift` (banner with `failure`), fixtures in `Projects/ProjectsFixtures.swift` + `Shell/PreviewEnvironment.swift` (saved `backend` with `rtd`, missing-profile project, failed terminal state)
- New preview states registered in `Inbox/InboxFixtures.swift` `DesignPreviewRoot`: `projectsaved`, `projectlaunch`, `terminalprofilefailed`.

- [ ] **Step 1:** Implement UI with existing components (`Palette`, `.cardStyle()`, `StatusIcon`).
- [ ] **Step 2:** Build, install on the booted simulator, run each new preview state with `-designPreview <state>`, screenshot, check: saved project shows badge `rtd`; launch section shows the default label rule; failed terminal shows the agent message and no prompt.
- [ ] **Step 3: Commit** `feat(ios): saved projects with launch profile and mode`.

### Task 10: Docs, release and rollout

**Files:** `CLAUDE.md` (Structured output / protocol sections: `profiles_list`, `profile_strict`, harness launch, per-session error), `protocol/README.md`.

- [ ] **Step 1:** Update docs; full checks: relay/agent `gofmt -l`, `go vet`, `go test -race`; ClrcCore + ClrcInstallerCore `swift test` → all pass.
- [ ] **Step 2:** Commit `docs: project launch profiles`; push branch, open PR, CI green, rebase-merge.
- [ ] **Step 3:** `make release VERSION=v2.2.0`; wait for the release run (incl. Homebrew commit); redeploy relay (`railway up …/relay --path-as-root --service clrc-relay --environment production --ci`), check `railway logs` and `/health`.
- [ ] **Step 4:** Update the local agent (`rm` + `cp` the release binary to `~/.local/bin/clrc`, `clrc restart`), confirm `Registered as agent … version 2.2.0`; send a `profiles_list` from a test client or the app and confirm `rtd`/`dats`/`personal` appear.
