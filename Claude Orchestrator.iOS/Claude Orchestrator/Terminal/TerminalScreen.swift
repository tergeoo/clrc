import SwiftUI
import UIKit
import SwiftTerm
import ClrcCore

/// Colors of the always-dark terminal chrome (Terminal.dc.html).
enum TerminalChrome {
    static let bar = Color(hex: 0x26262B)
    static let key = Color(hex: 0x3A3A40)
    static let badge = Color(hex: 0x2C2C32)
    static let text = Color(hex: 0xE6E6EA)
    static let dim = Color(hex: 0x8E8E93)
    static let red = Color(hex: 0xFF6961)
    static let blue = Color(hex: 0x0A84FF)
}

/// A terminal session full screen (spec 5.6): view mode by default, the
/// keyboard only on «⌨︎ Клавиатура», one special-key row while typing.
struct TerminalScreen: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var keyboardVisible = false
    @State private var ctrlOn = false
    @State private var showCommands = false

    private var reconnecting: Bool {
        relay.connectionState != .connected
            || !relay.agents.contains { $0.id == session.agent.id && $0.connected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                ZStack {
                    RemoteTerminalView(session: session)
                        .id(session.id)
                    if reconnecting { ReconnectOverlay() }
                }
                if keyboardVisible {
                    SpecialKeysRow(ctrlOn: ctrlOn, send: sendKey, toggleCtrl: toggleCtrl, hide: hideKeyboard)
                } else {
                    TerminalViewBar(openKeyboard: openKeyboard,
                                    interrupt: { send(TerminalKeys.interrupt) },
                                    historyUp: { send(TerminalKeys.historyUp) },
                                    commands: { showCommands = true })
                }
            }
            // The header (back) stays usable: the Mac may never come back.
            .disabled(reconnecting)
        }
        .task(id: reconnecting) { await checkStillRunning() }
        .background(Palette.code)
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCommands) {
            CommandsSheet { command in
                send(command.bytes)
                showCommands = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            (session.terminalView as? ScrollableTerminalView)?.keyboardAllowed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.controlResetNotification)) { _ in
            ctrlOn = false
        }
    }

    /// SwiftTerm posts this when a typed key consumed the sticky Ctrl.
    private static let controlResetNotification = Notification.Name("SwiftTerm.TerminalView.controlModifierReset")

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TerminalChrome.blue)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            }
            .accessibilityLabel("Назад")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(session.customName) · \(session.agent.name)")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let path = session.projectPath {
                    Text(ChatContent.shortPath(path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TerminalChrome.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(session.fontSize.formatted())pt")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: 0xAEAEB2))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(TerminalChrome.badge, in: Capsule())
                .accessibilityLabel("Размер шрифта \(session.fontSize.formatted())")
        }
        .padding(.trailing, 12)
        .frame(height: 44)
        .foregroundStyle(TerminalChrome.text)
        .overlay(alignment: .bottom) { Rectangle().fill(TerminalChrome.key).frame(height: 0.5) }
    }

    // MARK: - Input

    private func send(_ bytes: [UInt8]) {
        relay.sendInput(sessionID: session.id, data: Data(bytes))
    }

    /// Special keys carry their own bytes, so a pending Ctrl is dropped.
    private func sendKey(_ key: TerminalKey) {
        if ctrlOn { toggleCtrl() }
        send(key.bytes)
    }

    private func toggleCtrl() {
        ctrlOn.toggle()
        session.terminalView?.controlModifier = ctrlOn
    }

    private func openKeyboard() {
        guard let tv = session.terminalView as? ScrollableTerminalView else { return }
        tv.keyboardAllowed = true
        _ = tv.becomeFirstResponder()
    }

    private func hideKeyboard() {
        _ = session.terminalView?.resignFirstResponder()
    }

    /// The agent says nothing when a PTY exits; ask which sessions it still
    /// runs and show «Сессия завершена» if this one is gone (spec 5.6).
    private func checkStillRunning() async {
        guard !reconnecting else { return }
        relay.requestSessionList(agentID: session.agent.id) { running in
            guard let running, !running.contains(where: { $0.id == session.id }) else { return }
            sessionManager.markEnded(session)
        }
    }
}

private struct ReconnectOverlay: View {
    var body: some View {
        ZStack {
            Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.72)
            VStack(spacing: 4) {
                Text("Переподключение…").font(.system(size: 16, weight: .semibold))
                Text("Ввод заблокирован до восстановления связи")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xAEAEB2))
            }
            .foregroundStyle(TerminalChrome.text)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(TerminalChrome.badge, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
