import Foundation

/// Blocks one-tap replies while a message is on its way: from the tap until
/// the transcript moves past the point it was sent at (the agent echoed it
/// or started a turn), or `timeout` passes so a lost message cannot lock
/// the screen.
public struct SendGate: Sendable, Equatable {
    public static let timeout: TimeInterval = 15

    private var sentAtSeq: UInt64?
    private var sentAt: Date?

    public init() {}

    public mutating func begin(atSeq seq: UInt64, now: Date) {
        sentAtSeq = seq
        sentAt = now
    }

    public func isBlocking(lastSeq: UInt64, now: Date) -> Bool {
        guard let sentAtSeq, let sentAt else { return false }
        return lastSeq <= sentAtSeq && now.timeIntervalSince(sentAt) < Self.timeout
    }
}
