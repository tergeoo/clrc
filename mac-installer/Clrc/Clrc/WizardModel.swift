//
//  WizardModel.swift
//  Clrc
//
//  Drives the two onboarding roles: satellite (join by token) and hub (from zero).
//

import Foundation
import Combine
import ClrcInstallerCore

@MainActor
final class WizardModel: ObservableObject {
    enum Phase: Equatable {
        case picker
        case working(role: String, step: String)
        case done(role: String)
        case failed(String)
    }

    @Published var phase: Phase = .picker
    @Published var prefilledToken: String = ""

    private let runner = ShellRunner()
    private var hostname: String { Host.current().localizedName ?? "Mac" }

    // MARK: Satellite

    func runSatellite(token: String) {
        phase = .working(role: "satellite", step: "starting")
        Task {
            do {
                try PrivilegedInstall.installBinaries(includeRelay: false)
                let sat = SatelliteSetup(tailscale: TailscaleOps(runner: runner),
                                         agent: AgentControl(runner: runner))
                try await sat.run(token: token, hostname: hostname,
                                  now: Int64(Date().timeIntervalSince1970)) { step in
                    Task { @MainActor in self.phase = .working(role: "satellite", step: "\(step)") }
                }
                phase = .done(role: "satellite")
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Hub (from zero)

    func runHub(authKey: String) {
        phase = .working(role: "hub", step: "installing")
        Task {
            do {
                let store = KeychainStore()
                if !authKey.isEmpty { try store.set("TAILSCALE_AUTHKEY", authKey) }

                try PrivilegedInstall.installBinaries(includeRelay: true)

                phase = .working(role: "hub", step: "tailscale")
                let ts = TailscaleOps(runner: runner)
                try await ts.ensureUp(authKey: nil)          // interactive browser sign-in
                let ip = try await ts.tailnetIPv4()

                phase = .working(role: "hub", step: "secrets")
                let secrets = Secrets.generate(SystemRandom())
                try store.set("JWT_SECRET", secrets.jwtSecret)
                try store.set("ADMIN_PASSWORD", secrets.adminPassword)
                try store.set("AGENT_SECRET", secrets.agentSecret)

                phase = .working(role: "hub", step: "relay")
                let files = DiskFileWriter()
                try PrivilegedInstall.writeRelayPlist(secrets: secrets, port: 8080, files: files)
                let relay = RelayControl(runner: runner, files: files, health: URLHealthChecker())
                try await relay.load(plistPath: PrivilegedInstall.relayPlistPath)
                guard await relay.waitHealthy(url: "http://127.0.0.1:8080/health", attempts: 20) else {
                    throw WizardError.relayUnhealthy
                }

                phase = .working(role: "hub", step: "agent")
                let agent = AgentControl(runner: runner)
                try await agent.configure(relayURL: "ws://\(ip):8080",
                                          secret: secrets.agentSecret, name: hostname)
                try await agent.start()

                // Optional iCloud sync (off by default; see SettingsView).
                if UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") {
                    try? ICloudSync.save(HubDescriptor(relayIP: ip, agentSecret: secrets.agentSecret),
                                         to: UbiquitousKV())
                }

                phase = .done(role: "hub")
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    enum WizardError: LocalizedError {
        case relayUnhealthy
        var errorDescription: String? {
            switch self {
            case .relayUnhealthy: return "The relay did not become healthy. Check /tmp/claude-relay.log."
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let le = error as? LocalizedError, let d = le.errorDescription { return d }
        switch error {
        case TokenError.expired: return "This join token has expired. Ask the hub for a fresh one."
        case TokenError.malformed: return "That doesn't look like a valid clrc join token."
        case TokenError.unsupportedVersion(let v): return "This token uses an unsupported version (\(v)). Update the app."
        case TailscaleError.authFailed: return "Tailscale sign-in failed. Try again."
        case TailscaleError.badIP(let s): return "Could not read a Tailscale IP (got '\(s)'). Is Tailscale connected?"
        default: return "\(error)"
        }
    }
}
