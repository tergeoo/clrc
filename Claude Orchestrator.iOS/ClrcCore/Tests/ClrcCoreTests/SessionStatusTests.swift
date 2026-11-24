import Testing
import Foundation
@testable import ClrcCore

@Test func workingOverridesStaleReport() {
    let report = TurnReport(status: .done)
    #expect(SessionStatus.derive(isWorking: true, lastError: nil, report: report) == .working)
}

@Test func errorWinsOverDoneReport() {
    #expect(SessionStatus.derive(isWorking: false, lastError: "boom", report: TurnReport(status: .done)) == .failed)
}

@Test func reportStatusMapsToSessionStatus() {
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .needsInput)) == .needsInput)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .failed)) == .failed)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .done)) == .done)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .inProgress)) == .working)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: TurnReport(status: .unknown)) == .idle)
    #expect(SessionStatus.derive(isWorking: false, lastError: nil, report: nil) == .idle)
}

@Test func onlyNeedsInputAndFailedNeedTheUser() {
    #expect(SessionStatus.allCases.filter(\.needsUser) == [.needsInput, .failed])
}

@Test func statusLabelsAreRussian() {
    #expect(SessionStatus.needsInput.label == "ждёт ответа")
    #expect(SessionStatus.failed.label == "ошибка")
    #expect(SessionStatus.working.label == "работает")
    #expect(SessionStatus.done.label == "готово")
    #expect(SessionStatus.idle.label == "нет данных")
}

@Test func voiceOverLabelNamesSessionStatusAndQuestions() {
    #expect(SessionStatus.accessibilityLabel(session: "api", status: .needsInput, questionCount: 2)
            == "Сессия api: ждёт ответа, 2 вопроса")
    #expect(SessionStatus.accessibilityLabel(session: "api", status: .needsInput, questionCount: 1)
            == "Сессия api: ждёт ответа, 1 вопрос")
    #expect(SessionStatus.accessibilityLabel(session: "web", status: .done, questionCount: 0)
            == "Сессия web: готово")
}
