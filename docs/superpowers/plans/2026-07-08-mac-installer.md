# clrc Mac Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed macOS menu-bar app that installs and auto-configures everything clrc needs (agent + relay + Tailscale + secrets + iPhone pairing) on any Mac, with hub, satellite, and iCloud-sync roles.

**Architecture:** All non-UI logic lives in a standalone SwiftPM package `ClrcInstallerCore` behind a mockable `CommandRunner` boundary, so state machines are unit-tested with a `FakeRunner` (Swift Testing). A separate SwiftUI Xcode app (`ClrcInstaller`) provides the `MenuBarExtra` and setup wizard, wiring real `ShellRunner`/`KeychainStore` impls into Core. The iOS app gains a small scan-to-pair addition sharing a decoder in `ClrcCore`.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing (`@Test`/`#expect`), SwiftUI `MenuBarExtra`, Security.framework (Keychain), Core Image (`CIQRCodeGenerator`), VisionKit `DataScannerViewController` (iOS), Homebrew cask + GitHub Actions for distribution. Existing Go `clrc` binary is orchestrated, never re-implemented.

## Global Constraints

- **Topology is Tailscale only.** Relay stays on the hub Mac, reached at `100.x.y.z:8080` over the tailnet; relay uses plain `http`/`ws` (no TLS). Do not add Cloudflare/Railway/TLS paths to the app.
- **All shell calls go through `CommandRunner`** (args array only — never `sh -c`, never string interpolation into a shell). Absolute tool paths.
- **Secrets** are generated with `SecRandomCopyBytes`, stored in Keychain, and written to env files/plists with mode `0600`. No secret is ever logged or shown in UI except the deliberate pairing artifacts.
- **Deep-link scheme is `clrc://`** with two verb paths `join` and `pair`; payload is `?v=1&d=<base64url(JSON)>`. Version mismatch, malformed payload, and expiry are hard rejects.
- **Join JSON keys (exact):** `relay`, `secret`, `tskey`, `exp`. **Pair JSON keys (exact):** `relay`, `pw`, `exp`. `exp` is Unix seconds (Int64).
- **`now` is injected** into all expiry-checking functions (`now: Int64`) — never read the clock inside pure logic.
- **Keychain service string:** `xyz.clrc.hub`. **launchd labels:** `xyz.clrc.relay`, `xyz.clrc.agent` (new app namespace; migrates any existing `com.claude.*`).
- **Bundle id:** `xyz.clrc.installer`. **Dev team:** `3ZZ5K4QUDG`. Hardened runtime on.
- gofmt/goimports for any Go; Swift code compiles under Swift 6 language mode; every Core type touched by logic is `Sendable`.
- Package location: `mac-installer/ClrcInstallerCore/` (package), `mac-installer/ClrcInstaller/` (app).

---

## File Structure

**New — `mac-installer/ClrcInstallerCore/` (SwiftPM package, `swift test`)**
- `Package.swift` — package manifest, one library target + test target.
- `Sources/ClrcInstallerCore/CommandRunner.swift` — `CommandResult`, `CommandRunner` protocol.
- `Sources/ClrcInstallerCore/ShellRunner.swift` — `Process`-based real runner.
- `Sources/ClrcInstallerCore/Errors.swift` — typed error enums.
- `Sources/ClrcInstallerCore/JoinToken.swift` — deep-link encode/decode + payload structs.
- `Sources/ClrcInstallerCore/Secrets.swift` — `HubSecrets`, `RandomBytes`, `Secrets.generate`, `SecretStore`.
- `Sources/ClrcInstallerCore/KeychainStore.swift` — real `SecretStore` over Security.framework.
- `Sources/ClrcInstallerCore/Prerequisites.swift` — `ToolStatus`, `Prerequisites`, `PrereqChecker`.
- `Sources/ClrcInstallerCore/TailscaleOps.swift` — `TailscaleOps`.
- `Sources/ClrcInstallerCore/AgentControl.swift` — `AgentControl`.
- `Sources/ClrcInstallerCore/RelayControl.swift` — `FileWriter`, `HealthChecker`, `RelayControl`.
- `Sources/ClrcInstallerCore/HubSetup.swift` — hub orchestration state machine.
- `Sources/ClrcInstallerCore/SatelliteSetup.swift` — satellite orchestration state machine.
- `Sources/ClrcInstallerCore/ICloudSync.swift` — `HubDescriptor`, `KVStore`, `ICloudSync`.
- `Tests/ClrcInstallerCoreTests/FakeRunner.swift` — scripted `CommandRunner` + in-memory fakes.
- `Tests/ClrcInstallerCoreTests/*Tests.swift` — per-component tests.

**New — `mac-installer/ClrcInstaller/` (Xcode app)**
- `ClrcInstaller.xcodeproj`, `ClrcInstallerApp.swift` (`MenuBarExtra`), `StatusModel.swift`, `MenuBarView.swift`, `SetupWizard.swift`, `PairSheet.swift`, `AddMacSheet.swift`, `SettingsView.swift`, `Info.plist`, `ClrcInstaller.entitlements`, bundled `Resources/clrc` (universal binary).

**Modify — iOS**
- `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/PairLink.swift` (new) + test.
- `Claude Orchestrator.iOS/Claude Orchestrator/Views/…` login screen — add Scan-to-pair.

**New — distribution**
- `mac-installer/scripts/build-clrc-universal.sh`, `mac-installer/scripts/package-app.sh`, `Casks/clrc-app.rb`, edits to `.github/workflows/release.yml`.

**Remove** — `scripts/make-app.sh` (superseded) in the final task.

---

# Milestone M1 — Core + hub wrap

### Task 1: Package scaffold + CommandRunner boundary

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Package.swift`
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/CommandRunner.swift`
- Create: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/FakeRunner.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/FakeRunnerTests.swift`

**Interfaces:**
- Produces: `struct CommandResult { let exitCode: Int32; let stdout: String; let stderr: String }`; `protocol CommandRunner { func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult }`; test-only `actor FakeRunner: CommandRunner` with `script(tool:args:result:)` and `calls: [(String,[String])]`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClrcInstallerCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClrcInstallerCore", targets: ["ClrcInstallerCore"])],
    targets: [
        .target(name: "ClrcInstallerCore"),
        .testTarget(name: "ClrcInstallerCoreTests", dependencies: ["ClrcInstallerCore"]),
    ]
)
```

- [ ] **Step 2: Write `CommandRunner.swift`**

```swift
import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
    public var ok: Bool { exitCode == 0 }
}

public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult
}

public extension CommandRunner {
    func run(_ tool: String, _ args: [String]) async throws -> CommandResult {
        try await run(tool, args, stdin: nil)
    }
}
```

- [ ] **Step 3: Write `FakeRunner.swift` (test support)**

```swift
import Foundation
@testable import ClrcInstallerCore

actor FakeRunner: CommandRunner {
    struct Key: Hashable { let tool: String; let args: [String] }
    private var scripted: [Key: CommandResult] = [:]
    private(set) var calls: [(tool: String, args: [String])] = []
    var fallback = CommandResult(exitCode: 0, stdout: "", stderr: "")

    func script(tool: String, args: [String], result: CommandResult) {
        scripted[Key(tool: tool, args: args)] = result
    }
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult {
        calls.append((tool, args))
        return scripted[Key(tool: tool, args: args)] ?? fallback
    }
    func recorded() -> [(tool: String, args: [String])] { calls }
}
```

- [ ] **Step 4: Write failing test `FakeRunnerTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func fakeRunnerReturnsScriptedResultAndRecordsCalls() async throws {
    let r = FakeRunner()
    await r.script(tool: "/bin/echo", args: ["hi"],
                   result: CommandResult(exitCode: 0, stdout: "hi\n", stderr: ""))
    let out = try await r.run("/bin/echo", ["hi"])
    #expect(out.stdout == "hi\n")
    #expect(out.ok)
    let calls = await r.recorded()
    #expect(calls.count == 1)
    #expect(calls[0].tool == "/bin/echo")
}
```

- [ ] **Step 5: Run test — expect FAIL then PASS**

Run: `cd mac-installer/ClrcInstallerCore && swift test`
Expected: first run FAILs if any file is missing/typoed; after Steps 1–3 are correct it PASSES.

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): scaffold ClrcInstallerCore + CommandRunner boundary"
```

---

### Task 2: JoinToken deep-link encode/decode

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/JoinToken.swift`
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Errors.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/JoinTokenTests.swift`

**Interfaces:**
- Produces: `struct JoinPayload { relay, secret, tskey: String; exp: Int64 }`; `struct PairPayload { relay, pw: String; exp: Int64 }`; `enum JoinToken` with `encodeJoin(_:) -> String`, `encodePair(_:) -> String`, `decodeJoin(_:now:) throws -> JoinPayload`, `decodePair(_:now:) throws -> PairPayload`; `enum TokenError: Error, Equatable { case malformed, unsupportedVersion(Int), expired }`.

- [ ] **Step 1: Write `Errors.swift`**

```swift
import Foundation

public enum TokenError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case expired
}
```

- [ ] **Step 2: Write failing tests `JoinTokenTests.swift`**

```swift
import Testing
import Foundation
@testable import ClrcInstallerCore

