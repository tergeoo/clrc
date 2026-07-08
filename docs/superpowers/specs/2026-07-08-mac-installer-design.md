# clrc Mac Installer — Design Spec

**Date:** 2026-07-08
**Status:** Draft for review
**Topic:** One-click macOS installer/menu-bar app that installs and auto-configures everything clrc needs (agent + relay + Tailscale network + secrets + iPhone pairing) on any Mac.

---

## 1. Goal

A native macOS **menu-bar app** that lets a non-technical user stand up clrc on any Mac in one guided flow, and thereafter monitor/control it from the menu bar. It covers three roles:

- **Hub setup from zero** — a fresh Mac becomes the home base: installs prerequisites, joins Tailscale, generates secrets, starts relay + agent, emits pairing artifacts.
- **Satellite onboarding** — any additional Mac joins the existing setup by consuming a single join token (no manual secret entry).
- **iPhone pairing** — a QR code carries the relay URL + password so the iOS app logs in by scanning.

Optional convenience layer: **iCloud sync** of the hub config across the same user's Macs, so a second personal Mac can self-configure without a token.

## 2. Topology (fixed)

Tailscale. The relay lives on the hub Mac and is reached over the tailnet (`100.x.y.z:8080`) — never exposed to the public internet. Traffic is end-to-end encrypted by WireGuard, so the relay stays on plain `http`/`ws` (no TLS certs). This matches `docs/REMOTE-ACCESS.md` Option 1 and preserves the relay's existing hardening as defense-in-depth.

## 3. Non-goals (YAGNI)

- No Windows/Linux installer (macOS only; the agent is Mac-only by design).
- No web dashboard — the menu bar is the only GUI surface.
- No multi-tenant / multi-user accounts — single owner, one tailnet.
- No re-implementation of agent/relay logic in Swift; the app orchestrates the existing Go binaries and CLIs.
- No Cloudflare/Railway/native-TLS setup paths in the app (documented in `REMOTE-ACCESS.md` for manual use; the app commits to Tailscale).

## 4. Build approach (chosen)

**Thin native SwiftUI orchestrator over existing tools.** The app shells out to `brew`, `tailscale`, and the existing `clrc` CLI (`config`, `start`, `stop`, `status`, `logs`, `sessions`), plus a small new relay-management surface. The app's own value-add is: prerequisite detection/installation, Tailscale orchestration, secret generation + Keychain storage, join-token/QR encode-decode, iCloud sync, and live status. All shell interaction goes through one mockable `CommandRunner` protocol so the orchestration state machine is unit-testable with a fake runner.

Rejected alternatives: (b) re-implement agent management natively — duplicates logic, more surface; (c) `.pkg` + login-item helper — an installer, not a live status app.

## 5. Architecture

```
┌──────────────────────── clrc-installer.app (SwiftUI) ────────────────────────┐
│  MenuBarExtra (status + actions)      SetupWizard (first-run window)          │
│         │                                    │                                │
│         ▼                                    ▼                                │
│  ClrcInstallerCore  (pure Swift, unit-tested, no UI, no direct Process)       │
│   ├─ Prerequisites  (detect brew / tailscale / clrc / agent binary)          │
│   ├─ TailscaleOps   (up --authkey, ip -4, status)                            │
│   ├─ Secrets        (CSPRNG generate; Keychain read/write)                    │
│   ├─ JoinToken      (encode/decode clrc:// deep links; versioned)             │
│   ├─ RelayControl   (write env, load/unload launchd, health poll)            │
│   ├─ AgentControl   (wrap `clrc config/start/stop/status`)                    │
│   ├─ ICloudSync     (NSUbiquitousKeyValueStore config mirror)                 │
│   └─ CommandRunner  (protocol; ShellRunner impl + FakeRunner for tests)       │
└──────────────────────────────────────────────────────────────────────────────┘
        │ shells out to                     │ writes                │ emits
        ▼                                    ▼                        ▼
   brew / tailscale / clrc          ~/.config/clrc/.env,        QR image + token string
                                    relay .env, launchd plists  (Add Mac / Pair iPhone)
```

`ClrcInstallerCore` is a local SwiftPM package (mirrors the existing `ClrcCore` package used by the iOS app), so the logic is testable with the Swift Testing framework (`@Test`/`#expect`) independent of AppKit.

