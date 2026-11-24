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

// MARK: - Awaiting confirmation (review fix: answers must not bounce back or vanish silently)

private func sent(_ q: inout PendingAnswerQueue, afterSeq: UInt64 = 10) -> PendingAnswer {
    let answer = q.drain(now: t0.addingTimeInterval(3), onlineAgentIDs: ["a1"]).send[0]
    q.markSent(answer, afterSeq: afterSeq, now: t0.addingTimeInterval(3))
    return answer
}

@Test func sentAnswerKeepsSessionWorkingUntilConfirmed() {
    var q = queue()
    _ = sent(&q)
    #expect(q.sessionIDs == ["s1"])
    q.confirm(progress: ["s1": 10])
    #expect(q.sessionIDs == ["s1"])
    q.confirm(progress: ["s1": 11])
    #expect(q.sessionIDs.isEmpty)
}

@Test func unconfirmedAnswerExpiresAfterConfirmWindow() {
    var q = queue()
    _ = sent(&q)
    let sentAt = t0.addingTimeInterval(3)
    #expect(q.expire(now: sentAt.addingTimeInterval(PendingAnswerQueue.confirmWindow - 0.1)).isEmpty)
    let expired = q.expire(now: sentAt.addingTimeInterval(PendingAnswerQueue.confirmWindow))
    #expect(expired.map(\.sessionID) == ["s1"])
    #expect(q.sessionIDs.isEmpty)
}

@Test func newAnswerReplacesAwaitingOneForSameSession() {
    var q = queue()
    _ = sent(&q)
    q.enqueue(sessionID: "s1", agentID: "a1", text: "2", now: t0.addingTimeInterval(4))
    #expect(q.expire(now: t0.addingTimeInterval(1_000)).isEmpty)
    #expect(q.items.map(\.text) == ["2"])
}

@Test func flushAllSendsEverythingNotYetDue() {
    var q = queue(["s1", "s2"])
    let result = q.drain(now: .distantFuture, onlineAgentIDs: ["a1"])
    #expect(result.send.count == 2)
}