@Test func joinRoundTrip() throws {
    let p = JoinPayload(relay: "100.1.2.3:8080", secret: "s3cr3t", tskey: "tskey-abc", exp: 2_000_000_000)
    let url = JoinToken.encodeJoin(p)
    #expect(url.hasPrefix("clrc://join?v=1&d="))
    let back = try JoinToken.decodeJoin(url, now: 1_000_000_000)
    #expect(back == p)
}

@Test func pairRoundTrip() throws {
    let p = PairPayload(relay: "http://100.1.2.3:8080", pw: "hunter2", exp: 2_000_000_000)
    let url = JoinToken.encodePair(p)
    #expect(url.hasPrefix("clrc://pair?v=1&d="))
    #expect(try JoinToken.decodePair(url, now: 1_000_000_000) == p)
}

@Test func expiredRejected() throws {
    let url = JoinToken.encodePair(PairPayload(relay: "http://x:8080", pw: "p", exp: 100))
    #expect(throws: TokenError.expired) { try JoinToken.decodePair(url, now: 200) }
}

@Test func malformedRejected() {
    #expect(throws: TokenError.malformed) { try JoinToken.decodeJoin("clrc://join?v=1&d=@@@", now: 0) }
    #expect(throws: TokenError.malformed) { try JoinToken.decodeJoin("https://nope", now: 0) }
}

@Test func versionMismatchRejected() {
    // hand-craft a v=2 link with a valid-looking payload
    let d = Data("{\"relay\":\"x\",\"pw\":\"p\",\"exp\":9999999999}".utf8)
        .base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(throws: TokenError.unsupportedVersion(2)) {
        try JoinToken.decodePair("clrc://pair?v=2&d=\(d)", now: 0)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter JoinTokenTests`
Expected: FAIL (`JoinToken` / payloads not defined).

- [ ] **Step 4: Write `JoinToken.swift`**

```swift
import Foundation

public struct JoinPayload: Codable, Equatable, Sendable {
    public let relay: String; public let secret: String; public let tskey: String; public let exp: Int64
    public init(relay: String, secret: String, tskey: String, exp: Int64) {
        self.relay = relay; self.secret = secret; self.tskey = tskey; self.exp = exp
    }
}

public struct PairPayload: Codable, Equatable, Sendable {
    public let relay: String; public let pw: String; public let exp: Int64
    public init(relay: String, pw: String, exp: Int64) {
        self.relay = relay; self.pw = pw; self.exp = exp
    }
}

public enum JoinToken {
    private static let version = 1

    public static func encodeJoin(_ p: JoinPayload) -> String { encode(verb: "join", p) }
    public static func encodePair(_ p: PairPayload) -> String { encode(verb: "pair", p) }

    public static func decodeJoin(_ url: String, now: Int64) throws -> JoinPayload {
        let p: JoinPayload = try decode(verb: "join", url)
        if p.exp <= now { throw TokenError.expired }
        return p
    }
    public static func decodePair(_ url: String, now: Int64) throws -> PairPayload {
        let p: PairPayload = try decode(verb: "pair", url)
        if p.exp <= now { throw TokenError.expired }
        return p
    }

    private static func encode<T: Encodable>(verb: String, _ payload: T) -> String {
        let json = try! JSONEncoder().encode(payload)
        return "clrc://\(verb)?v=\(version)&d=\(base64url(json))"
    }

    private static func decode<T: Decodable>(verb: String, _ url: String) throws -> T {
        guard let comps = URLComponents(string: url),
              comps.scheme == "clrc", comps.host == verb,
              let items = comps.queryItems,
              let vStr = items.first(where: { $0.name == "v" })?.value,
              let v = Int(vStr),
              let d = items.first(where: { $0.name == "d" })?.value
        else { throw TokenError.malformed }
        guard v == version else { throw TokenError.unsupportedVersion(v) }
        guard let data = base64urlDecode(d) else { throw TokenError.malformed }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TokenError.malformed }
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
```

Note on version-mismatch ordering: `decode` checks `v` before decoding the payload, so a `v=2` link throws `unsupportedVersion(2)` even though its JSON is valid — matching the test.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter JoinTokenTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): clrc:// join/pair deep-link encode/decode with expiry+version guards"
```

---

### Task 3: Secrets generation + SecretStore

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Secrets.swift`
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/KeychainStore.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/SecretsTests.swift`

**Interfaces:**
- Produces: `struct HubSecrets { jwtSecret, adminPassword, agentSecret: String }`; `protocol RandomBytes { func bytes(_ count: Int) -> Data }`; `struct SystemRandom: RandomBytes`; `enum Secrets { static func generate(_ rng: RandomBytes) -> HubSecrets }`; `protocol SecretStore { func get(_ key: String) throws -> String?; func set(_ key: String, _ value: String) throws }`; `struct KeychainStore: SecretStore`; test-only `InMemorySecretStore`.

- [ ] **Step 1: Write failing tests `SecretsTests.swift`**

```swift
import Testing
import Foundation
@testable import ClrcInstallerCore

struct FixedRandom: RandomBytes {
    let value: UInt8
    func bytes(_ count: Int) -> Data { Data(repeating: value, count: count) }
}

@Test func secretsAreHexOfExpectedLength() {
    let s = Secrets.generate(FixedRandom(value: 0xAB))
    // 32 bytes -> 64 hex chars for jwt & agent secret
    #expect(s.jwtSecret.count == 64)
    #expect(s.agentSecret.count == 64)
    #expect(s.jwtSecret.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(!s.adminPassword.isEmpty)
}

@Test func distinctSecretsFromDistinctBytes() {
    // Two different RNG streams must not collide across the three fields.
    let s = Secrets.generate(SystemRandom())
    #expect(s.jwtSecret != s.agentSecret)
    #expect(s.jwtSecret != s.adminPassword)
}

@Test func inMemoryStoreRoundTrip() throws {
    let store = InMemorySecretStore()
    try store.set("AGENT_SECRET", "abc")
    #expect(try store.get("AGENT_SECRET") == "abc")
    #expect(try store.get("MISSING") == nil)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter SecretsTests`
Expected: FAIL (undefined symbols).

- [ ] **Step 3: Write `Secrets.swift`**

```swift
import Foundation
import Security

public protocol RandomBytes: Sendable { func bytes(_ count: Int) -> Data }

public struct SystemRandom: RandomBytes {
    public init() {}
    public func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}

public struct HubSecrets: Sendable, Equatable {
    public let jwtSecret: String
    public let adminPassword: String
    public let agentSecret: String
    public init(jwtSecret: String, adminPassword: String, agentSecret: String) {
        self.jwtSecret = jwtSecret; self.adminPassword = adminPassword; self.agentSecret = agentSecret
    }
}

public enum Secrets {
    public static func generate(_ rng: RandomBytes) -> HubSecrets {
        HubSecrets(
            jwtSecret: hex(rng.bytes(32)),
            adminPassword: passphrase(rng.bytes(24)),
            agentSecret: hex(rng.bytes(32))
        )
    }
    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    // URL/paste-safe readable password: base32-ish over a fixed alphabet.
    private static func passphrase(_ d: Data) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String(d.map { alphabet[Int($0) % alphabet.count] })
    }
}

public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
}
```

- [ ] **Step 4: Write `KeychainStore.swift` (real) + in-memory fake in test file**

```swift
import Foundation
import Security

public struct KeychainStore: SecretStore {
    public let service: String
    public init(service: String = "xyz.clrc.hub") { self.service = service }

    public func get(_ key: String) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
```

Add to `SecretsTests.swift` (top-level, test target):

```swift
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var store: [String: String] = [:]
    func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return store[key] }
    func set(_ key: String, _ value: String) throws { lock.lock(); defer { lock.unlock() }; store[key] = value }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter SecretsTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): CSPRNG secret generation + Keychain-backed SecretStore"
```

---

### Task 4: Prerequisites detection

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Prerequisites.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/PrerequisitesTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`.
- Produces: `enum ToolStatus: Equatable { case installed(version: String?); case missing }`; `struct Prerequisites: Equatable { let homebrew, tailscale, clrc: ToolStatus }`; `enum PrereqChecker { static func check(_ runner: CommandRunner) async -> Prerequisites }`. Probe commands: `brew --version`, `tailscale version`, `clrc status` (exit 0/known text ⇒ installed).

- [ ] **Step 1: Write failing tests `PrerequisitesTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func detectsAllInstalledWithVersions() async {
    let r = FakeRunner()
    await r.script(tool: "/opt/homebrew/bin/brew", args: ["--version"],
                   result: .init(exitCode: 0, stdout: "Homebrew 4.3.0\n", stderr: ""))
    await r.script(tool: "tailscale", args: ["version"],
                   result: .init(exitCode: 0, stdout: "1.70.0\n", stderr: ""))
    await r.script(tool: "/usr/local/bin/clrc", args: ["status"],
                   result: .init(exitCode: 0, stdout: "running\n", stderr: ""))
    let p = await PrereqChecker.check(r)
    #expect(p.homebrew == .installed(version: "Homebrew 4.3.0"))
    #expect(p.tailscale == .installed(version: "1.70.0"))
    #expect(p.clrc == .installed(version: nil))
}

@Test func detectsMissingOnNonZeroExit() async {
    let r = FakeRunner()
    await r.fallback = .init(exitCode: 127, stdout: "", stderr: "not found")
    let p = await PrereqChecker.check(r)
    #expect(p.homebrew == .missing)
    #expect(p.tailscale == .missing)
    #expect(p.clrc == .missing)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter PrerequisitesTests`
Expected: FAIL.

- [ ] **Step 3: Write `Prerequisites.swift`**

```swift
import Foundation

public enum ToolStatus: Equatable, Sendable {
    case installed(version: String?)
    case missing
}

public struct Prerequisites: Equatable, Sendable {
    public let homebrew: ToolStatus
    public let tailscale: ToolStatus
    public let clrc: ToolStatus
    public init(homebrew: ToolStatus, tailscale: ToolStatus, clrc: ToolStatus) {
        self.homebrew = homebrew; self.tailscale = tailscale; self.clrc = clrc
    }
}

public enum PrereqChecker {
    public static let brewPath = "/opt/homebrew/bin/brew"
    public static let tailscalePath = "tailscale"
    public static let clrcPath = "/usr/local/bin/clrc"

    public static func check(_ runner: CommandRunner) async -> Prerequisites {
        Prerequisites(
            homebrew: await probe(runner, brewPath, ["--version"], firstLineVersion: true),
            tailscale: await probe(runner, tailscalePath, ["version"], firstLineVersion: true),
            clrc: await probe(runner, clrcPath, ["status"], firstLineVersion: false)
        )
    }

    private static func probe(_ runner: CommandRunner, _ tool: String, _ args: [String],
                              firstLineVersion: Bool) async -> ToolStatus {
        guard let res = try? await runner.run(tool, args), res.ok else { return .missing }
        guard firstLineVersion else { return .installed(version: nil) }
        let line = res.stdout.split(separator: "\n").first.map(String.init)
        return .installed(version: line?.trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter PrerequisitesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): prerequisite detection (brew/tailscale/clrc) via CommandRunner"
```

---

### Task 5: TailscaleOps

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/TailscaleOps.swift`
- Modify: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Errors.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/TailscaleOpsTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `PrereqChecker.tailscalePath`.
- Produces: `struct TailscaleOps { init(runner: CommandRunner) }` with `func ensureUp(authKey: String?) async throws` and `func tailnetIPv4() async throws -> String`; `enum TailscaleError: Error, Equatable { case authFailed, badIP(String) }`. `ensureUp` runs `tailscale up` (+ `--authkey=<key>` when non-nil); `tailnetIPv4` runs `tailscale ip -4`, validates IPv4.

- [ ] **Step 1: Add error case to `Errors.swift`**

```swift
public enum TailscaleError: Error, Equatable {
    case authFailed
    case badIP(String)
}
```

- [ ] **Step 2: Write failing tests `TailscaleOpsTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func ensureUpPassesAuthKeyFlag() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up", "--authkey=K123"],
                   result: .init(exitCode: 0, stdout: "", stderr: ""))
    try await TailscaleOps(runner: r).ensureUp(authKey: "K123")
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up", "--authkey=K123"] })
}

@Test func ensureUpInteractiveWhenNoKey() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    try await TailscaleOps(runner: r).ensureUp(authKey: nil)
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up"] })
}

@Test func ensureUpThrowsOnFailure() async {
    let r = FakeRunner()
    await r.fallback = .init(exitCode: 1, stderr: "auth error", stdout: "")
    await #expect(throws: TailscaleError.authFailed) {
        try await TailscaleOps(runner: r).ensureUp(authKey: "bad")
    }
}

