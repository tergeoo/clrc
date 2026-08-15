import Testing
import Foundation
@testable import ClrcCore

@Test("Decodes a text event")
func decodesTextEvent() throws {
    let json = #"{"kind":"text","seq":3,"ts":"2026-08-15T00:00:00Z","text":"hello"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .text)
    #expect(event.seq == 3)
    #expect(event.text == "hello")
}

@Test("Decodes a tool call")
func decodesToolUse() throws {
    let json = #"{"kind":"tool_use","seq":1,"ts":"t","tool_id":"t1","name":"Bash","input":"{\"command\":\"ls\"}"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .toolUse)
    #expect(event.name == "Bash")
    #expect(event.toolID == "t1")
}

@Test("Decodes turn_end metrics")
func decodesTurnEnd() throws {
    let json = #"{"kind":"turn_end","seq":9,"ts":"t","num_turns":2,"cost_usd":0.05,"duration_ms":4877}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .turnEnd)
    #expect(event.costUSD == 0.05)
    #expect(event.durationMS == 4877)
}

// A newer agent must never break an older app.
@Test("Unknown kind decodes as .unknown rather than throwing")
func toleratesUnknownKind() throws {
    let json = #"{"kind":"something_invented_later","seq":1,"ts":"t"}"#
    let event = try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    #expect(event.kind == .unknown)
    #expect(event.seq == 1)
}
