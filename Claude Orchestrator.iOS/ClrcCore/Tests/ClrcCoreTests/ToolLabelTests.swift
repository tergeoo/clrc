import Testing
import Foundation
@testable import ClrcCore

@Test func bashLabelUsesFirstCommandLine() {
    #expect(ToolLabel.label(name: "Bash", input: #"{"command":"make test\necho x"}"#) == "Bash: make test")
}

@Test func editLabelKeepsLastThreePathComponents() {
    #expect(ToolLabel.label(name: "Edit", input: #"{"file_path":"/Users/g/web/src/routes/login.tsx"}"#)
            == "Edit src/routes/login.tsx")
    #expect(ToolLabel.label(name: "Read", input: #"{"file_path":"main.go"}"#) == "Read main.go")
}

@Test func searchAndWebLabels() {
    #expect(ToolLabel.label(name: "Grep", input: #"{"pattern":"TODO"}"#) == "Grep TODO")
    #expect(ToolLabel.label(name: "WebFetch", input: #"{"url":"https://x.dev"}"#) == "WebFetch https://x.dev")
    #expect(ToolLabel.label(name: "WebSearch", input: #"{"query":"swift"}"#) == "WebSearch swift")
}

@Test func invalidJSONFallsBackToName() {
    #expect(ToolLabel.label(name: "Edit", input: #"{"file_path":"/Users/g/we"#) == "Edit")
}

@Test func unknownToolOrMissingKeyFallsBackToName() {
    #expect(ToolLabel.label(name: "TodoWrite", input: #"{"todos":[]}"#) == "TodoWrite")
    #expect(ToolLabel.label(name: "Bash", input: #"{}"#) == "Bash")
}

@Test func longLabelIsCappedAtSixtyCharacters() {
    let cmd = String(repeating: "a", count: 200)
    let label = ToolLabel.label(name: "Bash", input: #"{"command":"\#(cmd)"}"#)
    #expect(label.count == 60)
    #expect(label.hasSuffix("…"))
}

@Test func toolSymbols() {
    #expect(ToolLabel.symbol(for: "Read") == "doc.text")
    #expect(ToolLabel.symbol(for: "Edit") == "pencil")
    #expect(ToolLabel.symbol(for: "Bash") == "terminal")
    #expect(ToolLabel.symbol(for: "Grep") == "magnifyingglass")
    #expect(ToolLabel.symbol(for: "WebFetch") == "globe")
    #expect(ToolLabel.symbol(for: "Other") == "wrench.and.screwdriver")
}

@Test func currentToolOnlyWhileTurnIsOpen() {
    let open = ChatTurn(id: 1, events: [
        ChatEvent(kind: .turnStart, seq: 1, ts: "2026-11-24T10:00:00Z"),
        ChatEvent(kind: .toolUse, seq: 2, ts: "", name: "Bash", input: #"{"command":"ls"}"#),
    ])
    #expect(open.currentTool == "Bash: ls")
    #expect(open.startedAt == ISO8601DateFormatter().date(from: "2026-11-24T10:00:00Z"))

    let closed = ChatTurn(id: 1, events: open.events + [ChatEvent(kind: .turnEnd, seq: 3, ts: "")])
    #expect(closed.currentTool == nil)
}

@Test func startedAtAcceptsFractionalSeconds() {
    let turn = ChatTurn(id: 1, events: [ChatEvent(kind: .turnStart, seq: 1, ts: "2026-11-24T10:00:00.250Z")])
    #expect(turn.startedAt == ISO8601DateFormatter().date(from: "2026-11-24T10:00:00Z")!.addingTimeInterval(0.25))
}