@Test func tailnetIPv4ParsesAndValidates() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.101.102.103\n", stderr: ""))
    let ip = try await TailscaleOps(runner: r).tailnetIPv4()
    #expect(ip == "100.101.102.103")
}

@Test func tailnetIPv4RejectsGarbage() async {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "not-an-ip\n", stderr: ""))
    await #expect(throws: TailscaleError.badIP("not-an-ip")) {
        try await TailscaleOps(runner: r).tailnetIPv4()
    }
}
```

Note: `stderr:`/`stdout:` argument order in `CommandResult.init` is `(exitCode:stdout:stderr:)`; the two failing-path inits above use labels so order is irrelevant.

- [ ] **Step 3: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter TailscaleOpsTests`
Expected: FAIL.

- [ ] **Step 4: Write `TailscaleOps.swift`**

```swift
import Foundation

public struct TailscaleOps: Sendable {
    private let runner: CommandRunner
    private let tool: String
    public init(runner: CommandRunner, tool: String = PrereqChecker.tailscalePath) {
        self.runner = runner; self.tool = tool
    }

    public func ensureUp(authKey: String?) async throws {
        var args = ["up"]
        if let k = authKey, !k.isEmpty { args.append("--authkey=\(k)") }
        let res = try await runner.run(tool, args)
        guard res.ok else { throw TailscaleError.authFailed }
    }

    public func tailnetIPv4() async throws -> String {
        let res = try await runner.run(tool, ["ip", "-4"])
        let ip = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isIPv4(ip) else { throw TailscaleError.badIP(ip) }
        return ip
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard let n = Int(p), p.allSatisfy(\.isNumber), n >= 0, n <= 255 else { return false }
            return true
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter TailscaleOpsTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): TailscaleOps up/authkey + validated tailnet IPv4"
```

---

### Task 6: AgentControl

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/AgentControl.swift`
- Modify: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Errors.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/AgentControlTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `PrereqChecker.clrcPath`.
- Produces: `struct AgentControl { init(runner: CommandRunner, clrcPath: String = PrereqChecker.clrcPath) }` with `func configure(relayURL: String, secret: String, name: String) async throws`, `func start() async throws`, `func status() async throws -> String`; `enum AgentError: Error, Equatable { case configFailed, startFailed }`.

- [ ] **Step 1: Add error case to `Errors.swift`**

```swift
public enum AgentError: Error, Equatable {
    case configFailed
    case startFailed
}
```

- [ ] **Step 2: Write failing tests `AgentControlTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func configurePassesAllFlags() async throws {
    let r = FakeRunner()
    let a = AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc")
    try await a.configure(relayURL: "ws://100.1.2.3:8080", secret: "S", name: "My Mac")
    let calls = await r.recorded()
    #expect(calls.contains {
        $0.args == ["config", "--relay-url", "ws://100.1.2.3:8080", "--secret", "S", "--name", "My Mac"]
    })
}

@Test func startThrowsOnFailure() async {
    let r = FakeRunner()
    await r.fallback = .init(exitCode: 1, stdout: "", stderr: "boom")
    let a = AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc")
    await #expect(throws: AgentError.startFailed) { try await a.start() }
}
```

- [ ] **Step 3: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter AgentControlTests`
Expected: FAIL.

- [ ] **Step 4: Write `AgentControl.swift`**

```swift
import Foundation

public struct AgentControl: Sendable {
    private let runner: CommandRunner
    private let clrcPath: String
    public init(runner: CommandRunner, clrcPath: String = PrereqChecker.clrcPath) {
        self.runner = runner; self.clrcPath = clrcPath
    }

    public func configure(relayURL: String, secret: String, name: String) async throws {
        let res = try await runner.run(clrcPath,
            ["config", "--relay-url", relayURL, "--secret", secret, "--name", name])
        guard res.ok else { throw AgentError.configFailed }
    }

    public func start() async throws {
        let res = try await runner.run(clrcPath, ["start"])
        guard res.ok else { throw AgentError.startFailed }
    }

    public func status() async throws -> String {
        let res = try await runner.run(clrcPath, ["status"])
        return res.stdout
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter AgentControlTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): AgentControl wraps clrc config/start/status"
```

---

### Task 7: RelayControl (env write, launchd load, health poll)

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/RelayControl.swift`
- Modify: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/Errors.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/RelayControlTests.swift`

**Interfaces:**
- Consumes: `CommandRunner`, `HubSecrets`.
- Produces: `protocol FileWriter { func write(_ path: String, _ contents: String, mode: Int16) throws }`; `protocol HealthChecker { func healthy(_ url: String) async -> Bool }`; `struct RelayControl { init(runner: CommandRunner, files: FileWriter, health: HealthChecker) }` with `func writeEnv(path: String, secrets: HubSecrets, port: Int) throws`, `func load(plistPath: String) async throws`, `func waitHealthy(url: String, attempts: Int) async -> Bool`; `enum RelayError: Error, Equatable { case loadFailed }`; test fakes `SpyFileWriter`, `StubHealth`.

- [ ] **Step 1: Add error case to `Errors.swift`**

```swift
public enum RelayError: Error, Equatable {
    case loadFailed
}
```