## 6. Components & responsibilities

### 6.1 `CommandRunner` (boundary)
- `protocol CommandRunner { func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult }` where `CommandResult { exitCode: Int, stdout: String, stderr: String }`.
- `ShellRunner` executes via `Process`, absolute tool paths resolved once (`/opt/homebrew/bin/...`, `/usr/local/bin/clrc`, `/Applications/Tailscale.app/Contents/MacOS/Tailscale` or `tailscale` CLI). Never passes user input through a shell string — args array only, no `sh -c`.
- `FakeRunner` returns scripted results keyed by `(tool, args)` for unit tests.

### 6.2 `Prerequisites`
- Detects presence + version of: Homebrew, Tailscale (app or CLI), the `clrc` agent binary, and whether launchd services are loaded.
- Returns a `[PrerequisiteState]` the wizard renders as a checklist (installed / missing / needs-update). Each has an `install()` action (brew install, or bundled-binary copy for clrc).
- clrc binary source: **bundled inside the .app** (`Contents/Resources/clrc`) and copied to `/usr/local/bin/clrc` — no network needed for the core binary. Tailscale is installed via `brew install --cask tailscale` (needs network) with a fallback link to the Tailscale download page.

### 6.3 `TailscaleOps`
- `ensureUp(authKey: String?) async throws` → runs `tailscale up` (interactive browser auth for the hub; `--authkey=<key>` non-interactive for satellites), then verifies `tailscale status` reports `Running`.
- `tailnetIPv4() async throws -> String` → `tailscale ip -4`, validated against an IPv4 regexp before use.
- Surfaces auth-expired / not-installed / daemon-down as typed errors mapped to user-facing messages.

### 6.4 `Secrets`
- Generates `JWT_SECRET`, `ADMIN_PASSWORD`, `AGENT_SECRET` with `SecRandomCopyBytes` (32 bytes → hex/base64url). `ADMIN_PASSWORD` is a readable-but-strong passphrase-length random string.
- Stores all three in the macOS **Keychain** (login keychain, service `xyz.clrc.hub`). The relay/agent env files are written from the Keychain values with `0600` perms (consistent with the Feb-2026 hardening).
- One migration path: if `relay/.env` or `~/.config/clrc/.env` already hold secrets (existing hub), import them into Keychain instead of regenerating.

### 6.5 `JoinToken` (the config-transfer format)
Two versioned `clrc://` deep links; the app registers the `clrc` URL scheme so opening a link launches straight into the flow. Payload is a base64url-encoded JSON blob after the scheme to keep it copy-pasteable and QR-encodable.

- **Mac join** — `clrc://join?v=1&d=<base64url(json)>` where json =
  `{ "relay": "100.x.y.z:8080", "secret": "<AGENT_SECRET>", "tskey": "<reusable-tailscale-authkey>", "exp": <unix-ts> }`.
- **iPhone pair** — `clrc://pair?v=1&d=<base64url(json)>` where json =
  `{ "relay": "http://100.x.y.z:8080", "pw": "<ADMIN_PASSWORD>", "exp": <unix-ts> }`.
- Encode/decode is pure and unit-tested: round-trip, unknown-version rejection, expiry check, malformed-payload rejection. `exp` defaults to 15 minutes for pair links, configurable (default 24h) for join links.
- Rendered as both a **copy-paste string** and a **QR image** (Core Image `CIQRCodeGenerator`). Mac→Mac uses the string/deep-link primarily (Macs have no easy camera scan); iPhone uses the QR.

### 6.6 `RelayControl`
- Writes the relay env (Keychain-sourced) and manages a launchd agent `xyz.clrc.relay` (plist `0600`, secrets in `EnvironmentVariables`), binding `:8080`. Reachable over the tailnet by the Mac's `100.x.y.z`.
- `healthy() async -> Bool` polls `http://127.0.0.1:8080/health` (the relay already serves `/health`).
- New CLI surface needed on the relay side is **not** required — the app manages the relay's launchd + env directly. (A future `clrc relay ...` subcommand is out of scope here.)

