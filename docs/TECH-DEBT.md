# Tech Debt

## Mac installer — code signing & distribution (deferred by owner, 2026-07-09)

**Status:** `Clrc.app` builds and runs locally (signed with the owner's *Apple
Development* cert). It is **not yet distributable to other Macs** — Gatekeeper
will block it on any machine not registered to this Apple account.

Owner decision: run on **own devices only** for now (personal use over
Tailscale). The Apple Development build is sufficient for that; nothing else is
required to use it locally.

To make it installable on other Macs (`brew install --cask clrc-app` or a
double-clickable `.dmg`), do — in order:

1. **Developer ID Application certificate** — Xcode → Settings → Accounts →
   Manage Certificates → **+ Developer ID Application** (team `3ZZ5K4QUDG`).
   This is a distinct cert from *Apple Development*; only it satisfies Gatekeeper
   off-device.
2. **Notarize** — `xcrun notarytool store-credentials clrc-notary --apple-id
   <email> --team-id 3ZZ5K4QUDG --password <app-specific-pw>`, then run
   `mac-installer/scripts/package-app.sh <Clrc.app>` (codesign → dmg →
   notarytool submit → staple).
3. **(Optional) CI automation** — add repo secrets `MACOS_CERT_P12` (base64 of
   the `.p12`), `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_APPLE_ID`,
   `NOTARY_TEAM_ID=3ZZ5K4QUDG`, `NOTARY_PASSWORD`. Then
   `.github/workflows/release-app.yml` self-activates on a `vX.Y.Z` tag and
   attaches a signed+notarized `Clrc.dmg`. Skip this if signing locally.

The cask (`Casks/clrc-app.rb`), the packaging script, and the gated workflow are
already written and waiting on the cert.

## iCloud sync capability not enabled

`SettingsView` (toggle) + `UbiquitousKV`/`ICloudSync` code ship and compile, but
real cross-Mac sync needs the **iCloud → Key-Value Storage** capability enabled
in Xcode (Signing & Capabilities) under the paid account. Until then the toggle
persists but nothing propagates.

## Minor follow-ups from code review (non-blocking)

- `RelayControl.waitHealthy` polls with a real 20×500 ms sleep loop → the
  relay-unhealthy unit test runs ~10.5 s. Inject a `Sleeper` abstraction to make
  it instant under test.
- The base64url + JSON deep-link codec is duplicated between the Mac
  (`JoinToken.swift`) and iOS (`PairLink.swift`) with no shared package. Any
  `v=2`/key change must be mirrored by hand; add a committed golden
  encode-on-Mac → decode-on-iOS vector, or share a target.
- iOS `PairLink` has no `.unsupportedVersion` test case.
- `SecretsTests.distinctSecretsFromDistinctBytes` omits the
  `agentSecret != adminPassword` pair.

## Physical-device verification pending

- iOS scan-to-pair camera flow needs a real iPhone (the simulator has no
  camera; it shows the "camera unavailable" fallback).
- Full end-to-end path: hub → **Pair iPhone** QR → iPhone **Scan pairing QR** →
  live session.
