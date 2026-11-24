import Testing
import Foundation
@testable import ClrcCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func queue(_ ids: [String] = ["s1"]) -> PendingAnswerQueue {
    var q = PendingAnswerQueue()
    for id in ids { q.enqueue(sessionID: id, agentID: "a1", text: "1", now: t0) }
    return q
}

@Test func notDueBeforeThreeSeconds() {
    var q = queue()
    let result = q.drain(now: t0.addingTimeInterval(2.9), onlineAgentIDs: ["a1"])
    #expect(result.send.isEmpty && result.dropped.isEmpty)
    #expect(q.sessionIDs == ["s1"])
}

@Test func dueAtThreeSeconds() {
    var q = queue()
    let result = q.drain(now: t0.addingTimeInterval(PendingAnswerQueue.undoWindow), onlineAgentIDs: ["a1"])
    #expect(result.send.map(\.sessionID) == ["s1"])
    #expect(result.send.first?.text == "1")
    #expect(q.items.isEmpty)
}

@Test func cancelRemovesAndReturnsTheAnswer() {
    var q = queue()
    #expect(q.cancel(sessionID: "s1")?.text == "1")
    #expect(q.items.isEmpty)
    #expect(q.cancel(sessionID: "s1") == nil)
}

@Test func enqueueReplacesSameSession() {
    var q = queue()
    q.enqueue(sessionID: "s1", agentID: "a1", text: "2", now: t0.addingTimeInterval(1))
    #expect(q.items.count == 1)
    #expect(q.items.first?.text == "2")
    #expect(q.items.first?.dueAt == t0.addingTimeInterval(1 + PendingAnswerQueue.undoWindow))
}

@Test func dropsAnswersForOfflineAgent() {
    var q = queue()
    let result = q.drain(now: t0.addingTimeInterval(5), onlineAgentIDs: [])
    #expect(result.send.isEmpty)
    #expect(result.dropped.map(\.sessionID) == ["s1"])
    #expect(q.items.isEmpty)
}