- [ ] **Step 2: Write failing tests `RelayControlTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

final class SpyFileWriter: FileWriter, @unchecked Sendable {
    var written: [(path: String, contents: String, mode: Int16)] = []
    func write(_ path: String, _ contents: String, mode: Int16) throws {
        written.append((path, contents, mode))
    }
}
struct StubHealth: HealthChecker {
    let results: [Bool]
    private let box = Box()
    final class Box: @unchecked Sendable { var i = 0 }
    func healthy(_ url: String) async -> Bool {
        defer { box.i += 1 }
        return box.i < results.count ? results[box.i] : false
    }
}

@Test func writeEnvEmitsAllSecretsMode0600() throws {
    let files = SpyFileWriter()
    let rc = RelayControl(runner: FakeRunner(), files: files, health: StubHealth(results: [true]))
    let secrets = HubSecrets(jwtSecret: "J", adminPassword: "P", agentSecret: "A")
    try rc.writeEnv(path: "/tmp/relay.env", secrets: secrets, port: 8080)
    #expect(files.written.count == 1)
    let w = files.written[0]
    #expect(w.mode == 0o600)
    #expect(w.contents.contains("JWT_SECRET=J"))
    #expect(w.contents.contains("ADMIN_PASSWORD=P"))
    #expect(w.contents.contains("AGENT_SECRET=A"))
    #expect(w.contents.contains("PORT=8080"))
}

@Test func loadThrowsWhenLaunchctlFails() async {
    let r = FakeRunner()
    await r.fallback = .init(exitCode: 1, stdout: "", stderr: "no")
    let rc = RelayControl(runner: r, files: SpyFileWriter(), health: StubHealth(results: [true]))
    await #expect(throws: RelayError.loadFailed) { try await rc.load(plistPath: "/tmp/x.plist") }
}

@Test func waitHealthyRetriesUntilTrue() async {
    let rc = RelayControl(runner: FakeRunner(), files: SpyFileWriter(),
                          health: StubHealth(results: [false, false, true]))
    let ok = await rc.waitHealthy(url: "http://127.0.0.1:8080/health", attempts: 5)
    #expect(ok)
}
```

- [ ] **Step 3: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter RelayControlTests`
Expected: FAIL.

- [ ] **Step 4: Write `RelayControl.swift`**

```swift
import Foundation

public protocol FileWriter: Sendable {
    func write(_ path: String, _ contents: String, mode: Int16) throws
}
public protocol HealthChecker: Sendable {
    func healthy(_ url: String) async -> Bool
}

public struct DiskFileWriter: FileWriter {
    public init() {}
    public func write(_ path: String, _ contents: String, mode: Int16) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}

public struct URLHealthChecker: HealthChecker {
    public init() {}
    public func healthy(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u); req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

public struct RelayControl: Sendable {
    private let runner: CommandRunner
    private let files: FileWriter
    private let health: HealthChecker
    public init(runner: CommandRunner, files: FileWriter, health: HealthChecker) {
        self.runner = runner; self.files = files; self.health = health
    }

    public func writeEnv(path: String, secrets: HubSecrets, port: Int) throws {
        let body = """
        JWT_SECRET=\(secrets.jwtSecret)
        ADMIN_PASSWORD=\(secrets.adminPassword)
        AGENT_SECRET=\(secrets.agentSecret)
        PORT=\(port)
        """
        try files.write(path, body + "\n", mode: 0o600)
    }

    public func load(plistPath: String) async throws {
        let res = try await runner.run("/bin/launchctl",
            ["bootstrap", "gui/\(getuid())", plistPath])
        guard res.ok else { throw RelayError.loadFailed }
    }

