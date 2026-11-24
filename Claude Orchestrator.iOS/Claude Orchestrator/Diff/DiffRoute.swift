import SwiftUI

/// Changes of a project, optionally limited to some files (a turn's).
struct DiffRoute: Hashable {
    let agentID: String
    let repo: String
    let files: [String]?
    let title: String
}

private struct OpenDiffKey: EnvironmentKey {
    static let defaultValue: @MainActor (DiffRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes a `DiffRoute` onto the current tab's stack.
    var openDiff: @MainActor (DiffRoute) -> Void {
        get { self[OpenDiffKey.self] }
        set { self[OpenDiffKey.self] = newValue }
    }
}

extension View {
    func diffDestinations() -> some View {
        navigationDestination(for: DiffRoute.self) { ChangesScreen(route: $0) }
    }
}
