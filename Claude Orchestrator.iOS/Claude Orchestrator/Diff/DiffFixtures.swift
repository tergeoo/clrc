#if DEBUG
import SwiftUI
import ClrcCore

/// `-designPreview difffile|projectgit`.
struct DiffPreviewHost: View {
    let state: String
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager
    @State private var viewed: Set<String> = []

    static let states: Set<String> = ["difffile", "projectgit"]

    init(state: String) {
        self.state = state
        let (relay, manager) = PreviewEnvironment.make(agents: [PreviewEnvironment.macs[0]], recents: PreviewEnvironment.recents)
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        NavigationStack {
            if state == "projectgit" {
                ProjectView(agentID: "mbp", path: "/Users/g/startups/api", previewGit: GitStatusInfo(payload: [
                    "branch": "feat/accounts", "ahead": 2, "behind": 0,
                    "files": [["path": "internal/models/account.go", "status": "M"],
                              ["path": "db/migrations/0042_accounts.up.sql", "status": "??"],
                              ["path": "internal/models/user.go", "status": "D"]],
                ]))
            } else {
                DiffFileScreen(files: UnifiedDiff.parse(Self.sample), index: 0, viewed: $viewed)
            }
        }
        .environmentObject(relay)
        .environmentObject(sessionManager)
    }

    static let sample = """
    diff --git a/internal/auth/login.go b/internal/auth/login.go
    index 1111111..2222222 100644
    --- a/internal/auth/login.go
    +++ b/internal/auth/login.go
    @@ -38,9 +38,11 @@ func Login(w http.ResponseWriter, req *http.Request) {
     \tctx := req.Context()
    -\ttoken := req.Header.Get("x-token")
    +\ttoken := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
     \tif token == "" {
     \t\tunauthorized(w)
     \t\treturn
     \t}
    -\tuser, err := db.Users.Find(token)
    +\tpasskey, err := verifyPasskey(ctx, token)
    +\tif err != nil {
    +\t\tunauthorized(w)
    +\t\treturn
    +\t}
     \tif err != nil {
    @@ -80,3 +82,4 @@ func Logout(w http.ResponseWriter, req *http.Request) {
     \tsession.Clear(w)
    +\taudit.Log(ctx, "logout")
     }
    """
}
#endif
