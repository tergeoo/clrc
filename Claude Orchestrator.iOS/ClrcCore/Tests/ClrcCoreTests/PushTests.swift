import Testing
import Foundation
@testable import ClrcCore

@Test func categoriesOfferOneActionPerQuestion() {
    #expect(PushCategories.all.map(\.id) == ["CLRC_Q0", "CLRC_Q1", "CLRC_Q2", "CLRC_Q3"])
    #expect(PushCategories.all[0].answerActions.isEmpty)
    #expect(PushCategories.all[2].answerActions.map(\.title) == ["Вариант 1", "Вариант 2"])
    #expect(PushCategories.all[3].answerActions.map(\.id) == ["answer_1", "answer_2", "answer_3"])
    #expect(PushCategories.textReplyID == "reply_text")
}

@Test func actionsMapToTheTextSent() {
    #expect(PushCategories.answer(actionID: "answer_2", typedText: nil) == "2")
    #expect(PushCategories.answer(actionID: "reply_text", typedText: "  да, запускай ") == "да, запускай")
    #expect(PushCategories.answer(actionID: "reply_text", typedText: "   ") == nil)
    #expect(PushCategories.answer(actionID: "com.apple.UNNotificationDefaultActionIdentifier", typedText: nil) == nil)
    #expect(PushCategories.answer(actionID: "answer_9", typedText: nil) == nil)
}

@Test func pushTargetFromUserInfo() {
    let info: [AnyHashable: Any] = ["agent_id": "a", "session_id": "s", "status": "needs_input", "aps": [:]]
    #expect(PushTarget(userInfo: info) == PushTarget(agentID: "a", sessionID: "s"))
    #expect(PushTarget(userInfo: ["session_id": "s"]) == nil)
}

@Test func notifyStatusesStoredWithDefaults() {
    #expect(PushNotify.decode(nil) == ["needs_input", "failed", "done"])
    #expect(PushNotify.decode("failed") == ["failed"])
    #expect(PushNotify.decode("none") == [])
    #expect(PushNotify.encode([]) == "none")
    #expect(PushNotify.decode(PushNotify.encode(["needs_input", "done"])) == ["needs_input", "done"])
}

@Test func deviceTokenHex() {
    #expect(PushNotify.hex(Data([0x0a, 0xff, 0x00])) == "0aff00")
}
