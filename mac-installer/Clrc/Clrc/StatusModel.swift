//
//  StatusModel.swift
//  Clrc
//
//  Live menu-bar status: prerequisites, tailnet IP, agent connectivity.
//

import Foundation
import Combine
import ClrcInstallerCore

@MainActor
final class StatusModel: ObservableObject {
    @Published var prereqs: Prerequisites?
    @Published var relayIP: String?
    @Published var agentStatus: String = "checking…"
    @Published var refreshing = false

    private let runner = ShellRunner()

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        prereqs = await PrereqChecker.check(runner)
        relayIP = try? await TailscaleOps(runner: runner).tailnetIPv4()
        do {
            let out = try await AgentControl(runner: runner).status()
            agentStatus = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "not running" : out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            agentStatus = "unreachable"
        }
    }

    func startAgent() { Task { _ = try? await AgentControl(runner: runner).start(); await refresh() } }
    func stopAgent() { Task { _ = try? await runner.run(PrereqChecker.clrcPath, ["stop"]); await refresh() } }

    func keychain(_ key: String) -> String {
        (try? KeychainStore().get(key)) ?? ""
    }
}
