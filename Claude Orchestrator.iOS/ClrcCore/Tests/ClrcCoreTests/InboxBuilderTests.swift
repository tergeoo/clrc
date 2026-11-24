import Testing
import Foundation
@testable import ClrcCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func chat(_ id: String, _ status: SessionStatus, questions: [String] = [], files: [String] = [],
                  updated: TimeInterval = 0, started: TimeInterval? = nil) -> InboxChatSnapshot {
    let report: TurnReport? = status == .idle && questions.isEmpty && files.isEmpty
        ? nil
        : TurnReport(status: .done, title: "t-\(id)", questions: questions, changedFiles: files, contextOK: true)
    return InboxChatSnapshot(id: id, name: id, agentID: "a1", agentName: "mbp-work", project: "api",
                             status: status, report: report, currentTool: nil,
                             turnStartedAt: started.map { t0.addingTimeInterval($0) },
                             updatedAt: t0.addingTimeInterval(updated), agentOnline: true)
}

private func build(_ chats: [InboxChatSnapshot], pending: Set<String> = []) -> InboxSections {
    InboxBuilder.build(chats: chats, terminals: [], ended: [], pendingAnswerIDs: pending)
}

@Test func sectionsByUrgency() {
    let s = build([chat("n", .needsInput), chat("f", .failed), chat("w", .working, started: 0),
                   chat("d", .done), chat("i", .idle)])
    #expect(s.waiting.map(\.id).sorted() == ["f", "n"])
    #expect(s.working.map(\.id) == ["w"])
    #expect(s.done.map(\.id).sorted() == ["d", "i"])
}

@Test func waitingNewestFirst() {
    let s = build([chat("old", .needsInput, updated: 10), chat("new", .needsInput, updated: 50)])
    #expect(s.waiting.map(\.id) == ["new", "old"])
}

@Test func workingOldestTurnFirst() {
    let s = build([chat("late", .working, started: 90), chat("early", .working, started: 10)])
    #expect(s.working.map(\.id) == ["early", "late"])
}

@Test func pendingAnswerMovesCardToWorking() {
    let s = build([chat("n", .needsInput, questions: ["a"])], pending: ["n"])
    #expect(s.waiting.isEmpty)
    #expect(s.working.map(\.id) == ["n"])
}

@Test func needsInputWithoutQuestionsStaysWaitingWithNoAnswers() {
    let s = build([chat("n", .needsInput, files: ["x.go"])])
    #expect(s.waiting.first?.answers == [])
    #expect(s.waiting.first?.moreAnswers == false)
}

@Test func answersCappedAtTwo() {
    let card = build([chat("n", .needsInput, questions: ["a", "b", "c"])]).waiting.first
    #expect(card?.answers == ["a", "b"])
    #expect(card?.moreAnswers == true)
}

@Test func metaCountsFilesAndOmitsZero() {
    #expect(build([chat("n", .needsInput, files: ["a", "b", "c", "d"])]).waiting.first?.meta == "api · mbp-work · 4 файла")
    #expect(build([chat("n", .needsInput, questions: ["q"])]).waiting.first?.meta == "api · mbp-work")
}

@Test func contextOKIsNilWithoutReport() {
    #expect(build([chat("i", .idle)]).done.first?.contextOK == nil)
    #expect(build([chat("d", .done, files: ["a"])]).done.first?.contextOK == true)
}

@Test func summaryLine() {
    let s = build([chat("a", .needsInput), chat("b", .failed), chat("c", .working), chat("d", .done)])
    #expect(s.summaryLine == "2 ждут вас · 1 работает · 1 готово")
    #expect(build([chat("a", .needsInput), chat("c", .working), chat("e", .working)]).summaryLine
            == "1 ждёт вас · 2 работают")
    #expect(build([]).summaryLine == "Всё спокойно")
}

@Test func emptyOnlyWhenNothingAtAll() {
    #expect(build([]).isEmpty)
    let withTerminal = InboxBuilder.build(
        chats: [], terminals: [InboxTerminalSnapshot(id: "t", name: "zsh", agentName: "m", isWorking: false, agentOnline: true)],
        ended: [], pendingAnswerIDs: [])
    #expect(!withTerminal.isEmpty)
    let withEnded = InboxBuilder.build(
        chats: [], terminals: [], ended: [InboxEndedSnapshot(id: "e", name: "api", agentName: "m", projectPath: nil)],
        pendingAnswerIDs: [])
    #expect(!withEnded.isEmpty)
}

@Test func connectionPill() {
    #expect(InboxBuilder.connectionPill(relayConnected: false, onlineMacs: 2) == "нет связи")
    #expect(InboxBuilder.connectionPill(relayConnected: true, onlineMacs: 0) == "нет Маков")
    #expect(InboxBuilder.connectionPill(relayConnected: true, onlineMacs: 1) == "1 Мак")
    #expect(InboxBuilder.connectionPill(relayConnected: true, onlineMacs: 2) == "2 Мака")
}
