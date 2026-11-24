import Testing
@testable import ClrcCore

private func use(_ name: String, _ seq: UInt64) -> ChatEvent {
    ChatEvent(kind: .toolUse, seq: seq, ts: "", toolID: "t\(seq)", name: name)
}

@Test func countsAndOrdersByFrequency() {
    let names = ["Read", "Edit", "Read", "Bash", "Read", "Edit", "Bash"]
    let events = names.enumerated().map { use($1, UInt64($0 + 1)) }
    let summary = ToolSummary.of(events)
    #expect(summary?.count == 7)
    #expect(summary?.text == "7 действий · Read ×3 · Edit ×2 · Bash ×2")
}

@Test func singleTool() {
    #expect(ToolSummary.of([use("Read", 1)])?.text == "1 действие · Read")
    #expect(ToolSummary.of([use("Read", 1), use("Read", 2)])?.text == "2 действия · Read ×2")
}

@Test func capsAtThreeNames() {
    let events = ["A", "B", "C", "D", "E"].enumerated().map { use($1, UInt64($0 + 1)) }
    #expect(ToolSummary.of(events)?.text == "5 действий · A · B · C · ещё 2")
}

@Test func countsFailedResults() {
    let events = [use("Bash", 1),
                  ChatEvent(kind: .toolResult, seq: 2, ts: "", toolID: "t1", ok: false),
                  use("Read", 3),
                  ChatEvent(kind: .toolResult, seq: 4, ts: "", toolID: "t3", ok: true)]
    #expect(ToolSummary.of(events)?.failed == 1)
}

@Test func nilWithoutTools() {
    #expect(ToolSummary.of([ChatEvent(kind: .text, seq: 1, ts: "", text: "hi")]) == nil)
}