### 6.7 `AgentControl`
- Wraps existing `clrc config --relay-url ws://<hub-ip>:8080 --secret <AGENT_SECRET> --name <hostname>` then `clrc start`, and reads `clrc status` / `clrc sessions` for the menu-bar display.

### 6.8 `ICloudSync` (optional convenience)
- Mirrors the hub descriptor `{ relayIP, agentSecret }` (NOT the Tailscale authkey) into `NSUbiquitousKeyValueStore` under the user's iCloud account. A second Mac signed into the same Apple ID can offer "Use my other Mac's clrc setup" and self-configure the agent, then join Tailscale interactively (its own device auth). Authkeys are never synced — they mint new devices and must stay in Keychain/token only.
- Guarded by an explicit user toggle in Settings; off by default.

### 6.9 UI surfaces
- **`MenuBarExtra`** (steady state): role (Hub/Satellite), status dots (tailnet up, relay healthy [hub], agent↔relay connected), active session count (`clrc sessions`), and actions: Start/Stop agent, Start/Stop relay [hub], Pair iPhone (QR sheet), Add another Mac (token sheet) [hub], Settings, Open Logs, Quit.
- **`SetupWizard`** (first run / re-run from menu): role picker → per-role step flow (below), each step showing the prerequisite checklist and live progress, with retry on any failed step.

## 7. Data flows

### 7.1 Hub setup (fresh Mac, from zero)
1. Wizard: "Set up the hub (first Mac)".
2. Prerequisites: install Homebrew (if missing, guided), install Tailscale cask, copy bundled `clrc` → `/usr/local/bin`.
3. `TailscaleOps.ensureUp(nil)` → browser sign-in (one time) → read `tailnetIPv4()`.
4. `Secrets.generate()` (or import existing) → Keychain.
5. `RelayControl` write env + load launchd → wait `healthy()`.
6. `AgentControl` config (`ws://<hub-ip>:8080`) + start → wait connected.
7. Ask the user (one time) to paste a **reusable Tailscale auth key** from the Tailscale admin console (link + instructions shown); store in Keychain. This is the one unavoidable Tailscale-account step; without it, satellite join falls back to interactive Tailscale auth on each new Mac.
8. Show success + the two artifacts: **Pair iPhone** QR and **Add another Mac** token.

### 7.2 Satellite onboarding (Mac #2..N)
1. Wizard: "Add this Mac to an existing setup" → paste join token (or open the `clrc://join` link).
2. Decode token; validate version + expiry.
3. Install prerequisites (Tailscale cask, bundled `clrc`).
4. `TailscaleOps.ensureUp(token.tskey)` → non-interactive join. If the key is expired/absent, fall back to interactive `tailscale up`.
5. `AgentControl` config (`ws://<token.relay>`) with `token.secret` + hostname → start → wait connected.
6. Menu bar shows Connected. (Satellites run agent only — no relay.)

### 7.3 iPhone pairing
1. Hub menu → **Pair iPhone** → QR sheet renders `clrc://pair` (short expiry).
2. iOS app gains a "Scan to pair" button (camera) that decodes the link and fills relay URL + password on the login screen. Prerequisite banner in both app and sheet: "Install Tailscale on the iPhone, sign in with the same account."

### 7.4 iCloud self-configure (optional)
1. Second personal Mac, same Apple ID, iCloud sync enabled on the hub.
2. Wizard offers "Use my other Mac's clrc setup" → reads descriptor from `NSUbiquitousKeyValueStore` → configures agent → interactive Tailscale sign-in → start.

## 8. Secrets & security