    public func waitHealthy(url: String, attempts: Int) async -> Bool {
        for _ in 0..<max(1, attempts) {
            if await health.healthy(url) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
```

Note: tests inject `StubHealth`, so the real `Task.sleep` never runs under test (stub returns `true` within `attempts`).

- [ ] **Step 5: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter RelayControlTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): RelayControl env write (0600) + launchd load + health poll"
```

---

### Task 8: HubSetup orchestration state machine

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/HubSetup.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/HubSetupTests.swift`

**Interfaces:**
- Consumes: `TailscaleOps`, `Secrets`, `SecretStore`, `RelayControl`, `AgentControl`.
- Produces: `enum HubStep: Equatable { case tailscale, secrets, relay, agent, done }`; `struct HubSetup` with `init(tailscale:secrets rng:store:relay:agent:relayEnvPath:relayPlistPath:healthURL:)` and `func run(hostname: String, onStep: @Sendable (HubStep) -> Void) async throws -> HubResult`; `struct HubResult { let ip: String; let secrets: HubSecrets }`; `enum HubError: Error, Equatable { case relayUnhealthy }`.

- [ ] **Step 1: Write failing test `HubSetupTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func hubSetupRunsAllStepsInOrderAndStoresSecrets() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.5.6.7\n", stderr: ""))
    let store = InMemorySecretStore()
    let files = SpyFileWriter()
    let hub = HubSetup(
        tailscale: TailscaleOps(runner: r),
        rng: FixedRandom(value: 0x11),
        store: store,
        relay: RelayControl(runner: r, files: files, health: StubHealth(results: [true])),
        agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"),
        relayEnvPath: "/tmp/relay.env",
        relayPlistPath: "/tmp/relay.plist",
        healthURL: "http://127.0.0.1:8080/health"
    )
    var steps: [HubStep] = []
    let result = try await hub.run(hostname: "My Mac") { steps.append($0) }
    #expect(steps == [.tailscale, .secrets, .relay, .agent, .done])
    #expect(result.ip == "100.5.6.7")
    #expect(try store.get("AGENT_SECRET") == result.secrets.agentSecret)
    // agent configured against the tailnet relay
    let calls = await r.recorded()
    #expect(calls.contains { $0.args.contains("--relay-url") && $0.args.contains("ws://100.5.6.7:8080") })
}

@Test func hubSetupThrowsWhenRelayNeverHealthy() async {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up"], result: .init(exitCode: 0, stdout: "", stderr: ""))
    await r.script(tool: "tailscale", args: ["ip", "-4"],
                   result: .init(exitCode: 0, stdout: "100.5.6.7\n", stderr: ""))
    let hub = HubSetup(
        tailscale: TailscaleOps(runner: r), rng: FixedRandom(value: 1),
        store: InMemorySecretStore(),
        relay: RelayControl(runner: r, files: SpyFileWriter(), health: StubHealth(results: [false])),
        agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"),
        relayEnvPath: "/tmp/e", relayPlistPath: "/tmp/p", healthURL: "http://127.0.0.1:8080/health"
    )
    await #expect(throws: HubError.relayUnhealthy) { _ = try await hub.run(hostname: "x") { _ in } }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter HubSetupTests`
Expected: FAIL.

- [ ] **Step 3: Write `HubSetup.swift`**

```swift
import Foundation

public enum HubStep: Equatable, Sendable { case tailscale, secrets, relay, agent, done }
public enum HubError: Error, Equatable { case relayUnhealthy }

public struct HubResult: Sendable, Equatable {
    public let ip: String
    public let secrets: HubSecrets
}

public struct HubSetup: Sendable {
    private let tailscale: TailscaleOps
    private let rng: RandomBytes
    private let store: SecretStore
    private let relay: RelayControl
    private let agent: AgentControl
    private let relayEnvPath: String
    private let relayPlistPath: String
    private let healthURL: String

    public init(tailscale: TailscaleOps, rng: RandomBytes, store: SecretStore,
                relay: RelayControl, agent: AgentControl,
                relayEnvPath: String, relayPlistPath: String, healthURL: String) {
        self.tailscale = tailscale; self.rng = rng; self.store = store
        self.relay = relay; self.agent = agent
        self.relayEnvPath = relayEnvPath; self.relayPlistPath = relayPlistPath
        self.healthURL = healthURL
    }

    public func run(hostname: String, onStep: @Sendable (HubStep) -> Void) async throws -> HubResult {
        onStep(.tailscale)
        try await tailscale.ensureUp(authKey: nil)
        let ip = try await tailscale.tailnetIPv4()

        onStep(.secrets)
        let secrets = Secrets.generate(rng)
        try store.set("JWT_SECRET", secrets.jwtSecret)
        try store.set("ADMIN_PASSWORD", secrets.adminPassword)
        try store.set("AGENT_SECRET", secrets.agentSecret)

        onStep(.relay)
        try relay.writeEnv(path: relayEnvPath, secrets: secrets, port: 8080)
        try await relay.load(plistPath: relayPlistPath)
        guard await relay.waitHealthy(url: healthURL, attempts: 20) else { throw HubError.relayUnhealthy }

        onStep(.agent)
        try await agent.configure(relayURL: "ws://\(ip):8080", secret: secrets.agentSecret, name: hostname)
        try await agent.start()

        onStep(.done)
        return HubResult(ip: ip, secrets: secrets)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter HubSetupTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole suite**

Run: `cd mac-installer/ClrcInstallerCore && swift test`
Expected: PASS (all M1 Core tests).

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): HubSetup orchestration (tailscale→secrets→relay→agent)"
```

---

### Task 9: Menu-bar app scaffold + live status

**Files:**
- Create: `mac-installer/ClrcInstaller/ClrcInstaller.xcodeproj` (Xcode: macOS App, SwiftUI, bundle id `xyz.clrc.installer`, team `3ZZ5K4QUDG`, add local package `../ClrcInstallerCore`)
- Create: `mac-installer/ClrcInstaller/ClrcInstallerApp.swift`
- Create: `mac-installer/ClrcInstaller/ShellRunner.swift`
- Create: `mac-installer/ClrcInstaller/StatusModel.swift`
- Create: `mac-installer/ClrcInstaller/MenuBarView.swift`
- Create: `mac-installer/ClrcInstaller/Info.plist` (register `clrc://` URL scheme, `LSUIElement=true`)

**Interfaces:**
- Consumes: `PrereqChecker`, `AgentControl`, `RelayControl`, `CommandRunner`.
- Produces: `struct ShellRunner: CommandRunner`; `@MainActor final class StatusModel: ObservableObject` with `@Published var prereqs`, `@Published var agentStatus`, `func refresh() async`.

- [ ] **Step 1: Write `ShellRunner.swift`**

```swift
import Foundation
import ClrcInstallerCore

struct ShellRunner: CommandRunner {
    func run(_ tool: String, _ args: [String], stdin: String?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: resolve(tool))
            p.arguments = args
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            if let stdin { let inP = Pipe(); p.standardInput = inP
                inP.fileHandleForWriting.write(Data(stdin.utf8)); inP.fileHandleForWriting.closeFile() }
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: o, stderr: e))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
    // Resolve bare tool names (e.g. "tailscale") to an absolute path when possible.
    private func resolve(_ tool: String) -> String {
        if tool.hasPrefix("/") { return tool }
        for base in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            if FileManager.default.isExecutableFile(atPath: base + tool) { return base + tool }
        }
        return "/usr/bin/env" // last resort; args[0] must then be the tool — avoided by absolute paths above
    }
}
```

- [ ] **Step 2: Write `StatusModel.swift`**

```swift
import Foundation
import ClrcInstallerCore

@MainActor final class StatusModel: ObservableObject {
    @Published var prereqs: Prerequisites?
    @Published var agentStatus: String = "unknown"
    private let runner = ShellRunner()

    func refresh() async {
        prereqs = await PrereqChecker.check(runner)
        agentStatus = (try? await AgentControl(runner: runner).status()) ?? "unreachable"
    }
}
```

- [ ] **Step 3: Write `MenuBarView.swift`**

```swift
import SwiftUI
import ClrcInstallerCore

struct MenuBarView: View {
    @ObservedObject var model: StatusModel
    @Binding var showPair: Bool
    @Binding var showAddMac: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text("clrc").font(.headline)
            Text("Agent: \(model.agentStatus)")
            if let p = model.prereqs {
                Text("Tailscale: \(desc(p.tailscale))")
                Text("clrc: \(desc(p.clrc))")
            }
            Divider()
            Button("Pair iPhone…") { showPair = true }
            Button("Add another Mac…") { showAddMac = true }
            Button("Refresh") { Task { await model.refresh() } }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .task { await model.refresh() }
    }
    private func desc(_ s: ToolStatus) -> String {
        switch s { case .installed(let v): return v ?? "installed"; case .missing: return "missing" }
    }
}
```

- [ ] **Step 4: Write `ClrcInstallerApp.swift`**

```swift
import SwiftUI

@main
struct ClrcInstallerApp: App {
    @StateObject private var model = StatusModel()
    @State private var showPair = false
    @State private var showAddMac = false

    var body: some Scene {
        MenuBarExtra("clrc", systemImage: "terminal") {
            MenuBarView(model: model, showPair: $showPair, showAddMac: $showAddMac)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Build to verify (manual — no unit tests for the app shell)**

Run: `cd mac-installer/ClrcInstaller && xcodebuild -scheme ClrcInstaller -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. Launch: a menu-bar terminal icon appears; clicking shows agent status and prerequisite lines.

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstaller
git commit -m "feat(installer): menu-bar app scaffold + live prereq/agent status"
```

---

### Task 10: Pair-iPhone QR sheet + Add-Mac token sheet

**Files:**
- Create: `mac-installer/ClrcInstaller/QRImage.swift`
- Create: `mac-installer/ClrcInstaller/PairSheet.swift`
- Create: `mac-installer/ClrcInstaller/AddMacSheet.swift`
- Modify: `mac-installer/ClrcInstaller/MenuBarView.swift` (present sheets)

**Interfaces:**
- Consumes: `JoinToken.encodePair/encodeJoin`, `KeychainStore`, `PairPayload`, `JoinPayload`.
- Produces: `func qrImage(from string: String) -> NSImage?`; `struct PairSheet: View`; `struct AddMacSheet: View`. Both read `ADMIN_PASSWORD`/`AGENT_SECRET`/`TAILSCALE_AUTHKEY` + relay IP from Keychain and compute `exp` from `Date`.

- [ ] **Step 1: Write `QRImage.swift`**

```swift
import AppKit
import CoreImage.CIFilterBuiltins

func qrImage(from string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let ci = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: ci)
    let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
}
```

- [ ] **Step 2: Write `PairSheet.swift`**

```swift
import SwiftUI
import ClrcInstallerCore

struct PairSheet: View {
    let relayIP: String
    let adminPassword: String
    @Environment(\.dismiss) private var dismiss

    private var link: String {
        let exp = Int64(Date().timeIntervalSince1970) + 15 * 60
        return JoinToken.encodePair(PairPayload(relay: "http://\(relayIP):8080", pw: adminPassword, exp: exp))
    }
    var body: some View {
        VStack(spacing: 12) {
            Text("Scan on your iPhone").font(.headline)
            if let img = qrImage(from: link) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
            }
            Text("Requires Tailscale on the iPhone, same account.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }
        }.padding(20).frame(width: 300)
    }
}
```

- [ ] **Step 3: Write `AddMacSheet.swift`**

```swift
import SwiftUI
import ClrcInstallerCore

struct AddMacSheet: View {
    let relayIP: String
    let agentSecret: String
    let tailscaleAuthKey: String
    @Environment(\.dismiss) private var dismiss

    private var token: String {
        let exp = Int64(Date().timeIntervalSince1970) + 24 * 3600
        return JoinToken.encodeJoin(JoinPayload(
            relay: "\(relayIP):8080", secret: agentSecret, tskey: tailscaleAuthKey, exp: exp))
    }
    var body: some View {
        VStack(spacing: 12) {
            Text("Add another Mac").font(.headline)
            Text("Open this link on the new Mac (clrc app installed):")
                .font(.caption).foregroundStyle(.secondary)
            TextField("", text: .constant(token), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3).disabled(true)
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }
            if let img = qrImage(from: token) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 180, height: 180)
            }
            Button("Done") { dismiss() }
        }.padding(20).frame(width: 340)
    }
}
```

- [ ] **Step 4: Wire sheets into `MenuBarView.swift`**

Add to the `VStack` in `MenuBarView` (after the existing buttons), reading secrets from Keychain and the relay IP from `TailscaleOps`:

```swift
.sheet(isPresented: $showPair) {
    PairSheet(relayIP: model.relayIP ?? "100.0.0.0",
              adminPassword: (try? KeychainStore().get("ADMIN_PASSWORD")) ?? "")
}
.sheet(isPresented: $showAddMac) {
    AddMacSheet(relayIP: model.relayIP ?? "100.0.0.0",
                agentSecret: (try? KeychainStore().get("AGENT_SECRET")) ?? "",
                tailscaleAuthKey: (try? KeychainStore().get("TAILSCALE_AUTHKEY")) ?? "")
}
```

Add `@Published var relayIP: String?` to `StatusModel` and set it in `refresh()`:

```swift
relayIP = try? await TailscaleOps(runner: runner).tailnetIPv4()
```

- [ ] **Step 5: Build to verify (manual)**

Run: `cd mac-installer/ClrcInstaller && xcodebuild -scheme ClrcInstaller -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. "Pair iPhone…" shows a QR; "Add another Mac…" shows a copyable token + QR.

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstaller
git commit -m "feat(installer): pair-iPhone QR + add-Mac join-token sheets"
```

---

# Milestone M2 — Satellite onboarding + iOS scan-to-pair

### Task 11: SatelliteSetup state machine

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/SatelliteSetup.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/SatelliteSetupTests.swift`

**Interfaces:**
- Consumes: `JoinToken.decodeJoin`, `TailscaleOps`, `AgentControl`.
- Produces: `enum SatelliteStep: Equatable { case tailscale, agent, done }`; `struct SatelliteSetup { init(tailscale:agent:) }` with `func run(token: String, hostname: String, now: Int64, onStep: @Sendable (SatelliteStep) -> Void) async throws`. Rethrows `TokenError` on bad token.

- [ ] **Step 1: Write failing tests `SatelliteSetupTests.swift`**

