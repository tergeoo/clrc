//
//  SettingsView.swift
//  Clrc
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("iCloudSyncEnabled") private var syncEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Sync my hub setup via iCloud", isOn: $syncEnabled)
            } footer: {
                Text("""
                When on, other Macs signed into the same Apple ID can self-configure \
                from this hub's relay. The Tailscale auth key is never synced. \
                Requires the iCloud Key-Value Storage capability enabled for this app.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 200)
    }
}
