import Foundation
import Combine
import SwiftTerm

/// Represents one active PTY session connected to a Mac agent.
@MainActor
final class TerminalSession: ObservableObject, Identifiable, Equatable {
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool { lhs.id == rhs.id }
    let id: String
    let agent: Agent

    @Published var title: String
    @Published var customName: String
    @Published var isReady: Bool = false
    @Published var activityLog: [ActivityEvent] = []
    @Published var claudeState: ClaudeState = .idle

    enum ClaudeState {
        case idle
        case working(toolsUsed: Int)
    }

    // The SwiftTerm terminal view — set after the view is created
    weak var terminalView: SwiftTerm.TerminalView?

    // Last known terminal size — used to restore after reconnect
    var lastCols: Int = 80
    var lastRows: Int = 24

    /// Command sent automatically once the PTY session is ready.
    let initialCommand: String?

    // Output parsing state
    private var outputBuffer = ""
    private var toolsUsed = 0
    private var idleTimer: Task<Void, Never>?

    private static let toolPattern = try! NSRegularExpression(
        pattern: #"(Bash|Read|Write|Edit|Glob|Grep|WebFetch|WebSearch|Task|NotebookEdit)\s*\("#
    )
    private static let ansiPattern = try! NSRegularExpression(
        pattern: #"\x1B(?:[@-Z\-_]|\[[0-?]*[ -/]*[@-~])"#
    )

    init(agent: Agent, customName: String, initialCommand: String? = nil) {
        self.id = UUID().uuidString.lowercased()
        self.agent = agent
        self.title = agent.name
        self.customName = customName
        self.initialCommand = initialCommand
        activityLog.append(ActivityEvent(sessionID: id, kind: .sessionStarted))
    }

    /// Used when reattaching to an existing PTY session with a known session ID.
    init(agentID: String, agentName: String, sessionID: String, customName: String) {
        self.id = sessionID
        self.agent = Agent(id: agentID, name: agentName, connected: true)
        self.title = agentName
        self.customName = customName
        self.initialCommand = nil
        activityLog.append(ActivityEvent(sessionID: sessionID, kind: .sessionStarted))
    }

    /// Feed raw terminal bytes into SwiftTerm and parse for activity events.
    func receive(_ data: Data) {
        guard let tv = terminalView else { return }
        let bytes = [UInt8](data)
        tv.feed(byteArray: bytes[...])
        parseOutput(data)
    }

    /// Log a user-initiated input as an activity event.
    func logUserInput(_ text: String) {
        activityLog.append(ActivityEvent(sessionID: id, kind: .userInput(text)))
    }

    // MARK: - Output Parsing

    private func parseOutput(_ data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else { return }
        let stripped = stripANSI(raw)

        // Cancel pending idle flush
        idleTimer?.cancel()

        // Mark as working
        if case .idle = claudeState {
            toolsUsed = 0
            claudeState = .working(toolsUsed: 0)
        }

        // Process each line; accumulate the last (potentially incomplete) fragment
        let components = stripped.components(separatedBy: "\n")
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            if isLast {
                outputBuffer += component
            } else {
                let fullLine = outputBuffer + component
                outputBuffer = ""
                if !fullLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    processLine(fullLine)
                }
            }
        }

        // After 1s of silence, flush buffer and go idle
        scheduleIdleTimer()
    }

    private func processLine(_ line: String) {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)

        if let match = Self.toolPattern.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            // Flush accumulated text before this tool call
            flushTextBuffer()

            let toolName = String(line[nameRange])

            // Extract args: text between "ToolName(" and first ")"
            let afterOpen = nsLine.substring(from: match.range.upperBound)
            let argsStr: String
            if let closeIdx = afterOpen.firstIndex(of: ")") {
                argsStr = String(afterOpen[..<closeIdx])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            } else {
                argsStr = afterOpen.trimmingCharacters(in: .whitespaces)
            }

            toolsUsed += 1
            claudeState = .working(toolsUsed: toolsUsed)
            activityLog.append(ActivityEvent(sessionID: id, kind: .toolCall(name: toolName, args: argsStr)))
        } else {
            outputBuffer += line + "\n"
        }
    }

    private func flushTextBuffer() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        outputBuffer = ""
        guard !text.isEmpty else { return }
        activityLog.append(ActivityEvent(sessionID: id, kind: .claudeText(text)))
    }

    private func scheduleIdleTimer() {
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.flushTextBuffer()
                self.claudeState = .idle
            }
        }
    }

    private func stripANSI(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Self.ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
