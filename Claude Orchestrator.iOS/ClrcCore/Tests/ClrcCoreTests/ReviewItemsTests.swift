import Testing
import Foundation
@testable import ClrcCore

private func turn(_ id: UInt64, ts: String, report: TurnReport?, answered: Bool = false) -> ChatTurn {
    var events = [ChatEvent(kind: .turnStart, seq: id, ts: ts)]
    if let report { events.append(ChatEvent(kind: .report, seq: id + 1, ts: "", report: report)) }
    if answered { events.append(ChatEvent(kind: .userText, seq: id + 2, ts: "", text: "1")) }
    return ChatTurn(id: id, events: events)
}

private func session(_ id: String, project: String, turns: [ChatTurn]) -> ReviewSessionSnapshot {
    ReviewSessionSnapshot(sessionID: id, agentID: "m", agentName: "mbp", cwd: "/u/\(project)", turns: turns)
}

@Test func onlyTurnsWithChangedFilesNewestFirst() {
    let a = session("a", project: "api", turns: [
        turn(1, ts: "2026-11-24T09:00:00Z", report: TurnReport(status: .done, title: "first", changedFiles: ["x.go"])),
        turn(10, ts: "2026-11-24T09:30:00Z", report: TurnReport(status: .done, title: "no files")),
    ])
    let b = session("b", project: "web", turns: [
        turn(1, ts: "2026-11-24T10:00:00Z", report: TurnReport(status: .done, title: "web", changedFiles: ["a.ts", "b.ts"])),
    ])
    let items = ReviewItems.build(sessions: [a, b], viewed: [])
    #expect(items.map(\.title) == ["web", "first"])
    #expect(items[0].project == "web")
    #expect(items[0].turnNumber == 1)
    #expect(items[1].files == ["x.go"])
    #expect(items[0].id == "b:1")
}

@Test func labels() {
    let s = session("a", project: "api", turns: [
        turn(1, ts: "2026-11-24T09:00:00Z", report: TurnReport(status: .done, title: "old", changedFiles: ["x"])),
        turn(5, ts: "2026-11-24T09:10:00Z", report: TurnReport(status: .done, title: "seen", changedFiles: ["y"])),
        turn(9, ts: "2026-11-24T09:20:00Z", report: TurnReport(status: .needsInput, title: "ask", questions: ["?"], changedFiles: ["z"])),
    ])
    let items = ReviewItems.build(sessions: [s], viewed: ["a:5"])
    #expect(items.map(\.label) == [.waiting, .viewed, .new])
    let answered = session("a", project: "api", turns: [
        turn(9, ts: "2026-11-24T09:20:00Z", report: TurnReport(status: .needsInput, questions: ["?"], changedFiles: ["z"]), answered: true),
    ])
    #expect(ReviewItems.build(sessions: [answered], viewed: [])[0].label == .new)
}

@Test func turnNumbersCountTurnsInSession() {
    let s = session("a", project: "api", turns: [
        turn(1, ts: "", report: nil),
        turn(4, ts: "", report: TurnReport(status: .done, changedFiles: ["x"])),
    ])
    #expect(ReviewItems.build(sessions: [s], viewed: [])[0].turnNumber == 2)
}

@Test func projectFilter() {
    let items = ReviewItems.build(sessions: [
        session("a", project: "api", turns: [turn(1, ts: "", report: TurnReport(status: .done, changedFiles: ["x"]))]),
        session("b", project: "web", turns: [turn(1, ts: "", report: TurnReport(status: .done, changedFiles: ["y"]))]),
    ], viewed: [])
    #expect(ReviewItems.projects(items) == ["api", "web"])
    #expect(ReviewItems.filter(items, project: "web").map(\.sessionID) == ["b"])
    #expect(ReviewItems.filter(items, project: nil).count == 2)
}

@Test func turnNumbersSkipTheLeadingUserMessage() {
    // The first user message arrives before any turn_start and forms its own pseudo-turn.
    let lead = ChatTurn(id: 1, events: [ChatEvent(kind: .userText, seq: 1, ts: "", text: "go")])
    let s = session("a", project: "api", turns: [lead, turn(2, ts: "", report: TurnReport(status: .done, changedFiles: ["x"]))])
    #expect(ReviewItems.build(sessions: [s], viewed: [])[0].turnNumber == 1)
}
