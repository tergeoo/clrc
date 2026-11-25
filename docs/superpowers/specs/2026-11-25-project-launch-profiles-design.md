# Project launch profiles — design

Status: approved 2026-11-25 · builder-checked

## Intent

The owner works on several projects with different Claude accounts and setups: e.g. this
repo with the personal profile, the RTD backend repo with the corporate `rtd` profile. On
the Mac that difference is one command, `c rtd`, from `~/harness`. From the iPhone it is a
manual, error-prone choice today, and even a correct choice does not reproduce `c rtd`.

Goal: **a project remembers how it is launched, and launching it from the iPhone behaves
like running `c <profile>` in that folder** — the right account, MCP credentials, flags —
with no per-launch choice and no silent fallback to the wrong account.

Single user, one iPhone, one or more Macs.

## What exists today

- `connect` already carries an optional `profile`; the agent maps it to
  `CLAUDE_CONFIG_DIR=~/.claude-<profile>` for both chat and PTY sessions
  (`agent/ws_client.go` `sessionConfigDir`, `agent/child_env.go`). An invalid or missing
  profile **falls back to the agent default** and reports a non-fatal error.
- iPhone: one global profile text field in Settings, plus a per-task text override in
  New Task → Дополнительно. Projects are only the 8 most recent folders per Mac
  (`SessionsStore.recentsByAgent`); nothing is stored per project.
- Terminal sessions: the agent spawns `DEFAULT_COMMAND` (bash) in a PTY; the iPhone then
  types `cd <path> && claude [flags] [prompt]` (`SessionLaunchMode.terminalCommand`).
- Chat sessions: the agent spawns `claude -p --output-format stream-json …` itself with its
  own flags (permission bypass already on), `cmd.Dir = cwd`.
- `~/harness` (`shell/harness.zsh` `_harness_launch`) — what `c <name>` does:
  1. `CLAUDE_CONFIG_DIR=~/.claude-<name>`
  2. `set -a; source ~/.config/harness/<name>.env` if present (MCP credentials etc.)
  3. `HARNESS_PROFILE=<name>`
  4. `claude <launch_args from profiles/<name>/profile.json> "$@"`
  A profile counts as usable on a machine only if `~/.claude-<name>/.harness-state.json`
  exists (it was `harness sync`-ed). `profile.json` also has `description`.

clrc today does only step 1.

## Goals

1. A saved project = Mac + folder + launch config (profile, default mode). Saved projects
   are listed above recents and are never evicted by the recents cap.
2. Launching a saved project (chat or terminal) applies its config with no extra taps.
3. A harness profile launched by clrc gets the same environment as `c <name>` (steps 1–3),
   and terminal sessions also get its `launch_args` (step 4).
4. The iPhone picks profiles from a list the Mac reports (name + description), not free text.
5. If a project's saved profile is not usable on the Mac, the launch **fails visibly**; it
   never runs under the default account.

## Non-goals

- A free-form launch command per project (approach B) — possible later as an extra field.
- Editing harness profiles from the iPhone; syncing project configs between devices or
  storing them on the Mac (approach C).
- Per-project model, env vars, output style, or header canary (`profile.json` `output`).

## Anti-goals

- A launch that silently uses a different account than the project says.
- Breaking existing flows: projects without a config, agents/relays without the new
  messages, and the existing Settings/New Task profile fields keep working as today.

## Approaches considered

- **A. Agent reproduces harness launch; project configs live on the iPhone — chosen.**
  One mechanism for chat and terminal, profile picked from the Mac's real list, new harness
  profiles appear automatically. Cost: the agent learns the `~/harness` layout (optional —
  without `~/harness` everything behaves as today).
- B. Per-project free-form command (`c rtd`) run in the PTY. Cheapest, but terminal only
  (chat spawns `claude` itself), typed on a phone, errors seen only after launch.
- C. Like A with configs on the Mac (`~/.config/clrc/projects.json`). Shared across clients,
  but iPhone editing needs extra protocol; no gain with one iPhone.

## Design

### Agent

**Harness profiles** (new file, e.g. `agent/harness.go`):

- Root: `$HARNESS_ROOT` if set, else `~/harness`. Missing root → no harness profiles.
- A profile is `profiles/<name>/profile.json` for every `<name>` not starting with `_`,
  that passes `validIdent`, and is synced (`~/.claude-<name>/.harness-state.json` exists).
