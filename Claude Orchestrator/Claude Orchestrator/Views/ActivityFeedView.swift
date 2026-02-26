import SwiftUI

// MARK: - ActivityFeedView

struct ActivityFeedView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var relay: RelayWebSocket

    @State private var showNewTask = false

    private var hasContent: Bool {
        session.activityLog.contains { $0.isContentEvent }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Tap on empty space dismisses keyboard
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }

            if hasContent {
                feedList
            } else {
                emptyState
            }

            // Floating "New Task" button
            Button {
                showNewTask = true
            } label: {
                Label("New Task", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskSheet(session: session)
                .environmentObject(relay)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Open a terminal and start Claude\nto see activity here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Feed list

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.activityLog) { event in
                        ActivityEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Extra bottom padding so the FAB doesn't cover the last item
                .padding(.bottom, 72)
            }
            .onChange(of: session.activityLog.count) { _, _ in
                if let last = session.activityLog.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - ActivityEventRow

struct ActivityEventRow: View {
    let event: ActivityEvent

    var body: some View {
        switch event.kind {
        case .sessionStarted:
            sessionDivider(label: "Session started · \(event.timestamp.formatted(.dateTime.hour().minute()))")
        case .sessionEnded:
            sessionDivider(label: "Session ended")
        case .userInput(let text):
            userInputRow(text: text)
        case .claudeText(let text):
            claudeTextRow(text: text)
        case .toolCall(let name, let args):
            toolCallRow(name: name, args: args)
        }
    }

    // MARK: Session divider

    private func sessionDivider(label: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
        }
        .padding(.vertical, 8)
    }

    // MARK: User input (iMessage-style blue bubble)

    private func userInputRow(text: String) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(event.timestamp.formatted(.dateTime.hour().minute()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
        }
        .padding(.vertical, 2)
    }

    // MARK: Claude text (gray bubble)

    private func claudeTextRow(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemBackground))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 48)
        }
        .padding(.vertical, 2)
    }

    // MARK: Tool call (compact chip)

    private func toolCallRow(name: String, args: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon(for: name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            if !args.isEmpty {
                Text(args.count > 60 ? String(args.prefix(60)) + "…" : args)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(event.timestamp.formatted(.dateTime.hour().minute()))
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 1)
    }

    private func toolIcon(for name: String) -> String {
        switch name {
        case "Bash":        return "terminal.fill"
        case "Read":        return "doc.text"
        case "Write":       return "square.and.pencil"
        case "Edit":        return "pencil.circle"
        case "Glob":        return "magnifyingglass"
        case "Grep":        return "doc.text.magnifyingglass"
        case "WebFetch":    return "globe"
        case "WebSearch":   return "globe.americas.fill"
        case "Task":        return "cpu"
        case "NotebookEdit": return "book.closed"
        default:            return "wrench.and.screwdriver"
        }
    }
}
