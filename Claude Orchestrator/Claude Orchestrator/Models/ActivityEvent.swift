import Foundation

struct ActivityEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: String
    let kind: Kind

    enum Kind {
        case sessionStarted
        case userInput(String)
        case claudeText(String)
        case toolCall(name: String, args: String)
        case sessionEnded
    }

    var isContentEvent: Bool {
        switch kind {
        case .sessionStarted, .sessionEnded: return false
        default: return true
        }
    }

    init(sessionID: String, kind: Kind) {
        self.id = UUID()
        self.timestamp = Date()
        self.sessionID = sessionID
        self.kind = kind
    }
}
