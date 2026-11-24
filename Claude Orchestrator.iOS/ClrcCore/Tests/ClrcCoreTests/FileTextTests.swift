import Testing
import Foundation
@testable import ClrcCore

@Test func decodesUTF8() {
    let text = FileText(data: Data("привет\nmir".utf8))
    #expect(text.text == "привет\nmir")
    #expect(!text.truncated)
    #expect(text.lines == ["привет", "mir"])
}

@Test func truncatedMidCharacterStillDecodes() {
    // The agent cuts at exactly 100 KB; "я" is two bytes, so cut one byte into a character.
    var data = Data(String(repeating: "я", count: FileText.agentReadLimit / 2).utf8)
    data.removeLast()
    data.append(0xD1) // first byte of another "я"
    #expect(data.count == FileText.agentReadLimit)
    let text = FileText(data: data)
    #expect(text.truncated)
    #expect(!text.text.isEmpty)
    #expect(!text.text.hasSuffix("\u{FFFD}"))
}

@Test func notTruncatedBelowLimit() {
    #expect(!FileText(data: Data(count: FileText.agentReadLimit - 1)).truncated)
}

@Test func matchingLines() {
    let text = FileText(data: Data("Foo\nbar\nfoo\n\nxFOOx".utf8))
    #expect(text.matchingLines("FOO") == [0, 2, 4])
    #expect(text.matchingLines(" ") == [])
    #expect(text.lines.count == 5)
}

@Test func markdownDetection() {
    #expect(FileText.isMarkdown("/u/README.md"))
    #expect(FileText.isMarkdown("notes.MARKDOWN"))
    #expect(!FileText.isMarkdown("main.go"))
}