```swift
import Testing
@testable import ClrcInstallerCore

@Test func satelliteJoinsUsingTokenFields() async throws {
    let r = FakeRunner()
    await r.script(tool: "tailscale", args: ["up", "--authkey=TK"],
                   result: .init(exitCode: 0, stdout: "", stderr: ""))
    let token = JoinToken.encodeJoin(JoinPayload(
        relay: "100.9.9.9:8080", secret: "SEC", tskey: "TK", exp: 5_000_000_000))
    let sat = SatelliteSetup(tailscale: TailscaleOps(runner: r),
                             agent: AgentControl(runner: r, clrcPath: "/usr/local/bin/clrc"))
    var steps: [SatelliteStep] = []
    try await sat.run(token: token, hostname: "Laptop", now: 1_000_000_000) { steps.append($0) }
    #expect(steps == [.tailscale, .agent, .done])
    let calls = await r.recorded()
    #expect(calls.contains { $0.args == ["up", "--authkey=TK"] })
    #expect(calls.contains {
        $0.args == ["config", "--relay-url", "ws://100.9.9.9:8080", "--secret", "SEC", "--name", "Laptop"]
    })
}

@Test func satelliteRejectsExpiredToken() async {
    let token = JoinToken.encodeJoin(JoinPayload(relay: "x:8080", secret: "s", tskey: "k", exp: 100))
    let sat = SatelliteSetup(tailscale: TailscaleOps(runner: FakeRunner()),
                             agent: AgentControl(runner: FakeRunner()))
    await #expect(throws: TokenError.expired) {
        try await sat.run(token: token, hostname: "x", now: 200) { _ in }
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter SatelliteSetupTests`
Expected: FAIL.

- [ ] **Step 3: Write `SatelliteSetup.swift`**

```swift
import Foundation

public enum SatelliteStep: Equatable, Sendable { case tailscale, agent, done }

public struct SatelliteSetup: Sendable {
    private let tailscale: TailscaleOps
    private let agent: AgentControl
    public init(tailscale: TailscaleOps, agent: AgentControl) {
        self.tailscale = tailscale; self.agent = agent
    }

    public func run(token: String, hostname: String, now: Int64,
                    onStep: @Sendable (SatelliteStep) -> Void) async throws {
        let p = try JoinToken.decodeJoin(token, now: now)
        onStep(.tailscale)
        try await tailscale.ensureUp(authKey: p.tskey)
        onStep(.agent)
        try await agent.configure(relayURL: "ws://\(p.relay)", secret: p.secret, name: hostname)
        try await agent.start()
        onStep(.done)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter SatelliteSetupTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add mac-installer/ClrcInstallerCore
git commit -m "feat(installer): SatelliteSetup consumes join token (tailscale authkey + agent)"
```

---

### Task 12: Setup wizard (role picker + satellite flow)

**Files:**
- Create: `mac-installer/ClrcInstaller/SetupWizard.swift`
- Create: `mac-installer/ClrcInstaller/WizardModel.swift`
- Modify: `mac-installer/ClrcInstaller/ClrcInstallerApp.swift` (open wizard on first run / via menu; handle `clrc://join` URLs)

**Interfaces:**
- Consumes: `SatelliteSetup`, `ShellRunner`.
- Produces: `@MainActor final class WizardModel: ObservableObject` with `@Published var phase`, `func runSatellite(token: String)`; `struct SetupWizard: View`.

- [ ] **Step 1: Write `WizardModel.swift`**

```swift
import Foundation
import ClrcInstallerCore

@MainActor final class WizardModel: ObservableObject {
    enum Phase: Equatable { case picker, satellite(step: String), done, failed(String) }
    @Published var phase: Phase = .picker
    private let runner = ShellRunner()

    func runSatellite(token: String) {
        Task {
            do {
                let sat = SatelliteSetup(tailscale: TailscaleOps(runner: runner),
                                         agent: AgentControl(runner: runner))
                let host = Host.current().localizedName ?? "Mac"
                try await sat.run(token: token, hostname: host,
                                  now: Int64(Date().timeIntervalSince1970)) { step in
                    Task { @MainActor in self.phase = .satellite(step: "\(step)") }
                }
                phase = .done
            } catch { phase = .failed("\(error)") }
        }
    }
}
```

- [ ] **Step 2: Write `SetupWizard.swift`**

```swift
import SwiftUI

struct SetupWizard: View {
    @StateObject var model = WizardModel()
    @State private var token = ""

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .picker:
                Text("Set up clrc").font(.title2)
                Text("Add this Mac to an existing setup:")
                TextField("Paste join token (clrc://join…)", text: $token, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3)
                Button("Join") { model.runSatellite(token: token) }
                    .disabled(token.isEmpty)
            case .satellite(let step):
                ProgressView("Setting up… (\(step))")
            case .done:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Try again") { model.phase = .picker }
            }
        }.padding(24).frame(width: 420)
    }
}
```

- [ ] **Step 3: Handle `clrc://` URLs + open wizard in `ClrcInstallerApp.swift`**

```swift
// add inside ClrcInstallerApp:
@Environment(\.openWindow) private var openWindow

// in `body`, add a Window scene:
Window("Set up clrc", id: "setup") { SetupWizard() }

// and on the MenuBarExtra content, add:
.onOpenURL { url in
    if url.scheme == "clrc" { openWindow(id: "setup") /* WizardModel can prefill from url */ }
}
```

- [ ] **Step 4: Build to verify (manual)**

Run: `cd mac-installer/ClrcInstaller && xcodebuild -scheme ClrcInstaller -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. Wizard opens; pasting a token drives the satellite flow to Connected (against a real hub) or a clear failure.

- [ ] **Step 5: Commit**

```bash
git add mac-installer/ClrcInstaller
git commit -m "feat(installer): setup wizard with satellite join flow + clrc:// handling"
```

---

### Task 13: iOS PairLink decoder (shared in ClrcCore)

**Files:**
- Create: `Claude Orchestrator.iOS/ClrcCore/Sources/ClrcCore/PairLink.swift`
- Test: `Claude Orchestrator.iOS/ClrcCore/Tests/ClrcCoreTests/PairLinkTests.swift`

**Interfaces:**
- Produces: `struct PairInfo: Equatable { let relay: String; let password: String }`; `enum PairLink { static func decode(_ url: String, now: Int64) throws -> PairInfo }`; `enum PairLinkError: Error, Equatable { case malformed, unsupportedVersion(Int), expired }`. Must decode links produced by the Mac app's `JoinToken.encodePair` (scheme `clrc`, host `pair`, `v=1`, `d=base64url({relay,pw,exp})`).

- [ ] **Step 1: Write failing tests `PairLinkTests.swift`**

```swift
import Testing
import Foundation
@testable import ClrcCore

@Test func decodesValidPairLink() throws {
    // {"relay":"http://100.1.2.3:8080","pw":"pw","exp":5000000000}
    let json = "{\"relay\":\"http://100.1.2.3:8080\",\"pw\":\"pw\",\"exp\":5000000000}"
    let d = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let info = try PairLink.decode("clrc://pair?v=1&d=\(d)", now: 1)
    #expect(info == PairInfo(relay: "http://100.1.2.3:8080", password: "pw"))
}

