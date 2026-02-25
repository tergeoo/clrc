import SwiftUI
import SwiftTerm
import UIKit

// MARK: - RemoteTerminalView

/// Wraps SwiftTerm's TerminalView (UIView) in a SwiftUI-compatible view.
/// Named RemoteTerminalView to avoid conflict with SwiftTerm.TerminalView.
struct RemoteTerminalView: UIViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator

        // Readable theme for mobile
        tv.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        tv.nativeBackgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1) // ~#1C1C21
        tv.nativeForegroundColor = UIColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1) // near-white

        session.terminalView = tv

        relay.registerSessionHandler(sessionID: session.id) { [weak session] _, data in
            DispatchQueue.main.async { session?.receive(data) }
        }

        // Become first responder so the keyboard appears immediately
        DispatchQueue.main.async { tv.becomeFirstResponder() }

        // Re-focus on tap (in case focus is lost)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focusTerminal))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)

        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(session: session, relay: relay) }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        // Don't unregister here — closeSession() in SessionTabsView handles it explicitly.
        // Unregistering here breaks the case where SwiftUI recreates the view for the same session.
    }

    // MARK: - Coordinator

    final class Coordinator: TerminalViewDelegate {
        let session: TerminalSession
        let relay: RelayWebSocket

        init(session: TerminalSession, relay: RelayWebSocket) {
            self.session = session
            self.relay = relay
        }

        @objc func focusTerminal(_ gesture: UITapGestureRecognizer) {
            gesture.view?.becomeFirstResponder()
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            relay.sendInput(sessionID: session.id, data: Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session.lastCols = newCols
            session.lastRows = newRows
            relay.sendResize(sessionID: session.id, cols: newCols, rows: newRows)
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            DispatchQueue.main.async {
                self.session.title = title.isEmpty ? self.session.agent.name : title
            }
        }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}

// MARK: - QuickCommandBar

struct QuickCommand: Identifiable {
    let id = UUID()
    let label: String
    let bytes: [UInt8]       // raw bytes to send (supports escape sequences)
    let newline: Bool        // append \n after bytes

    /// Shortcut that sends a plain text command followed by newline
    static func cmd(_ label: String, _ text: String) -> QuickCommand {
        QuickCommand(label: label, bytes: Array(text.utf8), newline: true)
    }
    /// Shortcut that sends raw escape bytes (no newline)
    static func esc(_ label: String, _ sequence: [UInt8]) -> QuickCommand {
        QuickCommand(label: label, bytes: sequence, newline: false)
    }
}

private let quickCommands: [QuickCommand] = [
    // Navigation keys
    .esc("↑",         [0x1B, 0x5B, 0x41]),  // cursor up / prev history
    .esc("↓",         [0x1B, 0x5B, 0x42]),  // cursor down / next history
    .esc("Tab",       [0x09]),               // autocomplete
    .esc("Ctrl+C",    [0x03]),               // interrupt
    .esc("Ctrl+D",    [0x04]),               // EOF / exit
    // Claude launchers
    .cmd("✦ claude",  "claude"),
    .cmd("⚠ claude",  "claude --dangerously-skip-permissions"),
    // Common shell
    .cmd("ls",        "ls -la"),
    .cmd("pwd",       "pwd"),
    .cmd("cd ~",      "cd ~"),
    .cmd("clear",     "clear"),
    .cmd("git log",   "git log --oneline -15"),
    .cmd("git st",    "git status"),
    .cmd("git diff",  "git diff"),
    .cmd("ps",        "ps aux | head -20"),
    .cmd("df",        "df -h"),
]

struct QuickCommandBar: View {
    let onSend: ([UInt8]) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands) { cmd in
                    Button {
                        var bytes = cmd.bytes
                        if cmd.newline { bytes.append(0x0A) }
                        onSend(bytes)
                    } label: {
                        Text(cmd.label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.secondarySystemBackground))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