- All secrets generated with `SecRandomCopyBytes`; stored in Keychain; env files/plists `0600`. No secret ever printed to logs or the UI except the deliberate one-time pairing artifacts.
- **Join token is sensitive** (carries `AGENT_SECRET` + Tailscale authkey). Mitigations: short default expiry, shown on demand only, "Regenerate" action that rotates the authkey and invalidates old tokens, treated as a password in the UI (obscured, copy-to-clipboard not screen-persisted). Transferred over a trusted channel (owner's own screen → own device).
- Reuse of the relay's existing hardening is unchanged — nothing here removes UUID validation, read limits, caps, rate limiting, or fs confinement. This is defense-in-depth behind the tailnet.
- iCloud descriptor excludes the authkey; only relay IP + agent secret sync, and only when the user opts in.

## 9. Distribution

- Ship a **Developer ID–signed + notarized** `.app` inside a `.dmg` (team `3ZZ5K4QUDG`), so it runs on any Mac without Gatekeeper friction. Hardened runtime enabled.
- Also add a Homebrew **cask** `clrc-app` pointing at the signed `.dmg` release asset, wired into the existing `.github/workflows/release.yml` on `vX.Y.Z` tags (parallel to the existing `clrc` cask/formula).
- The app bundles the `clrc` binary for the current arch (universal binary preferred: `lipo` arm64+x86_64) in `Contents/Resources`.
- Supersedes `scripts/make-app.sh` (the shell-launcher stopgap); that script is removed once the app ships.

## 10. iOS app changes (minimal)

- Add a "Scan to pair" affordance on the login screen using `AVCaptureSession` / `DataScannerViewController` to read `clrc://pair` links, decode via a shared `PairPayload` decoder (same JSON shape as `JoinToken`'s pair variant), and populate relay URL + password fields. Decoder lives in `ClrcCore` so it is unit-tested and shared. No other iOS behavior changes.

## 11. Error handling

Every step in the wizard is retryable and reports a specific cause:
- Homebrew missing → offer guided install or open install page.
- Tailscale not installed / daemon down / auth expired → precise message + action (install, open Tailscale, re-auth).
- Relay unhealthy after load → show last log lines (`Open Logs`) + retry.
- Agent fails to connect → show `clrc status` + retry.
- Token invalid / expired / wrong version → explain and ask for a fresh one.
- No network / tailnet down → status reflects; actions disabled with reason.
Errors are typed enums in Core mapped to user-facing copy in the UI layer; Core never swallows an error.

## 12. Testing

- **Unit (ClrcInstallerCore, Swift Testing):** JoinToken encode/decode round-trip + expiry + version + malformed; Secrets generation shape; Prerequisites state derivation from `FakeRunner` outputs; each Ops state machine (hub flow, satellite flow) driven by scripted `FakeRunner` results incl. failure branches; ICloudSync serialize/deserialize. Target ≥80% of Core.
- **Unit (ClrcCore, iOS):** `PairPayload` decode from `clrc://pair` links (valid, expired, malformed).
- **Manual E2E checklist (documented in the plan):** fresh Mac → hub flow end-to-end; second Mac → satellite via token; iPhone → scan-to-pair login; iCloud self-configure; regenerate-token invalidation.
- Go modules unchanged, so `go test -race ./...` in `relay/` and `agent/` must still pass (no relay CLI added here).

## 13. Milestones (sequencing, though all in scope)

- **M1 — Core + hub wrap:** `ClrcInstallerCore` (CommandRunner, Prerequisites, Secrets, RelayControl, AgentControl, JoinToken), menu-bar steady state over an already-running hub, Pair-iPhone QR + Add-Mac token generation. Full unit tests.
- **M2 — Satellite onboarding:** wizard "Add this Mac" flow consuming a join token (Tailscale authkey join + agent config/start), plus iOS "Scan to pair".
- **M3 — Hub-from-zero + distribution + iCloud:** full first-run hub wizard (brew, Tailscale up, secrets, relay, agent), signed/notarized `.dmg` + `clrc-app` cask in the release workflow, optional iCloud sync.

Each milestone is independently shippable and testable; the implementation plan will decompose these into per-file tasks.

## 14. Open assumptions (confirm at spec review)

1. **Join token** is the primary Mac config-transfer mechanism; iCloud sync is a secondary opt-in convenience. (Chosen while you were AFK.)
2. **Reusable Tailscale authkey** is pasted once by the user from the Tailscale admin console (no Tailscale OAuth/API integration in v1). If you'd rather do OAuth-minted ephemeral keys, that's a v2 add.
3. App bundle identifier `xyz.clrc.hub` / launchd labels `xyz.clrc.relay`, `xyz.clrc.agent` — confirm naming (current plists in memory use `com.claude.{relay,agent}`; new app can adopt `xyz.clrc.*` or keep `com.claude.*` for continuity).
4. The app **replaces** `scripts/make-app.sh`.
