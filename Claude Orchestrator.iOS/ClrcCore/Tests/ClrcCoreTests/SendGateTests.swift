import Testing
import Foundation
@testable import ClrcCore

private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func gateBlocksUntilTheTranscriptMoves() {
    var gate = SendGate()
    #expect(!gate.isBlocking(lastSeq: 10, now: t0))
    gate.begin(atSeq: 10, now: t0)
    #expect(gate.isBlocking(lastSeq: 10, now: t0.addingTimeInterval(1)))
    #expect(!gate.isBlocking(lastSeq: 11, now: t0.addingTimeInterval(1)))
}

@Test func gateGivesUpAfterTimeout() {
    var gate = SendGate()
    gate.begin(atSeq: 10, now: t0)
    #expect(gate.isBlocking(lastSeq: 10, now: t0.addingTimeInterval(SendGate.timeout - 0.1)))
    #expect(!gate.isBlocking(lastSeq: 10, now: t0.addingTimeInterval(SendGate.timeout)))
}