@Test func rejectsExpiredAndMalformed() {
    let json = "{\"relay\":\"x\",\"pw\":\"p\",\"exp\":100}"
    let d = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(throws: PairLinkError.expired) { try PairLink.decode("clrc://pair?v=1&d=\(d)", now: 200) }
    #expect(throws: PairLinkError.malformed) { try PairLink.decode("clrc://pair?v=1&d=@@@", now: 0) }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test --filter PairLinkTests`
Expected: FAIL.

- [ ] **Step 3: Write `PairLink.swift`**

```swift
import Foundation

public struct PairInfo: Equatable, Sendable {
    public let relay: String
    public let password: String
    public init(relay: String, password: String) { self.relay = relay; self.password = password }
}

public enum PairLinkError: Error, Equatable { case malformed, unsupportedVersion(Int), expired }

public enum PairLink {
    private struct Payload: Decodable { let relay: String; let pw: String; let exp: Int64 }

    public static func decode(_ url: String, now: Int64) throws -> PairInfo {
        guard let comps = URLComponents(string: url),
              comps.scheme == "clrc", comps.host == "pair",
              let items = comps.queryItems,
              let vStr = items.first(where: { $0.name == "v" })?.value, let v = Int(vStr),
              let d = items.first(where: { $0.name == "d" })?.value
        else { throw PairLinkError.malformed }
        guard v == 1 else { throw PairLinkError.unsupportedVersion(v) }
        guard let data = base64urlDecode(d) else { throw PairLinkError.malformed }
        let p: Payload
        do { p = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw PairLinkError.malformed }
        if p.exp <= now { throw PairLinkError.expired }
        return PairInfo(relay: p.relay, password: p.pw)
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd "Claude Orchestrator.iOS/ClrcCore" && swift test --filter PairLinkTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add "Claude Orchestrator.iOS/ClrcCore"
git commit -m "feat(ios): PairLink decoder for clrc://pair scan-to-pair"
```

---

### Task 14: iOS scan-to-pair UI + login prefill

**Files:**
- Create: `Claude Orchestrator.iOS/Claude Orchestrator/Views/ScanToPairView.swift`
- Modify: the login screen view (the one holding relay-URL + password fields; locate with `grep -rn "RELAY_URL\|relayURL\|password" "Claude Orchestrator.iOS/Claude Orchestrator/Views"`)
- Modify: `Claude Orchestrator.iOS/Claude Orchestrator/Info.plist` (camera usage description)

**Interfaces:**
- Consumes: `PairLink.decode`.
- Produces: `struct ScanToPairView: View` presenting `DataScannerViewController`, calling back `(PairInfo) -> Void`.

- [ ] **Step 1: Add camera usage string to `Info.plist`**

```xml
<key>NSCameraUsageDescription</key>
<string>Scan a clrc pairing QR code to connect to your Mac.</string>
```

- [ ] **Step 2: Write `ScanToPairView.swift`**

```swift
import SwiftUI
import VisionKit
import ClrcCore

struct ScanToPairView: UIViewControllerRepresentable {
    var onScan: (PairInfo) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isndPixelPerfect: false)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (PairInfo) -> Void
        init(onScan: @escaping (PairInfo) -> Void) { self.onScan = onScan }
        func dataScanner(_ s: DataScannerViewController, didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in added {
                if case let .barcode(code) = item, let str = code.payloadStringValue,
                   let info = try? PairLink.decode(str, now: Int64(Date().timeIntervalSince1970)) {
                    s.stopScanning(); onScan(info); return
                }
            }
        }
    }
}
```

Note: correct initializer label is `isPixelPerfect`; if the SDK signature differs, use `DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])])` (other args optional).

- [ ] **Step 3: Add a "Scan to pair" button to the login screen**

In the login view, add a button that presents `ScanToPairView` in a sheet and fills the fields:

```swift
@State private var showScanner = false
// … in body, near the login fields:
Button { showScanner = true } label: { Label("Scan to pair", systemImage: "qrcode.viewfinder") }
.sheet(isPresented: $showScanner) {
    ScanToPairView { info in
        relayURL = info.relay          // bind to the existing relay-URL state
        password = info.password       // bind to the existing password state
        showScanner = false
    }
}
```

- [ ] **Step 4: Build to verify (manual — device build, camera needs a real device)**

Run: open `Claude Orchestrator.iOS/Claude Orchestrator.xcodeproj`, build to a device.
Expected: BUILD SUCCEEDED; "Scan to pair" opens the camera; scanning the Mac app's pair QR fills relay URL + password.

- [ ] **Step 5: Commit**

```bash
git add "Claude Orchestrator.iOS"
git commit -m "feat(ios): scan-to-pair camera flow prefills login from clrc://pair QR"
```

---

# Milestone M3 — Hub-from-zero + distribution + iCloud

### Task 15: Hub-from-zero wizard flow

**Files:**
- Modify: `mac-installer/ClrcInstaller/WizardModel.swift` (add hub path)
- Modify: `mac-installer/ClrcInstaller/SetupWizard.swift` (role picker: Hub vs Satellite; prereq install; authkey paste)
- Create: `mac-installer/ClrcInstaller/PrereqInstaller.swift`

**Interfaces:**
- Consumes: `HubSetup`, `PrereqChecker`, `KeychainStore`, `ShellRunner`.
- Produces: `struct PrereqInstaller { func installTailscale() async throws; func installClrcBinary() throws }`; `WizardModel.runHub(authKey: String)`.

- [ ] **Step 1: Write `PrereqInstaller.swift`**

```swift
import Foundation
import ClrcInstallerCore

struct PrereqInstaller {
    let runner: CommandRunner
    // Copy the bundled universal clrc binary into /usr/local/bin (needs an admin prompt once).
    func installClrcBinary() throws {
        guard let src = Bundle.main.url(forResource: "clrc", withExtension: nil) else {
            throw NSError(domain: "clrc", code: 1, userInfo: [NSLocalizedDescriptionKey: "bundled clrc missing"])
        }
        let dest = "/usr/local/bin/clrc"
        // Use an AppleScript admin prompt to copy with privileges.
        let script = "do shell script \"mkdir -p /usr/local/bin && cp '\(src.path)' \(dest) && chmod 755 \(dest)\" with administrator privileges"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]; try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "clrc", code: 2, userInfo: [NSLocalizedDescriptionKey: "clrc install failed"])
        }
    }
    func installTailscale() async throws {
        _ = try await runner.run(PrereqChecker.brewPath, ["install", "--cask", "tailscale"])
    }
}
```

- [ ] **Step 2: Add hub path to `WizardModel.swift`**

```swift
func runHub(authKey: String) {
    Task {
        do {
            let store = KeychainStore()
            try store.set("TAILSCALE_AUTHKEY", authKey)
            let relay = RelayControl(runner: runner, files: DiskFileWriter(), health: URLHealthChecker())
            let hub = HubSetup(
                tailscale: TailscaleOps(runner: runner), rng: SystemRandom(), store: store,
                relay: relay, agent: AgentControl(runner: runner),
                relayEnvPath: NSHomeDirectory() + "/.config/clrc/relay.env",
                relayPlistPath: NSHomeDirectory() + "/Library/LaunchAgents/xyz.clrc.relay.plist",
                healthURL: "http://127.0.0.1:8080/health")
            let host = Host.current().localizedName ?? "Mac"
            _ = try await hub.run(hostname: host) { step in
                Task { @MainActor in self.phase = .satellite(step: "\(step)") }
            }
            phase = .done
        } catch { phase = .failed("\(error)") }
    }
}
```

Note: writing the launchd plist for `xyz.clrc.relay` is a prerequisite of `relay.load`; add a `writeRelayPlist()` helper in `PrereqInstaller` that emits a plist pointing `ProgramArguments` at the relay binary with `EnvironmentFile` sourced from `relay.env`, mode `0600`. (The relay binary path: bundle it too, or require `make build-relay`; for M3 the hub Mac is the developer's own — bundle `claude-relay` in `Resources` alongside `clrc`.)

- [ ] **Step 3: Extend role picker in `SetupWizard.swift`**

Add a hub branch with a Tailscale reusable-authkey `TextField` and a "Set up hub" button calling `model.runHub(authKey:)`, plus a link to `https://login.tailscale.com/admin/settings/keys`.

- [ ] **Step 4: Build to verify (manual)**

Run: `cd mac-installer/ClrcInstaller && xcodebuild -scheme ClrcInstaller -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED; hub flow runs on a clean Mac end-to-end (manual E2E), producing a healthy relay + connected agent.

- [ ] **Step 5: Commit**

```bash
git add mac-installer/ClrcInstaller
git commit -m "feat(installer): hub-from-zero wizard (prereqs, tailscale authkey, relay+agent)"
```

---

### Task 16: iCloud sync (opt-in)

**Files:**
- Create: `mac-installer/ClrcInstallerCore/Sources/ClrcInstallerCore/ICloudSync.swift`
- Test: `mac-installer/ClrcInstallerCore/Tests/ClrcInstallerCoreTests/ICloudSyncTests.swift`
- Create: `mac-installer/ClrcInstaller/SettingsView.swift`

**Interfaces:**
- Produces: `struct HubDescriptor: Codable, Equatable { let relayIP: String; let agentSecret: String }`; `protocol KVStore { func data(forKey: String) -> Data?; func set(_ data: Data?, forKey: String) }`; `enum ICloudSync { static func save(_ d: HubDescriptor, to store: KVStore) throws; static func load(from store: KVStore) throws -> HubDescriptor? }`; test fake `MemoryKV`.

- [ ] **Step 1: Write failing tests `ICloudSyncTests.swift`**

```swift
import Testing
import Foundation
@testable import ClrcInstallerCore

final class MemoryKV: KVStore, @unchecked Sendable {
    private var d: [String: Data] = [:]
    func data(forKey key: String) -> Data? { d[key] }
    func set(_ data: Data?, forKey key: String) { d[key] = data }
}

@Test func iCloudRoundTripExcludesAuthKey() throws {
    let kv = MemoryKV()
    let desc = HubDescriptor(relayIP: "100.1.2.3", agentSecret: "SEC")
    try ICloudSync.save(desc, to: kv)
    #expect(try ICloudSync.load(from: kv) == desc)
    // stored blob must not contain a tskey field
    let raw = String(data: kv.data(forKey: "hubDescriptor")!, encoding: .utf8)!
    #expect(!raw.contains("tskey"))
}

@Test func iCloudLoadNilWhenEmpty() throws {
    #expect(try ICloudSync.load(from: MemoryKV()) == nil)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter ICloudSyncTests`
Expected: FAIL.

- [ ] **Step 3: Write `ICloudSync.swift`**

```swift
import Foundation

public struct HubDescriptor: Codable, Equatable, Sendable {
    public let relayIP: String
    public let agentSecret: String
    public init(relayIP: String, agentSecret: String) { self.relayIP = relayIP; self.agentSecret = agentSecret }
}

public protocol KVStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public enum ICloudSync {
    static let key = "hubDescriptor"
    public static func save(_ d: HubDescriptor, to store: KVStore) throws {
        store.set(try JSONEncoder().encode(d), forKey: key)
    }
    public static func load(from store: KVStore) throws -> HubDescriptor? {
        guard let data = store.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(HubDescriptor.self, from: data)
    }
}
```

- [ ] **Step 4: Write `SettingsView.swift` (opt-in toggle, off by default)**

```swift
import SwiftUI
import ClrcInstallerCore

struct SettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var syncEnabled = false
    var body: some View {
        Form {
            Toggle("Sync my hub setup via iCloud", isOn: $syncEnabled)
            Text("When on, other Macs signed into the same Apple ID can self-configure. The Tailscale key is never synced.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 380)
    }
}
```

Wire an `UbiquitousKV: KVStore` adapter over `NSUbiquitousKeyValueStore.default` in the app target, and only call `ICloudSync.save` after hub setup when `syncEnabled`.

- [ ] **Step 5: Run to verify pass + build**

Run: `cd mac-installer/ClrcInstallerCore && swift test --filter ICloudSyncTests`
Expected: PASS (2 tests). Then build the app to confirm `SettingsView` compiles.

- [ ] **Step 6: Commit**

```bash
git add mac-installer/ClrcInstallerCore mac-installer/ClrcInstaller
git commit -m "feat(installer): opt-in iCloud hub-descriptor sync (authkey excluded)"
```

---

### Task 17: Universal clrc binary bundling

**Files:**
- Create: `mac-installer/scripts/build-clrc-universal.sh`
- Modify: Xcode build phase (copy `Resources/clrc`, `Resources/claude-relay`)

**Interfaces:** produces `mac-installer/ClrcInstaller/Resources/clrc` (arm64+x86_64) and `.../claude-relay`.

- [ ] **Step 1: Write `build-clrc-universal.sh`**

```sh
#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/mac-installer/ClrcInstaller/Resources"
mkdir -p "$OUT"
build() { # module dir, binary name
  cd "$ROOT/$1"
  GOARCH=arm64 go build -o "/tmp/$2-arm64" ./cmd/...
  GOARCH=amd64 go build -o "/tmp/$2-amd64" ./cmd/...
  lipo -create -output "$OUT/$2" "/tmp/$2-arm64" "/tmp/$2-amd64"
  chmod 755 "$OUT/$2"
}
build agent clrc
build relay claude-relay
echo "Wrote universal binaries to $OUT"
```

- [ ] **Step 2: Run it**

Run: `sh mac-installer/scripts/build-clrc-universal.sh && lipo -info "mac-installer/ClrcInstaller/Resources/clrc"`
Expected: `Architectures in the fat file: … arm64 x86_64`.

- [ ] **Step 3: Add both files to the app target's Copy Bundle Resources phase** (Xcode: drag `Resources/` into the project, ensure target membership).

- [ ] **Step 4: Build to verify (manual)**

Run: `cd mac-installer/ClrcInstaller && xcodebuild -scheme ClrcInstaller -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED; `Bundle.main.url(forResource: "clrc", withExtension: nil)` resolves at runtime.

- [ ] **Step 5: Commit**

```bash
git add mac-installer/scripts/build-clrc-universal.sh mac-installer/ClrcInstaller
git commit -m "build(installer): bundle universal clrc + claude-relay binaries"
```

---

### Task 18: Sign, notarize, and package .dmg

**Files:**
- Create: `mac-installer/scripts/package-app.sh`

**Interfaces:** produces a signed+notarized `ClrcInstaller.dmg`.

- [ ] **Step 1: Write `package-app.sh`**

```sh
#!/bin/sh
set -e
# Requires: Developer ID Application cert in the login keychain (team 3ZZ5K4QUDG),
# and a notarytool keychain profile named "clrc-notary" (xcrun notarytool store-credentials).
APP="$1"          # path to built ClrcInstaller.app
DMG="ClrcInstaller.dmg"
TEAM="3ZZ5K4QUDG"

codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: $TEAM" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$DMG"
hdiutil create -volname "clrc" -srcfolder "$APP" -ov -format UDZO "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "clrc-notary" --wait
xcrun stapler staple "$DMG"
echo "Signed + notarized $DMG"
```

- [ ] **Step 2: Build a Release .app, then run the script (manual — needs signing identity)**

Run:
```bash
cd mac-installer/ClrcInstaller
xcodebuild -scheme ClrcInstaller -configuration Release -derivedDataPath build build
sh ../scripts/package-app.sh build/Build/Products/Release/ClrcInstaller.app
```
Expected: `Signed + notarized ClrcInstaller.dmg`; `spctl -a -vv build/.../ClrcInstaller.app` → `accepted, source=Notarized Developer ID`.

- [ ] **Step 3: Commit**

```bash
git add mac-installer/scripts/package-app.sh
git commit -m "build(installer): sign + notarize + dmg packaging script"
```

---

### Task 19: Homebrew cask + release workflow

**Files:**
- Create: `Casks/clrc-app.rb`
- Modify: `.github/workflows/release.yml`

**Interfaces:** `brew install --cask clrc-app` installs the notarized app.

- [ ] **Step 1: Write `Casks/clrc-app.rb`** (mirror the existing `Casks/clrc.rb` structure)

```ruby
cask "clrc-app" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/claude-orchestrator/claude-orchestrator/releases/download/v#{version}/ClrcInstaller.dmg"
  name "clrc Installer"
  desc "Menu-bar app to install and configure clrc on any Mac"
  homepage "https://github.com/claude-orchestrator/claude-orchestrator"

  app "ClrcInstaller.app"
end
```

- [ ] **Step 2: Add a build+attach step to `release.yml`** on the `macos` runner, after the existing binary build: run `build-clrc-universal.sh`, `xcodebuild … Release`, `package-app.sh`, and upload `ClrcInstaller.dmg` as a release asset. (Signing needs `DEVELOPER_ID` + notary secrets configured in repo settings — document as a manual prerequisite in the step's comment.)

- [ ] **Step 3: Verify workflow YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add Casks/clrc-app.rb .github/workflows/release.yml
git commit -m "build(installer): clrc-app Homebrew cask + release asset"
```

---

### Task 20: Retire scripts/make-app.sh + docs

**Files:**
- Delete: `scripts/make-app.sh`
- Modify: `README.md`, `CLAUDE.md` (mention the installer app + `brew install --cask clrc-app`), `docs/REMOTE-ACCESS.md` (link installer as the recommended Tailscale on-ramp)

- [ ] **Step 1: Remove the superseded script**

```bash
git rm scripts/make-app.sh
```

- [ ] **Step 2: Add an installer section to `README.md`** (one paragraph: download the `.dmg` or `brew install --cask clrc-app`; first launch → wizard → hub or satellite; menu bar for status). Add a line to `CLAUDE.md` under the components list noting `mac-installer/` (Core package + SwiftUI app). Add a note to `docs/REMOTE-ACCESS.md` Option 1 that the installer app automates the Tailscale + relay + agent setup.

- [ ] **Step 3: Verify builds/tests still green**

Run:
```bash
cd mac-installer/ClrcInstallerCore && swift test
cd "../../Claude Orchestrator.iOS/ClrcCore" && swift test
cd ../.. && cd agent && go test -race ./... && cd ../relay && go build ./...
```
Expected: all PASS/OK (Go relay/agent untouched by installer, still build).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(installer): document installer app; remove make-app.sh stopgap"
```

---

## Self-Review

**Spec coverage:**
- §4 build approach (thin orchestrator, CommandRunner) → Tasks 1, 9. ✓
- §5 architecture / Core modules → Tasks 1–8, 11, 16. ✓
- §6.5 JoinToken format → Task 2. ✓
- §6.4 Secrets + Keychain → Task 3. ✓
- §6.2 Prerequisites → Task 4. ✓
- §6.3 TailscaleOps → Task 5. ✓
- §6.7 AgentControl → Task 6. ✓
- §6.6 RelayControl → Task 7. ✓
- §7.1 hub flow → Tasks 8, 15. ✓
- §7.2 satellite flow → Tasks 11, 12. ✓
- §7.3 iPhone pairing (QR emit + scan) → Tasks 10, 13, 14. ✓
- §6.8/§7.4 iCloud → Task 16. ✓
- §6.9 menu-bar + wizard UI → Tasks 9, 10, 12, 15. ✓
- §9 distribution (universal binary, sign/notarize, cask, workflow) → Tasks 17, 18, 19. ✓
- §10 iOS scan-to-pair → Tasks 13, 14. ✓
- §14 assumption #4 (retire make-app.sh) → Task 20. ✓

**Placeholder scan:** No "TBD/TODO"; every code step carries real code; manual-verify steps (UI build, notarization, device camera) are inherent to their task type and paired with explicit commands and expected output.

**Type consistency:** `CommandResult(exitCode:stdout:stderr:)`, `CommandRunner.run(_:_:stdin:)`, `HubSecrets(jwtSecret:adminPassword:agentSecret:)`, `JoinPayload`/`PairPayload` field names (`relay/secret/tskey/exp`, `relay/pw/exp`), `TailscaleOps(runner:)`, `AgentControl(runner:clrcPath:)`, `RelayControl(runner:files:health:)`, `HubSetup(...)` signature, `SatelliteSetup(tailscale:agent:)`, `PairInfo(relay:password:)` are used identically across defining and consuming tasks. ✓

**Open items surfaced to the human (from spec §14):** the launchd namespace decision (`xyz.clrc.*` vs `com.claude.*`) is fixed in Global Constraints as `xyz.clrc.*` with migration; if you prefer continuity, that's a one-line constraint change before execution.
