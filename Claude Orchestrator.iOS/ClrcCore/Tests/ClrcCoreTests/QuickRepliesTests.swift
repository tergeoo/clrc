import Testing
@testable import ClrcCore

@Test func permanentOnlyWithoutReport() {
    let chips = QuickReplies.chips(for: nil)
    #expect(chips.map(\.title) == QuickReplies.permanent)
    #expect(chips.allSatisfy { !$0.isAnswer && $0.text == $0.title })
}

@Test func questionsFirstThenPermanentDeduped() {
    let chips = QuickReplies.chips(for: TurnReport(status: .needsInput, questions: ["Да", "Покажи SQL"]))
    #expect(chips.map(\.title) == ["1 · Да", "2 · Покажи SQL", "Продолжай", "Нет", "Покажи diff", "Запусти тесты", "Закоммить"])
    #expect(chips.prefix(2).map(\.text) == ["1", "2"])
    #expect(chips.prefix(2).allSatisfy { $0.isAnswer })
}

@Test func longQuestionTitleTruncated() {
    let long = String(repeating: "я", count: 40)
    let title = QuickReplies.chips(for: TurnReport(status: .needsInput, questions: [long]))[0].title
    #expect(title.count == 28)
    #expect(title.hasSuffix("…"))
}

@Test func cdQuotesPath() {
    #expect(ShellCommand.cd("/u/it's x") == #"cd '/u/it'\''s x'"#)
    #expect(ShellCommand.cd(nil) == "cd ~")
    #expect(ShellCommand.cd("~") == "cd ~")
    #expect(ShellCommand.cd("") == "cd ~")
}
