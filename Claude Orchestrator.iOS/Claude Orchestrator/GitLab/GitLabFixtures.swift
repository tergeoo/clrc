#if DEBUG
import SwiftUI
import ClrcCore

/// `-designPreview gitlablist|gitlabmr`.
struct GitLabPreviewHost: View {
    let state: String
    @StateObject private var relay: RelayWebSocket
    @StateObject private var sessionManager: SessionManager

    static let states: Set<String> = ["gitlablist", "gitlabmr"]

    init(state: String) {
        self.state = state
        let (relay, manager) = PreviewEnvironment.make(agents: PreviewEnvironment.macs)
        _relay = StateObject(wrappedValue: relay)
        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        Group {
            if state == "gitlabmr" {
                NavigationStack {
                    MergeRequestScreen(route: MergeRequestRoute(projectID: 42, iid: 128, title: "Passkey"),
                                       preloaded: (Self.mrs[0], Self.entries, Self.discussions))
                }
            } else {
                ReviewScreen(previewMRs: Self.mrs, initialSource: .gitlab)
            }
        }
        .environmentObject(relay)
        .environmentObject(sessionManager)
    }

    static func mr(_ iid: Int, _ title: String, _ ref: String, _ author: String, _ src: String, notes: Int,
                   pipeline: String?, draft: Bool = false) -> GitLabMR {
        let json = """
        {"id":\(iid),"iid":\(iid),"project_id":42,"title":"\(title)","source_branch":"\(src)","target_branch":"main",
         "web_url":"https://gitlab.example.com/web/-/merge_requests/\(iid)","references":{"full":"\(ref)"},
         "author":{"name":"\(author)","username":"u"},"draft":\(draft),"user_notes_count":\(notes),
         "description":"Логин через passkey вместо токена в заголовке. Старый x-token поддерживается до 1 декабря.",
         \(pipeline.map { "\"head_pipeline\":{\"status\":\"\($0)\"}," } ?? "")
         "diff_refs":{"base_sha":"b","head_sha":"h","start_sha":"s"}}
        """
        return try! GitLabJSON.decoder.decode(GitLabMR.self, from: Data(json.utf8))
    }

    static let mrs = [
        mr(128, "Passkey-логин вместо x-token", "web/app!128", "Анна Смирнова", "feature/passkey", notes: 4, pipeline: "success"),
        mr(77, "Миграция users → accounts", "backend/api!77", "Георгий", "refactor/accounts", notes: 0, pipeline: "failed"),
        mr(12, "Обновить зависимости", "infra/ci!12", "renovate", "deps/weekly", notes: 1, pipeline: "running", draft: true),
    ]

    static let entries = [
        GitLabDiffEntry(oldPath: "src/routes/login.tsx", newPath: "src/routes/login.tsx",
                        diff: "@@ -38,4 +38,5 @@\n   const ctx = req.context;\n-  const token = req.headers.get(\"x-token\");\n+  const token = bearer(req);\n+  if (!token) return unauthorized();\n   return next();\n",
                        newFile: false, renamedFile: false, deletedFile: false, generatedFile: nil),
        GitLabDiffEntry(oldPath: "src/auth/passkey.ts", newPath: "src/auth/passkey.ts",
                        diff: "@@ -0,0 +1,2 @@\n+export async function verifyPasskey() {}\n+export const x = 1;\n",
                        newFile: true, renamedFile: false, deletedFile: false, generatedFile: nil),
        GitLabDiffEntry(oldPath: "package-lock.json", newPath: "package-lock.json", diff: "@@ -1 +1 @@\n-a\n+b\n",
                        newFile: false, renamedFile: false, deletedFile: false, generatedFile: nil),
    ]

    static let discussions = [
        GitLabDiscussion(id: "d1", notes: [GitLabNote(id: 1, body: "Нужен ли fallback на x-token?", author: GitLabUser(name: "Анна", username: "anna"),
                                                      system: false, position: GitLabPosition(newPath: "src/routes/login.tsx", oldPath: "src/routes/login.tsx", newLine: 39, oldLine: nil), createdAt: nil)]),
    ]
}
#endif
