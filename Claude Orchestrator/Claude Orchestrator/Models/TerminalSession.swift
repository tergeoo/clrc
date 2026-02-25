import Foundation
import Combine
import SwiftTerm

/// Represents one active PTY session connected to a Mac agent.
@MainActor
final class TerminalSession: ObservableObject, Identifiable, Equatable {
    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool { lhs.id == rhs.id }
    let id: String          // UUID session_id used in protocol
    let agent: Agent

    @Published var title: String
    @Published var isReady: Bool = false

    // The SwiftTerm terminal view — set after the view is created
    weak var terminalView: SwiftTerm.TerminalView?

    // Last known terminal size — used to restore after reconnect
    var lastCols: Int = 80
    var lastRows: Int = 24

    /// Command sent automatically once the PTY session is ready (e.g. "cd ~/project && claude").
    let initialCommand: String?

    init(agent: Agent, initialCommand: String? = nil) {
        self.id = UUID().uuidString
        self.agent = agent
        self.title = agent.name
        self.initialCommand = initialCommand
    }

    /// Used when reattaching to an existing PTY session with a known session ID.
    init(agentID: String, agentName: String, sessionID: String) {
        self.id = sessionID
        self.agent = Agent(id: agentID, name: agentName, connected: true)
        self.title = agentName
        self.initialCommand = nil
    }

    /// Feed raw terminal bytes (stdout/stderr ANSI) into SwiftTerm.
    func receive(_ data: Data) {
        guard let tv = terminalView else { return }
        let bytes = [UInt8](data)
        tv.feed(byteArray: bytes[...])
    }
}
