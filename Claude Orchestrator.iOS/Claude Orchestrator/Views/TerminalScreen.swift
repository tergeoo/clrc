import SwiftUI
import UIKit

/// A terminal session full screen: the SwiftTerm view plus the quick
/// command bar and a keyboard-dismiss button while the keyboard is up.
struct TerminalScreen: View {
    let session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket

    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 0) {
                QuickCommandBar { bytes in
                    relay.sendInput(sessionID: session.id, data: Data(bytes))
                }

                // Keyboard dismiss button — appears only when keyboard is up
                if keyboardVisible {
                    Divider().frame(height: 32)
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, height: 44)
                    }
                }
            }
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }
}
