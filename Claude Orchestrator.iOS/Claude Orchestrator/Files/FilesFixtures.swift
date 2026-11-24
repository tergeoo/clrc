#if DEBUG
import SwiftUI
import ClrcCore

/// `-designPreview folder|file|filesearch|markdown`.
struct FilesPreviewHost: View {
    let state: String
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager

    static let states: Set<String> = ["folder", "file", "filesearch", "markdown"]

    init(state: String) {
        self.state = state
        let (relay, manager) = PreviewEnvironment.make(agents: PreviewEnvironment.macs)
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            switch state {
            case "folder":
                FolderBrowser(agentID: "mbp", path: "~/dev/api", preloaded: Self.items)
            case "markdown":
                FileContentView(path: "/Users/g/dev/api/README.md", file: FileText(data: Data(ChatFixtures.reply.utf8)), agentID: "mbp")
            default:
                FileContentView(path: "/Users/g/dev/api/internal/models/account.go", file: FileText(data: Data(Self.code.utf8)),
                                agentID: "mbp", initialQuery: state == "filesearch" ? "account" : "")
                    .navigationTitle("account.go")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .environmentObject(relay)
        .environmentObject(sessionManager)
    }

    private static func item(_ name: String, dir: Bool = false, size: Int = 0) -> FSItem {
        FSItem(dict: ["name": name, "is_dir": dir, "size": size, "mod_time": "2026-11-24T09:12:00Z"])!
    }

    static let items = [item("internal", dir: true), item("db", dir: true), item("cmd", dir: true),
                        item("go.mod", size: 412), item("go.sum", size: 18_204), item("README.md", size: 2_310),
                        item("Makefile", size: 980), item("main.go", size: 1_544)]

    static let code = """
    package models

    import "time"

    // Account replaces User after migration 0042.
    type Account struct {
    \tID        int64     `db:"id"`
    \tEmail     string    `db:"email"`
    \tCreatedAt time.Time `db:"created_at"`
    }

    func (a Account) TableName() string { return "accounts" }

    func NewAccount(email string) Account {
    \treturn Account{Email: email, CreatedAt: time.Now()}
    }
    """
}
#endif
