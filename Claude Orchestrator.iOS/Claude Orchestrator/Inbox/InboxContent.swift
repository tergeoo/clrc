import Foundation
import ClrcCore

/// A recent project offered for a one-tap launch in the empty Inbox.
struct RecentProject: Identifiable, Equatable {
    let agentID: String
    let agentName: String
    let path: String
    var id: String { agentID + ":" + path }
    var name: String { (path as NSString).lastPathComponent }
}

struct Toast: Equatable {
    let text: String
    let canUndo: Bool
}

/// Everything the Inbox screen draws, as one value: the live model builds
/// it from the session manager and relay, previews build it from fixtures.
struct InboxContent: Equatable {
    var sections = InboxSections()
    var pill = ""
    var relayConnected = false
    var isLoading = false
    /// «Показаны данные на 9:32» while the relay is unreachable.
    var lastSyncText: String?
    var toast: Toast?
    var now = Date()
    var recents: [RecentProject] = []

    static let empty = InboxContent()
}

/// What the Inbox screen can ask for; implemented by `InboxView`.
struct InboxActions {
    var open: (SessionRoute) -> Void = { _ in }
    var answer: (InboxCard, Int) -> Void = { _, _ in }
    var undo: () -> Void = {}
    var retry: () -> Void = {}
    var newTask: () -> Void = {}
    var launchRecent: (RecentProject) -> Void = { _ in }
    var stop: (String) -> Void = { _ in }
    var close: (SessionRoute) -> Void = { _ in }
    var restart: (String) -> Void = { _ in }
}
