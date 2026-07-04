/// Splits persisted sessions into those still alive on the agent (reattach)
/// and those whose PTY is gone (tombstones).
public struct RestorePlan: Equatable, Sendable {
    public let toAttach: [PersistedSession]
    public let tombstones: [PersistedSession]

    public init(toAttach: [PersistedSession], tombstones: [PersistedSession]) {
        self.toAttach = toAttach
        self.tombstones = tombstones
    }
}

public enum RestorePlanner {
    public static func plan(persisted: [PersistedSession],
                            liveSessionIDs: Set<String>) -> RestorePlan {
        RestorePlan(
            toAttach: persisted.filter { liveSessionIDs.contains($0.id) },
            tombstones: persisted.filter { !liveSessionIDs.contains($0.id) }
        )
    }
}
