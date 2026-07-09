//
//  PairSheet.swift
//  Clrc
//

import SwiftUI
import ClrcInstallerCore

struct PairSheet: View {
    let relayIP: String
    let adminPassword: String
    @Environment(\.dismiss) private var dismiss

    private var link: String {
        let exp = Int64(Date().timeIntervalSince1970) + 15 * 60
        return JoinToken.encodePair(PairPayload(relay: "http://\(relayIP):8080",
                                                pw: adminPassword, exp: exp))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Pair your iPhone").font(.headline)
            if let img = qrImage(from: link) {
                Image(nsImage: img).interpolation(.none).resizable()
                    .frame(width: 220, height: 220)
            }
            Text("Open the clrc iPhone app and scan this code.\nTailscale must be on the phone, same account.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Valid for 15 minutes").font(.caption2).foregroundStyle(.tertiary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 300)
    }
}
