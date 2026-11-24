import Foundation
import ClrcCore

/// Everything the chat screen draws, as one value (live session or fixture).
struct ChatContent {
    var name = ""
    /// «~/dev/api · Chat»
    var subtitle = ""
    var mode: ChatDisplayMode = .chat
    var status: SessionStatus = .idle
    /// nil before the first report.
    var contextOK: Bool?
    var contextHeader = ""
    var turns: [ChatTurn] = []
    var isWorking = false
    /// A reply is on its way (`SendGate`): one-tap replies are disabled.
    var isSending = false
    /// What «Повторить» sends again; nil hides the button.
    var retryText: String?
    var chips: [QuickReply] = QuickReplies.chips(for: nil)
    var changedFiles: [String] = []
    var lastSeq: UInt64 = 0

    /// `/Users/<name>/rest` → `~/rest`; other paths unchanged.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/Users/"), parts.count >= 2 else { return path }
        let rest = parts.dropFirst(2).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }
}

/// What the chat screen can ask for.
struct ChatActions {
    var send: (String) -> Void = { _ in }
    var fillDraft: (String) -> Void = { _ in }
    var stop: () -> Void = {}
    var back: () -> Void = {}
    var rename: (String) -> Void = { _ in }
    var setMode: (ChatDisplayMode) -> Void = { _ in }
    var openTerminal: () -> Void = {}
    var close: () -> Void = {}
    /// Opens the diff of these files (a report's `changed_files`).
    var openDiff: ([String]) -> Void = { _ in }
}
