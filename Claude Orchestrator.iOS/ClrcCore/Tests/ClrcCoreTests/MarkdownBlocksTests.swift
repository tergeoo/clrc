import Testing
@testable import ClrcCore

@Test func paragraphsSplitOnBlankLines() {
    #expect(MarkdownBlocks.parse("a\nb\n\nc") == [.paragraph("a\nb"), .paragraph("c")])
}

@Test func headings() {
    #expect(MarkdownBlocks.parse("## Итог") == [.heading(level: 2, text: "Итог")])
    #expect(MarkdownBlocks.parse("#no") == [.paragraph("#no")])
    #expect(MarkdownBlocks.parse("####### seven") == [.paragraph("####### seven")])
}

@Test func lists() {
    #expect(MarkdownBlocks.parse("- x\n* y\n3. z\n12) w") ==
            [.bullet("x"), .bullet("y"), .numbered(3, "z"), .numbered(12, "w")])
}

@Test func listEndsParagraph() {
    #expect(MarkdownBlocks.parse("intro\n- x") == [.paragraph("intro"), .bullet("x")])
}

@Test func fencedCode() {
    #expect(MarkdownBlocks.parse("```go\nfunc a() {}\n  x\n```") == [.code(language: "go", text: "func a() {}\n  x")])
    #expect(MarkdownBlocks.parse("~~~\n# not heading\n\n- not list\n~~~\nafter") ==
            [.code(language: "", text: "# not heading\n\n- not list"), .paragraph("after")])
}

@Test func unterminatedFenceKeepsAllText() {
    #expect(MarkdownBlocks.parse("t\n```\nline1\nline2") == [.paragraph("t"), .code(language: "", text: "line1\nline2")])
}

@Test func crlfAndEmptyInput() {
    #expect(MarkdownBlocks.parse("a\r\nb") == [.paragraph("a\nb")])
    #expect(MarkdownBlocks.parse("") == [])
    #expect(MarkdownBlocks.parse("\n\n") == [])
}
