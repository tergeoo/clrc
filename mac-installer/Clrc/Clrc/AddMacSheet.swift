//
//  AddMacSheet.swift
//  Clrc
//

import SwiftUI
import ClrcInstallerCore

struct AddMacSheet: View {
    let relayIP: String
    let agentSecret: String
    let tailscaleAuthKey: String
    @Environment(\.dismiss) private var dismiss

    private var token: String {
        let exp = Int64(Date().timeIntervalSince1970) + 24 * 3600
        return JoinToken.encodeJoin(JoinPayload(relay: "\(relayIP):8080",
                                                secret: agentSecret,
                                                tskey: tailscaleAuthKey,
                                                exp: exp))
    }

    private var missingKey: Bool { tailscaleAuthKey.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            Text("Add another Mac").font(.headline)
            if missingKey {
                Text("No Tailscale auth key saved. Set one up first so new Macs can join automatically.")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Text("On the new Mac (with the clrc app installed), open this link:")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("", text: .constant(token), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4).disabled(true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
            } label: { Label("Copy link", systemImage: "doc.on.doc") }
            if let img = qrImage(from: token) {
                Image(nsImage: img).interpolation(.none).resizable()
                    .frame(width: 170, height: 170)
            }
            Text("Valid for 24 hours").font(.caption2).foregroundStyle(.tertiary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 360)
    }
}
