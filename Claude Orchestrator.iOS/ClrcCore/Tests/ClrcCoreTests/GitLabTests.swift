import Testing
import Foundation
@testable import ClrcCore

private let api = GitLabAPI(baseURL: "gitlab.example.com/", token: "glpat-secret")!
private let refs = GitLabDiffRefs(baseSHA: "b", headSHA: "h", startSHA: "s")

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

@Test func tokenOnlyInHeader() {
    let request = api.request(.mergeRequests(.assigned))
    #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-secret")
    #expect(!(request.url?.absoluteString.contains("glpat") ?? true))
    #expect(request.url?.absoluteString ==
            "https://gitlab.example.com/api/v4/merge_requests?scope=assigned_to_me&state=opened&per_page=50&order_by=updated_at")
    #expect(request.httpMethod == "GET")
}

@Test func refusesWithoutTokenOrURL() {
    #expect(GitLabAPI(baseURL: "https://g.example.com", token: "  ") == nil)
    #expect(GitLabAPI(baseURL: "not a url", token: "t") == nil)
    #expect(GitLabAPI(baseURL: "ftp://g.example.com", token: "t") == nil)
}

@Test func usesNumericProjectID() {
    #expect(api.request(.diffs(project: 42, iid: 7)).url?.path == "/api/v4/projects/42/merge_requests/7/diffs")
    let approve = api.request(.approve(project: 42, iid: 7))
    #expect(approve.httpMethod == "POST")
    #expect(approve.url?.path == "/api/v4/projects/42/merge_requests/7/approve")
    let merge = api.request(.merge(project: 42, iid: 7))
    #expect(merge.httpMethod == "PUT" && merge.url?.path == "/api/v4/projects/42/merge_requests/7/merge")
    let close = api.request(.close(project: 42, iid: 7))
    #expect(close.httpMethod == "PUT" && body(close)["state_event"] as? String == "close")
    let note = api.request(.note(project: 42, iid: 7, body: "ок"))
    #expect(note.url?.path == "/api/v4/projects/42/merge_requests/7/notes")
    #expect(body(note)["body"] as? String == "ок")
    #expect(note.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func linePositionPerLineKind() {
    func position(_ line: DiffLine) -> [String: Any] {
        let r = api.request(.lineComment(project: 1, iid: 2, body: "x", refs: refs, oldPath: "a.go", newPath: "b.go", line: line))
        #expect(r.url?.path == "/api/v4/projects/1/merge_requests/2/discussions")
        return body(r)["position"] as? [String: Any] ?? [:]
    }
    let added = position(DiffLine(kind: .added, oldNumber: nil, newNumber: 12, text: ""))
    #expect(added["new_line"] as? Int == 12 && added["old_line"] == nil)
    #expect(added["position_type"] as? String == "text")
    #expect(added["base_sha"] as? String == "b" && added["head_sha"] as? String == "h" && added["start_sha"] as? String == "s")
    #expect(added["old_path"] as? String == "a.go" && added["new_path"] as? String == "b.go")
    let removed = position(DiffLine(kind: .removed, oldNumber: 9, newNumber: nil, text: ""))
    #expect(removed["old_line"] as? Int == 9 && removed["new_line"] == nil)
    let context = position(DiffLine(kind: .context, oldNumber: 3, newNumber: 4, text: ""))
    #expect(context["old_line"] as? Int == 3 && context["new_line"] as? Int == 4)
}

