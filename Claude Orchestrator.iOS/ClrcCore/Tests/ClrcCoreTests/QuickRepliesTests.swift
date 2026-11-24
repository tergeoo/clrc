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

// Review fix: «~/x» must stay expandable — a quoted tilde is literal to the shell.
@Test func cdKeepsTildeOutsideQuotes() {
    #expect(ShellCommand.cd("~/dev/my app") == #"cd ~/'dev/my app'"#)
    #expect(ShellCommand.quotedPath("~") == "~")
    #expect(ShellCommand.quotedPath("~/a'b") == #"~/'a'\''b'"#)
    #expect(ShellCommand.quotedPath("/u/x") == "'/u/x'")
}

@Test func terminalCommandKeepsTildeOutsideQuotes() {
    #expect(SessionLaunchMode.terminalCommand(cwd: "~/dev/api", prompt: nil) == "cd ~/'dev/api' && claude")
    #expect(SessionNaming.projectPath(from: SessionLaunchMode.terminalCommand(cwd: "~/dev/api", prompt: nil)) == "~/dev/api")
    #expect(SessionNaming.projectPath(from: ShellCommand.cd("~/dev/api")) == "~/dev/api")
}
