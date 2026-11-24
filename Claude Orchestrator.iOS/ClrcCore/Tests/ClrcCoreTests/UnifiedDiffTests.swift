import Testing
import Foundation
@testable import ClrcCore

private let modified = """
diff --git a/src/app.go b/src/app.go
index 1111111..2222222 100644
--- a/src/app.go
+++ b/src/app.go
@@ -1,4 +1,4 @@ package main
 package main
-import "fmt"
+import "log"
 
 func a() {}
@@ -10,2 +10,3 @@ func b() {
 x
+y
 z
"""

@Test func modifiedFileWithTwoHunks() {
    let files = UnifiedDiff.parse(modified)
    #expect(files.count == 1)
    let f = files[0]
    #expect(f.path == "src/app.go")
    #expect(f.kind == .modified)
    #expect(f.hunks.count == 2)
    #expect(f.additions == 2)
    #expect(f.deletions == 1)
    let first = f.hunks[0].lines
    #expect(first[0] == DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "package main"))
    #expect(first[1] == DiffLine(kind: .removed, oldNumber: 2, newNumber: nil, text: "import \"fmt\""))
    #expect(first[2] == DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: "import \"log\""))
    #expect(first[3] == DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: ""))
    #expect(f.hunks[1].lines[1] == DiffLine(kind: .added, oldNumber: nil, newNumber: 11, text: "y"))
    #expect(f.hunks[1].header == "@@ -10,2 +10,3 @@ func b() {")
}

@Test func addedDeletedRenamedBinary() {
    let text = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..e69de29
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1 @@
    +hello
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/a.md b/b.md
    similarity index 90%
    rename from a.md
    rename to b.md
    diff --git a/logo.png b/logo.png
    index 1..2 100644
    Binary files a/logo.png and b/logo.png differ
    """
    let files = UnifiedDiff.parse(text)
    #expect(files.map(\.path) == ["new.txt", "old.txt", "b.md", "logo.png"])
    #expect(files.map(\.kind) == [.added, .deleted, .renamed, .modified])
    #expect(files[2].oldPath == "a.md")
    #expect(files[3].isBinary)
    #expect(files[0].additions == 1 && files[1].deletions == 1)
}

@Test func untrackedNoIndexHeaderAndNoNewline() {
    let text = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..ce01362
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1 @@
    +hello
    \\ No newline at end of file
    """
    let f = UnifiedDiff.parse(text)[0]
    #expect(f.kind == .added)
    #expect(f.hunks[0].lines.last?.kind == .noNewline)
    #expect(f.additions == 1)
}

@Test func truncatedInputParsesWhatItHas() {
    let cut = String(modified.prefix(200))
    let files = UnifiedDiff.parse(cut)
    #expect(files.count == 1)
    #expect(files[0].path == "src/app.go")
    #expect(UnifiedDiff.parse("").isEmpty)
    #expect(UnifiedDiff.parse("garbage\nmore").isEmpty)
}

@Test func gitStatusInfoParses() {
    let info = GitStatusInfo(payload: ["branch": "main", "upstream": "origin/main", "ahead": 1, "behind": 0,
                                       "files": [["path": "a.go", "status": "M"], ["path": "n.txt", "status": "??"]],
                                       "error": ""])
    #expect(info?.branch == "main")
    #expect(info?.isDirty == true)
    #expect(info?.files.map(\.kind) == [.modified, .added])
    #expect(GitStatusInfo(payload: ["error": "not a git repository"]) == nil)
    #expect(GitStatusInfo(payload: ["branch": "main", "files": []])?.isDirty == false)
}

@Test func diffPathsRelativeToRepo() {
    #expect(DiffPaths.relative(["/u/api/x.go", "y.go", "~/dev/api/z.go", "/other/q.go"], to: "/u/api") ==
            ["x.go", "y.go", "~/dev/api/z.go", "/other/q.go"])
    #expect(DiffPaths.relative(["~/dev/api/z.go"], to: "~/dev/api") == ["z.go"])
    #expect(DiffPaths.relative(["/u/api/"], to: "/u/api/") == ["/u/api/"])
}
