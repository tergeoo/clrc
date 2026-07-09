//
//  MenuBarView.swift
//  Clrc
//

import SwiftUI
import ClrcInstallerCore

struct MenuBarView: View {
    @ObservedObject var model: StatusModel
    var openSetup: () -> Void

    @State private var showPair = false
    @State private var showAddMac = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("clrc").font(.headline)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
            }

            Group {
                statusRow("Agent", model.agentStatus)
                statusRow("Tailnet", model.relayIP ?? "—")
                if let p = model.prereqs {
                    statusRow("Tailscale", desc(p.tailscale))
                    statusRow("clrc", desc(p.clrc))
                }
            }
            .font(.callout)

            Divider()

            Button("Pair iPhone…") { showPair = true }
                .disabled((model.relayIP ?? "").isEmpty)
            Button("Add another Mac…") { showAddMac = true }
                .disabled((model.relayIP ?? "").isEmpty)
            Button("Setup…") { openSetup() }

            Divider()

            Button(model.agentStatus == "not running" ? "Start agent" : "Restart agent") { model.startAgent() }
            Button("Stop agent") { model.stopAgent() }
            Button("Open logs") { NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/clrc.log")) }
            Button("Refresh") { Task { await model.refresh() } }

            Divider()
            Button("Quit clrc") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
        .frame(width: 260)
        .task { await model.refresh() }
        .sheet(isPresented: $showPair) {
            PairSheet(relayIP: model.relayIP ?? "",
                      adminPassword: model.keychain("ADMIN_PASSWORD"))
        }
        .sheet(isPresented: $showAddMac) {
            AddMacSheet(relayIP: model.relayIP ?? "",
                        agentSecret: model.keychain("AGENT_SECRET"),
                        tailscaleAuthKey: model.keychain("TAILSCALE_AUTHKEY"))
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.tail)
        }
    }

    private func desc(_ s: ToolStatus) -> String {
        switch s {
        case .installed(let v): return v ?? "installed"
        case .missing: return "missing"
        }
    }
}
