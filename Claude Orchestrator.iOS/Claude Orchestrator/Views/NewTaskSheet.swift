import SwiftUI
import UIKit

struct NewTaskSheet: View {
    let session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Describe what you want Claude to do…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .padding(.top, 8)

                Divider()
                    .padding(.top, 4)

                Spacer()
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendTask()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
            }
        }
    }

    private func sendTask() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        session.logUserInput(trimmed)
        relay.sendInput(sessionID: session.id, data: Data((trimmed + "\n").utf8))

        dismiss()
    }
}
