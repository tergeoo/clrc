//
//  SetupWizard.swift
//  Clrc
//

import SwiftUI

struct SetupWizard: View {
    @ObservedObject var model: WizardModel
    @State private var role: Role? = nil
    @State private var token = ""
    @State private var authKey = ""

    enum Role { case hub, satellite }

    var body: some View {
        VStack(spacing: 18) {
            switch model.phase {
            case .picker:
                picker
            case .working(let role, let step):
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Setting up \(role)…").font(.headline)
                    Text(step).font(.caption).foregroundStyle(.secondary)
                }
            case .done(let role):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle).foregroundStyle(.green)
                    Text(role == "hub" ? "Hub is ready" : "Connected").font(.headline)
                    Text(role == "hub"
                         ? "Pair your iPhone and add other Macs from the menu bar."
                         : "This Mac is now reachable from your iPhone.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .failed(let msg):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.largeTitle).foregroundStyle(.red)
                    Text(msg).font(.callout).multilineTextAlignment(.center)
                    Button("Try again") { model.phase = .picker; role = nil }
                }
            }
        }
        .padding(28)
        .frame(width: 440)
        .onAppear { if !model.prefilledToken.isEmpty { token = model.prefilledToken; role = .satellite } }
    }

    @ViewBuilder private var picker: some View {
        Text("Set up clrc").font(.title2).bold()
        Picker("", selection: $role) {
            Text("Add this Mac").tag(Role?.some(.satellite))
            Text("Set up the hub").tag(Role?.some(.hub))
        }
        .pickerStyle(.segmented).labelsHidden()

        switch role {
        case .some(.satellite):
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the join token from your hub Mac:").font(.callout)
                TextField("clrc://join…", text: $token, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                Button("Join") { model.runSatellite(token: token) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty)
            }
        case .some(.hub):
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional: paste a reusable Tailscale auth key so other Macs can join in one click.")
                    .font(.callout)
                Link("Create one in the Tailscale admin console",
                     destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!)
                    .font(.caption)
                TextField("tskey-… (optional)", text: $authKey)
                    .textFieldStyle(.roundedBorder)
                Text("You'll sign into Tailscale in the browser during setup.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Set up hub") { model.runHub(authKey: authKey) }
                    .keyboardShortcut(.defaultAction)
            }
        case nil:
            Text("Choose whether this is your first Mac (the hub) or an additional one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
