import Testing
import Foundation
@testable import ClrcCore

private func decode(_ json: String) throws -> ChatEvent {
    try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
}

@Test("Decodes a report event with every field")
func decodesReportEvent() throws {
    let json = #"""
    {"kind":"report","seq":5,"ts":"t","truncated":true,"report":{"v":1,"status":"needs_input",
     "title":"Need a value","summary":"Waiting.","questions":["How many days?"],
     "next_steps":["Set it"],"changed_files":["a.go","b.go"],
     "header":"tergeo · personal","context_ok":true,"source":"block"}}
    """#
    let event = try decode(json)
    #expect(event.kind == .report)
    #expect(event.truncated)
    let report = try #require(event.report)
    #expect(report.status == .needsInput)
    #expect(report.title == "Need a value")
    #expect(report.questions == ["How many days?"])
    #expect(report.nextSteps == ["Set it"])
    #expect(report.changedFiles == ["a.go", "b.go"])
    #expect(report.header == "tergeo · personal")
    #expect(report.contextOK)
    #expect(report.source == "block")
}

@Test("Report decoding tolerates missing and unknown fields")
func reportToleratesShape() throws {
    let event = try decode(#"{"kind":"report","seq":1,"ts":"t","report":{"status":"invented","extra":{"x":1}}}"#)
    let report = try #require(event.report)
    #expect(report.status == .unknown)
    #expect(report.v == 1)
    #expect(report.questions.isEmpty)
    #expect(report.changedFiles.isEmpty)
    #expect(!report.contextOK)
}

@Test("A malformed report payload does not break the event")
func malformedReportKeepsEvent() throws {
    let event = try decode(#"{"kind":"report","seq":2,"ts":"t","report":"not an object"}"#)
    #expect(event.kind == .report)
    #expect(event.seq == 2)
    #expect(event.report == nil)
}

@Test("Non-report events carry no report")
func textHasNoReport() throws {
    #expect(try decode(#"{"kind":"text","seq":1,"ts":"t","text":"hi"}"#).report == nil)
}

@Test("Transcript attaches the report to its turn")
func transcriptAttachesReport() {
    let report = TurnReport(status: .done, title: "First", header: "a · b", contextOK: true)
    let later = TurnReport(status: .failed, title: "Second")
    let events = [
        ChatEvent(kind: .turnStart, seq: 1, ts: ""),
        ChatEvent(kind: .text, seq: 2, ts: "", text: "hi"),
        ChatEvent(kind: .report, seq: 3, ts: "", report: report),
        ChatEvent(kind: .turnEnd, seq: 4, ts: ""),
        ChatEvent(kind: .turnStart, seq: 5, ts: ""),
        ChatEvent(kind: .text, seq: 6, ts: "", text: "no report yet"),
    ]
    var transcript = ChatTranscript().applying(events)
    #expect(transcript.turns.count == 2)
    #expect(transcript.turns[0].report == report)
    #expect(transcript.turns[1].report == nil)
    #expect(transcript.latestReport == report)

    transcript = transcript.applying([
        ChatEvent(kind: .report, seq: 7, ts: "", report: later),
        ChatEvent(kind: .turnEnd, seq: 8, ts: ""),
    ])
    #expect(transcript.turns[1].report == later)
    #expect(transcript.latestReport == later)
    #expect(transcript.turns[1].events.last?.kind == .turnEnd)
}

@Test("A report does not change working state")
func reportIsStateNeutral() {
    let state = ChatStateDeriver.deriving(
        [ChatEvent(kind: .report, seq: 1, ts: "", report: TurnReport(status: .failed))],
        from: ChatSessionState(isWorking: true, lastError: nil)
    )
    #expect(state.isWorking)
    #expect(state.lastError == nil)
}

@Test("Answer drafts are the 1-based question number")
func answerDrafts() {
    let report = TurnReport(status: .needsInput, questions: ["Keep 30 days?", "Keep 90 days?"])
    #expect(report.answerDraft(forQuestionAt: 0) == "1")
    #expect(report.answerDraft(forQuestionAt: 1) == "2")
    #expect(report.answerDraft(forQuestionAt: 5) == "")
}

@Test("Display modes map to output styles")
func displayModeStyles() {
    #expect(ChatDisplayMode.chat.outputStyle == "clrc-chat")
    #expect(ChatDisplayMode.brief.outputStyle == "clrc-brief")
    let defaults = UserDefaults(suiteName: "clrc-test-\(UUID().uuidString)")!
    #expect(ChatDisplayMode.stored(in: defaults) == .chat)
    defaults.set("brief", forKey: ChatDisplayMode.storageKey)
    #expect(ChatDisplayMode.stored(in: defaults) == .brief)
    defaults.set("bogus", forKey: ChatDisplayMode.storageKey)
    #expect(ChatDisplayMode.stored(in: defaults) == .chat)
}

@Test("Profile names are validated like the agent does")
func profileValidation() {
    #expect(normalizedProfile(" personal ") == "personal")
    #expect(normalizedProfile("work-2") == "work-2")
    #expect(normalizedProfile("") == nil)
    #expect(normalizedProfile("Personal") == nil)
    #expect(normalizedProfile("../etc") == nil)
}

@Test("Inline markdown renders emphasis and falls back to plain text")
func inlineMarkdownRendering() {
    let bold = inlineMarkdown("say **hi** to `x`")
    #expect(String(bold.characters) == "say hi to x")
    let plain = inlineMarkdown("line one\nline two")
    #expect(String(plain.characters) == "line one\nline two")
    let odd = inlineMarkdown("unclosed **bold and [link(")
    #expect(!String(odd.characters).isEmpty)
}
