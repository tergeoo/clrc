//
//  ClrcApp.swift
//  Clrc
//
//  Menu-bar installer app for clrc (Tailscale topology).
//

import SwiftUI

@main
struct ClrcApp: App {
    @StateObject private var status = StatusModel()
    @StateObject private var wizard = WizardModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("clrc", systemImage: "terminal") {
            MenuBarView(model: status) { openWindow(id: "setup") }
                .onOpenURL { url in
                    // A clrc://join link opened on a Mac drives satellite onboarding.
                    if url.scheme == "clrc", url.host == "join" {
                        wizard.prefilledToken = url.absoluteString
                        wizard.phase = .picker
                        openWindow(id: "setup")
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("Set up clrc", id: "setup") {
            SetupWizard(model: wizard)
        }
        .windowResizability(.contentSize)
    }
}
