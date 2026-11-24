# iOS 2.0.0 Redesign — Stage 6c (Push notifications, reply from a notification) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a chat turn ends with a report, the relay sends an APNs push (title, summary, numbered questions); the user can answer from the notification («Вариант N» buttons or «Ответить текстом…») without opening the app; tapping opens the session. Settings → Уведомления chooses which statuses notify.

**Architecture:** Relay: devices register their APNs token over the client WebSocket (`push_register`); the relay watches `chat_event` reports from agents (it sees them even when no client is attached, which is exactly when a push is needed) and sends APNs with a JWT (ES256 .p8 key) over HTTP/2. Replies from a notification go to a new authenticated HTTP endpoint `POST /chat/reply` that forwards `chat_send` straight to the agent (the session route is gone while the app is backgrounded). iOS: entitlement, registration, categories, delegate handling, reply via HTTP with the stored access token (refreshing once on 401).

**Spec:** `docs/design/2.0.0/clrc-redesign-spec.md` §5.12; brief §5.12, §8 (Push, ответ из уведомления); mockup `LockScreen.dc.html` (push mode).

## Global Constraints

- Push is optional: relay env `APNS_KEY_FILE` (.p8), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (bundle id); `APNS_SANDBOX=1` for development builds. Missing any → push disabled with one log line; nothing else changes.
- Device tokens: hex, 64–200 chars, at most 10 devices kept in memory (newest wins); devices re-register on every connect. Tokens never logged in full (first 8 chars).
- `push_register` payload `{device_token, sandbox, notify: ["needs_input","failed","done"]}`; empty `notify` = no pushes for that device.
- Push payload: `aps.alert {title: report title or status label, body: summary + "\n1. …\n2. …"}`, `aps.sound: default`, `aps.category: CLRC_Q0…CLRC_Q3` (number of questions, capped 3), `aps.thread-id: session_id`, custom `{agent_id, session_id, status}`. Body capped at 1 KB.
- `POST /chat/reply` `{agent_id, session_id, text}` with `Authorization: Bearer <access token>`; validates UUIDs and text length (≤ 4 KB); 401/400/404 (agent offline) responses; rate-limited like login (per IP).
- iOS: categories CLRC_Q0…Q3 with actions «Вариант 1…N» (sends "N") and a text-input action «Ответить текстом…»; foreground notifications are not shown as banners (the Inbox already shows the card); tapping a notification opens the chat. Live Activity is out of scope (needs a widget extension target; see Ruling).

## Review Focus

1. **Unauthenticated `/chat/reply`** — rejected without/with a bad token, never forwards. Test: `TestChatReplyRequiresAuth`.
2. **Reply to an offline agent** — 404, nothing queued. Test: `TestChatReplyAgentOffline`.
3. **Push for every report, including fallback reports** — status filter per device honoured. Test: `TestPushFilterByStatus`.
4. **Bad device token / too many devices** — rejected / oldest dropped. Test: `TestPushRegisterValidation`.
5. **APNs key missing or malformed** — relay still starts, push disabled. Test: `TestNewAPNsFromEnvDisabled`.

---

### Task 1: Relay — push registry, APNs sender, report watcher
`relay/push.go` (+ test): `PushRegistry` (register/devices/filter), `APNs` (JWT ES256 cached 50 min, `Send(ctx, device, payload)` via `http.Client` to `https://api.push.apple.com` or sandbox `/3/device/<token>`, headers `apns-topic`, `apns-push-type: alert`, `authorization: bearer <jwt>`), `buildReportPush(agentID, sessionID string, report reportPayload) (payload []byte, status string)`, `NewAPNsFromEnv() (*APNs, error)` (nil, nil when not configured). Hub: client `push_register` → registry; agent `chat_event` with `event.kind == "report"` → for each device whose `notify` contains the status → `go apns.Send` (5 s timeout, log failures; 410 Unregistered removes the token). Sender is an interface so tests capture pushes.
- [ ] Tests: `TestPushRegisterValidation`, `TestPushFilterByStatus`, `TestBuildReportPush` (title/body/category/thread-id/custom keys/body cap), `TestReportEventTriggersPush` (via test relay + fake sender), `TestNewAPNsFromEnvDisabled`, `TestAPNsJWT` (signs with a generated P-256 key, header kid/alg, claims iss/iat). Commit `feat(relay): send APNs pushes for chat reports`.

### Task 2: Relay — `POST /chat/reply`
`relay/chat_reply.go` (+ test): `ChatReplyHandler(hub, auth, limiter)`: method POST only; bearer token validated with `auth` (access token); JSON body validated; agent looked up → `chat_send` `{session_id, text}` sent to the agent connection; 200 `{"ok":true}`. Wire in `cmd/main.go`.
- [ ] Tests: `TestChatReplyRequiresAuth`, `TestChatReplyForwardsToAgent`, `TestChatReplyAgentOffline`, `TestChatReplyValidatesInput`. Commit `feat(relay): reply to a chat from a notification`.

### Task 3: iOS — registration, categories, reply, settings
`Push/PushManager.swift` (UNUserNotificationCenter delegate: categories, authorization request after sign-in, `registerForRemoteNotifications`, token → relay `push_register` on every connect; action handling: «Вариант N» → `ChatReplyClient.send(text: "N")`, text input → its text, default tap → open chat via `openSessionRoute`), `Push/ChatReplyClient.swift` (POST with access token, one refresh on 401), `App/AppDelegate.swift` (UIApplicationDelegateAdaptor for token callbacks), entitlements file `Claude Orchestrator.entitlements` (`aps-environment: development`) referenced in build settings, Settings → Уведомления (`notify_statuses`: toggles «Ждёт ответа», «Ошибка», «Готово»; re-registers). Core: `PushCategories` (ids, action ids ↔ answers) + `PushNotify` (stored statuses) tested in ClrcCore.
- [ ] Core tests; build; commit `feat(ios): push notifications with answers from the lock screen`.