- Parsed fields: `description` (string), `launch_args` ([]string). Unreadable or invalid
  `profile.json` → profile skipped and logged (not fatal).

**Session environment for profile P** (both PTY and chat):

- `CLAUDE_CONFIG_DIR` as today.
- If P is a harness profile: `HARNESS_PROFILE=P`, plus the variables from
  `~/.config/harness/P.env` when that file exists. Parsing is a dotenv subset that covers
  what `set -a; source` would export for simple files: `KEY=value`, optional `export `
  prefix, single/double-quoted values, blank lines and `#` comments. Lines outside that
  subset are skipped and logged by line number only — values are never logged. Env-file
  variables override inherited ones; `CLAUDE_CONFIG_DIR`, `CLRC_SESSION` and
  `HARNESS_PROFILE` are set last and cannot be overridden by the file.
- Builder's call: whether `.env` is re-read per session (preferred: yes, it is tiny, so
  edits apply without an agent restart).

**`launch_args`:** not applied by the agent. Chat already runs with its own flags and
permission bypass; arbitrary extra flags could break `-p`/stream-json. Terminal sessions
get them from the iPhone (below), which is where the `claude` command line is built.

**Mac default gets the same treatment.** A session without a profile uses the agent's
`CLRC_PROFILE`; if that is a harness profile it also gets `HARNESS_PROFILE` and its `.env`,
so «как на Маке» really equals `c <default>`. *(Builder-check answer, designer's call.)*

**Strict profile:** `connect` gains optional `profile_strict` (bool). When true, the
profile must resolve the way `c` would accept it: a harness profile must be synced
(`.harness-state.json`); a name that exists in `~/harness/profiles` but is not synced is
**rejected** (not treated as a plain dir); a plain `~/.claude-<name>` dir with no harness
entry is accepted. On failure the agent does **not** fall back and does **not** spawn
anything (so no `session_ready`, and the iPhone never types the command). It sends
`{"type":"error","payload":{"session_id":…, "message":"профиль «rtd» не найден на этом
Маке — harness sync rtd"}}`. Without the flag, behaviour is unchanged (fallback +
non-fatal error). The same rule applies to chat (error delivered as today's chat error
event) and PTY sessions.

**New request `profiles_list`** (client → agent, via relay), payload `{request_id}`.
Reply `profiles_list_result`:

```json
{ "request_id": "…",
  "default_profile": "personal",
  "profiles": [ { "name": "rtd", "description": "RTD Lab …: Go backend monorepo",
                  "launch_args": ["--dangerously-skip-permissions"], "harness": true } ] }
```

`default_profile` is the agent's `CLRC_PROFILE` (empty if none). `profiles` lists harness
profiles; plain `~/.claude-<name>` dirs that are not harness profiles are listed too with
`"harness": false`, empty description and no `launch_args` (they still work via the
existing profile mechanism). Sorted by name.

### Relay

- Forward `profiles_list` to the agent and route `profiles_list_result` back via the
  existing `request_id` / `pendingRequests` mechanism (add both to the type lists in
  `relay/hub.go`).
- Route agent → client `error` messages that carry a `session_id` to the client that owns
  that session (today they are only logged). Errors without `session_id` stay as they are.
- Requires a relay redeploy. With an old relay the strict error is dropped: the terminal tab
  stays in «подключение…» and nothing is typed — no wrong-account launch, just a less
  helpful state.

### Protocol contract

Add fixtures `profiles_list_result.json` and extend `connect.json` with `profile_strict`;
cover them in the agent, relay (routing) and ClrcCore contract tests. All new fields are
optional; old peers ignore them.

### iPhone

**Model (ClrcCore):**

```swift
struct ProjectConfig: Codable, Equatable {
    var profile: String?            // nil = Mac default (CLRC_PROFILE)
    var mode: SessionLaunchMode?    // nil = app default from Settings
}
```

Stored in `SessionsStore` as `configsByAgent: [agentID: [path: ProjectConfig]]` in the same
JSON file; decoding an old file without the field yields empty configs. A project with a
config is a **saved project**. Removing the config un-saves it (it may still be in recents).

**Profile resolution for a launch** (ClrcCore, unit-tested), highest wins:
per-task override in New Task → project config → Settings global profile → none (agent
default). Strict (`profile_strict: true`) only when the profile came from a project config.
The picker's «по умолчанию» option names what it resolves to right now — «По умолчанию
(rtd — из настроек)» when Settings has a global profile, else «Как на Маке (personal)» —
so a project never claims one account and runs another. *(Builder-check answer.)*

**Sessions keep their launch profile.** Each chat and terminal session stores the profile
and strict flag it was launched with (`PersistedSession` gains optional `profile`,
`profileStrict`). Reattach, auto-restore after an agent restart (`--resume`) and
«Перезапустить» use the stored values, never the current Settings or project config —
otherwise a resumed chat could come back under another account or lose its transcript.
Old persisted sessions without the field behave as today.

**Terminal sessions now send a profile.** Today `sendConnect` for PTY sends none, so the
Settings global profile silently does not apply to terminals although Settings says it
applies to new sessions. New terminal sessions send the resolved profile like chat does.
This is a deliberate behaviour change (a fix).

**Strict failure on the iPhone:** an `error` with a `session_id` marks that session failed
and shows the message in the session screen (terminal: an inline banner instead of the
prompt; chat: as today's chat error). The session is not removed automatically.

**Terminal command:** when the effective profile is a harness profile with `launch_args`,
`terminalCommand` adds them after `claude` (each shell-quoted). If they already contain
`--dangerously-skip-permissions`, the «Без подтверждений» toggle does not add a duplicate.

**Profiles list:** fetched per Mac with `profiles_list` (10 s timeout) when a project
screen or New Task opens; cached in memory per agent for the app session. On timeout /
old agent / old relay: the profile picker falls back to today's text field.

**UI** (Russian, existing style):

- Mac projects screen: new section «Проекты» (saved) above «Недавние проекты»; each row
  shows the folder name plus a profile badge (`rtd`) and mode icon.
- Project screen: new section «Запуск» with «Профиль Claude» (picker: «Как на Маке
  (personal)» + profiles with their description as subtitle) and «Режим» (Как в
  настройках / Chat / Brief / Terminal). Changing either saves the project. A «Убрать из
  проектов» action clears the config.
- «Новая задача здесь» opens New Task prefilled with the project's profile and mode;
  «Терминал здесь» uses the project's profile (strict) and `launch_args`.
- New Task: choosing a saved project (or opening from one) prefills profile and mode; the
  existing Дополнительно → «Профиль Claude» field becomes the same picker and still
  overrides for this one task.
- A profile that the Mac no longer reports is shown on the project as «rtd — нет на Маке»
  in orange; launching still goes strict and fails with the agent's message.

## Several Macs

The owner must be able to do the same on every Mac (owner requirement, 2026-11-25).

- Everything is per Mac by construction: each agent reports **its own** profiles
  (`profiles_list` goes to one `agent_id`), and project configs are keyed by
  `agent_id` + path. A work Mac can have `rtd` and `dats`, a home Mac only `personal`.
- Saving a project on a second Mac whose folder path matches a saved project on another
  Mac prefills that project's config (profile only if the second Mac reports it). Still a
  separate saved project; nothing is linked or synced. *(Designer's call: removes retyping
  without hidden coupling.)*
- A new Mac gets the agent via `~/harness/scripts/mac-setup.sh clrc`. That script today
  builds from branch `feat/structured-output`, which no longer exists: it must default to
  `main` and embed the version (`-ldflags "-X main.version=$(git describe --tags)"`) so the
  iPhone's «Обнови clrc» check works on every Mac. This change is in the `harness` repo.
- The agent finds harness via `$HARNESS_ROOT` or `~/harness`; launchd agents installed by
  `mac-setup.sh` have `HOME` set, so the default works without extra config.

## Constraints

- Existing security rules hold: profile names pass `validIdent` (`^[a-z0-9-]+$`, ≤64);
  harness paths are resolved only under `$HOME`; env-file values never logged.
- Old agent / relay / app combinations keep working (all fields optional, fallbacks above).
- TDD per repo rules; Go tests with `-race`; ClrcCore logic in the package, not the app.

## Left to the builder

Exact file/type names, how the picker is laid out, caching details, whether profile list
fetching is shared with the New Task sheet, and the wording of secondary UI text.