@Test func decodesMergeRequest() throws {
    let json = """
    {"id":1,"iid":12,"project_id":42,"title":"Passkey","source_branch":"feat/pk","target_branch":"main",
     "web_url":"https://g/x/-/merge_requests/12","references":{"full":"group/web!12"},
     "author":{"name":"Георгий","username":"geo"},"draft":false,"user_notes_count":3,
     "updated_at":"2026-11-24T09:12:33.123Z","description":"d",
     "head_pipeline":{"status":"success","web_url":"https://g/p/1"},
     "diff_refs":{"base_sha":"b","head_sha":"h","start_sha":"s"}}
    """
    let mr = try GitLabJSON.decoder.decode(GitLabMR.self, from: Data(json.utf8))
    #expect(mr.iid == 12 && mr.projectID == 42 && mr.reference == "group/web!12")
    #expect(mr.author.username == "geo" && mr.userNotesCount == 3)
    #expect(mr.headPipeline?.status == "success")
    #expect(mr.diffRefs == refs)
    #expect(mr.updatedAt != nil)
    let minimal = try GitLabJSON.decoder.decode(GitLabMR.self, from: Data("""
    {"id":2,"iid":3,"project_id":4,"title":"t","source_branch":"a","target_branch":"b","web_url":"u","author":{"name":"n","username":"u"}}
    """.utf8))
    #expect(minimal.reference == "!3" && minimal.headPipeline == nil && minimal.userNotesCount == 0)
}

@Test func gitLabDiffEntriesBecomeFiles() {
    let entries = [
        GitLabDiffEntry(oldPath: "a.go", newPath: "a.go", diff: "@@ -1,2 +1,2 @@\n x\n-y\n+z\n", newFile: false, renamedFile: false, deletedFile: false, generatedFile: nil),
        GitLabDiffEntry(oldPath: "n.go", newPath: "n.go", diff: "@@ -0,0 +1 @@\n+hi\n", newFile: true, renamedFile: false, deletedFile: false, generatedFile: nil),
        GitLabDiffEntry(oldPath: "old.md", newPath: "new.md", diff: "", newFile: false, renamedFile: true, deletedFile: false, generatedFile: nil),
        GitLabDiffEntry(oldPath: "gone.go", newPath: "gone.go", diff: "@@ -1 +0,0 @@\n-x\n", newFile: false, renamedFile: false, deletedFile: true, generatedFile: nil),
    ]
    let files = GitLabDiffs.files(entries)
    #expect(files.map(\.kind) == [.modified, .added, .renamed, .deleted])
    #expect(files[0].additions == 1 && files[0].deletions == 1)
    #expect(files[2].oldPath == "old.md" && files[2].newPath == "new.md")
    #expect(files[3].path == "gone.go")
}

@Test func hiddenLockAndGeneratedFiles() {
    func entry(_ path: String, generated: Bool? = nil) -> GitLabDiffEntry {
        GitLabDiffEntry(oldPath: path, newPath: path, diff: "", newFile: false, renamedFile: false, deletedFile: false, generatedFile: generated)
    }
    #expect(GitLabDiffs.isHidden(entry("web/package-lock.json")))
    #expect(GitLabDiffs.isHidden(entry("go.sum")))
    #expect(GitLabDiffs.isHidden(entry("api/schema.go", generated: true)))
    #expect(!GitLabDiffs.isHidden(entry("main.go")))
}

@Test func discussionsMapToLines() {
    let note = GitLabNote(id: 1, body: "почему?", author: GitLabUser(name: "A", username: "a"), system: false,
                          position: GitLabPosition(newPath: "a.go", oldPath: "a.go", newLine: 2, oldLine: nil), createdAt: nil)
    let other = GitLabNote(id: 2, body: "x", author: GitLabUser(name: "B", username: "b"), system: false,
                           position: GitLabPosition(newPath: "b.go", oldPath: "b.go", newLine: 2, oldLine: nil), createdAt: nil)
    let removed = GitLabNote(id: 3, body: "y", author: GitLabUser(name: "C", username: "c"), system: false,
                             position: GitLabPosition(newPath: "a.go", oldPath: "a.go", newLine: nil, oldLine: 5), createdAt: nil)
    let file = GitLabDiffs.files([GitLabDiffEntry(oldPath: "a.go", newPath: "a.go", diff: "", newFile: false,
                                                  renamedFile: false, deletedFile: false, generatedFile: nil)])[0]
    let map = GitLabDiscussions.notes(on: file, in: [GitLabDiscussion(id: "d1", notes: [note]),
                                                      GitLabDiscussion(id: "d2", notes: [other]),
                                                      GitLabDiscussion(id: "d3", notes: [removed])])
    #expect(map["n2"]?.map(\.id) == [1])
    #expect(map["o5"]?.map(\.id) == [3])
    #expect(map.count == 2)
}
