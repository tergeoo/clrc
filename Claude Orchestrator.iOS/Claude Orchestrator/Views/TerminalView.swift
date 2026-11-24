import SwiftUI
import SwiftTerm
import UIKit
import ClrcCore

// MARK: - ScrollableTerminalView

/// `SwiftTerm.TerminalView` is itself a `UIScrollView`, so a normal finger-drag should scroll
/// the scrollback buffer. But `TerminalView.allowMouseReporting` defaults to `true`, and when a
/// full-screen program running in the PTY (claude, vim, htop, ...) enables terminal mouse
/// tracking, SwiftTerm's `mouseModeChanged(source:)` hook adds a `UIPanGestureRecognizer`
/// directly onto the view. That recognizer competes with the scroll view's own pan gesture, so
/// finger-drag stops scrolling scrollback and starts being interpreted as mouse motion instead —
/// this is the bug: the owner cannot see output that has scrolled off the top.
///
/// Setting `allowMouseReporting = false` alone does not fix this: `panMouseHandler`'s body is
/// gated on `allowMouseReporting && terminal.mouseMode != .off`, so the handler becomes inert,
/// but `mouseModeChanged` still *attaches* the recognizer regardless of that flag — an
/// attached-but-inert `UIPanGestureRecognizer` still competes with the scroll view's for the
/// gesture. The recognizer must never be attached at all.
///
/// SwiftTerm's `enableMousePanGesture()` / `disableMousePanGesture()` (which add/remove that
/// recognizer) have no access modifier, i.e. `internal` to the SwiftTerm module — they cannot be
/// called from here. Their only call sites are the two branches of `mouseModeChanged(source:)`
/// itself, so overriding that `open` hook and not calling `super` is sufficient: the recognizer
/// is simply never created in the first place.
///
/// Trade-off: a phone has no mouse, so full-screen programs that respond to clicks (e.g.
/// clickable panes in some TUIs) lose that responsiveness. But being able to read output that
/// scrolled off the top matters far more on a small screen — that's what was actually reported
/// as broken, so this trade favors scrollback.
///
/// Note: this does not (and cannot) make the *alternate screen buffer* scrollable. While a
/// full-screen program like `claude` is running, the terminal is on the alternate buffer, which
/// by design holds no scrollback in any terminal emulator — there is genuinely nothing above to
/// scroll to. This fix restores scrolling for normal shell output and after such a program exits
/// and the view returns to the primary buffer.
final class ScrollableTerminalView: SwiftTerm.TerminalView {
    /// SwiftTerm focuses itself on any tap or long press. In view mode the
    /// keyboard must stay down (spec 5.6), so focus is refused unless
    /// «⌨︎ Клавиатура» allowed it.
    var keyboardAllowed = false

    override func becomeFirstResponder() -> Bool {
        guard keyboardAllowed else { return false }
        return super.becomeFirstResponder()
    }

    override func mouseModeChanged(source: Terminal) {
        // Deliberately not calling super — see the class doc above for why this alone is enough
        // to keep the mouse-pan gesture recognizer from ever being attached.
    }
}

// MARK: - RemoteTerminalView

/// Wraps SwiftTerm's TerminalView (UIView) in a SwiftUI-compatible view.
/// Named RemoteTerminalView to avoid conflict with SwiftTerm.TerminalView.
struct RemoteTerminalView: UIViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = ScrollableTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        // No mouse on a phone; more importantly this keeps SwiftTerm from ever sending mouse
        // escape sequences, matching the fact that ScrollableTerminalView never attaches the
        // mouse-pan gesture recognizer either. See ScrollableTerminalView's doc comment.
        tv.allowMouseReporting = false

        // Dark theme; the font follows the session's pinch size.
        tv.font = UIFont.monospacedSystemFont(ofSize: session.fontSize, weight: .regular)
        tv.nativeBackgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1) // ~#1C1C21
        tv.nativeForegroundColor = UIColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1) // near-white
        // TerminalScreen draws its own single row of special keys.
        tv.inputAccessoryView = nil

        session.attach(tv)

        relay.registerSessionHandler(sessionID: session.id) { [weak session] _, data in
            DispatchQueue.main.async { session?.receive(data) }
        }

        // No automatic keyboard and no tap-to-focus: the keyboard opens only
        // from «⌨︎ Клавиатура» (spec 5.6). Pinch changes the font size.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched))
        tv.addGestureRecognizer(pinch)

        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(session: session, relay: relay) }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        // Don't unregister here — SessionManager.close(_:) handles it explicitly.
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

        private var pinchBase = TerminalFont.defaultSize

        @MainActor @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let tv = gesture.view as? SwiftTerm.TerminalView else { return }
            switch gesture.state {
            case .began:
                pinchBase = session.fontSize
            case .changed, .ended:
                let size = TerminalFont.pinched(from: pinchBase, scale: gesture.scale)
                guard size != session.fontSize else { return }
                session.fontSize = size
                tv.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                break
            }
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            relay.sendInput(sessionID: session.id, data: Data(data))
            // Log user input into the activity feed (skip control characters / escape sequences)
            if let text = String(bytes: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    Task { @MainActor in
                        self.session.logUserInput(trimmed)
                    }
                }
            }
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
