import Testing
import Foundation
@testable import ClrcCore

private func file(_ name: String, dir: Bool = false) -> FSItem {
    FSItem(dict: ["name": name, "is_dir": dir])!
}

@Test func fsItemParsesAndRejects() {
    let item = FSItem(dict: ["name": "a.go", "is_dir": false, "size": 42, "mod_time": "2026-11-24T10:00:00Z"])
    #expect(item?.size == 42)
    #expect(item?.modified == ISO8601DateFormatter().date(from: "2026-11-24T10:00:00Z"))
    #expect(FSItem(dict: ["name": "x"]) == nil)
    #expect(FSItem(dict: ["is_dir": true]) == nil)
}

@Test func listingDirsFirstNaturalOrder() {
    let sorted = FSListing.sorted([file("b"), file("a10"), file("a2"), file("z", dir: true)])
    #expect(sorted.map(\.name) == ["z", "a2", "a10", "b"])
}

@Test func listingFilter() {
    let items = [file("Main.swift"), file("readme.md"), file("Ёлка.txt")]
    #expect(FSListing.filtered(items, query: "main").map(\.name) == ["Main.swift"])
    #expect(FSListing.filtered(items, query: "елка").map(\.name) == ["Ёлка.txt"])
    #expect(FSListing.filtered(items, query: "  ").count == 3)
}

@Test func kindSymbols() {
    #expect(file("src", dir: true).kindSymbol == "folder.fill")
    #expect(file("README.md").kindSymbol == "doc.richtext")
    #expect(file("main.go").kindSymbol == "chevron.left.forwardslash.chevron.right")
    #expect(file("logo.PNG").kindSymbol == "photo")
    #expect(file("notes").kindSymbol == "doc")
}

@Test func crumbsForHomeRelativePath() {
    let crumbs = PathCrumbs.crumbs(for: "~/dev/api")
    #expect(crumbs.map(\.name) == ["~", "dev", "api"])
    #expect(crumbs.map(\.path) == ["~", "~/dev", "~/dev/api"])
    #expect(PathCrumbs.crumbs(for: "~").map(\.path) == ["~"])
}

@Test func crumbsForAbsolutePath() {
    let crumbs = PathCrumbs.crumbs(for: "/Users/g/x/")
    #expect(crumbs.map(\.name) == ["/", "Users", "g", "x"])
    #expect(crumbs.map(\.path) == ["/", "/Users", "/Users/g", "/Users/g/x"])
}

@Test func joinPaths() {
    #expect(PathCrumbs.join("~", "a") == "~/a")
    #expect(PathCrumbs.join("/", "a") == "/a")
    #expect(PathCrumbs.join("/u/g/", "a") == "/u/g/a")
}

@Test func filterIsCaseInsensitive() {
    let paths = ["/u/апи", "/u/web", "/srv/Web-old"]
    #expect(ProjectIndex.filter(paths, query: "АПИ") == ["/u/апи"])
    #expect(ProjectIndex.filter(paths, query: "WEB") == ["/u/web", "/srv/Web-old"])
    #expect(ProjectIndex.filter(paths, query: "srv") == ["/srv/Web-old"])
    #expect(ProjectIndex.filter(paths, query: "") == paths)
}

@Test func sessionCountMatchesExactFolder() {
    #expect(ProjectIndex.sessionCount(path: "/u/api", folders: ["/u/api/", "/u/api2", nil, "/u/api"]) == 2)
}

@Test func macLevelOnlyWithSeveralMacs() {
    #expect(!ProjectIndex.showsMacLevel(macCount: 0))
    #expect(!ProjectIndex.showsMacLevel(macCount: 1))
    #expect(ProjectIndex.showsMacLevel(macCount: 2))
}
