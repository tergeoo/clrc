import Testing
import Foundation
@testable import ClrcCore

@Test func russianPluralPicksFormByNumber() {
    #expect(ru(1, one: "файл", few: "файла", many: "файлов") == "1 файл")
    #expect(ru(3, one: "файл", few: "файла", many: "файлов") == "3 файла")
    #expect(ru(5, one: "файл", few: "файла", many: "файлов") == "5 файлов")
    #expect(ru(11, one: "файл", few: "файла", many: "файлов") == "11 файлов")
    #expect(ru(21, one: "файл", few: "файла", many: "файлов") == "21 файл")
    #expect(ru(22, one: "Мак", few: "Мака", many: "Маков") == "22 Мака")
    #expect(ru(0, one: "Мак", few: "Мака", many: "Маков") == "0 Маков")
}

@Test func agoTextRoundsDown() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(agoText(from: now.addingTimeInterval(-30), now: now) == "сейчас")
    #expect(agoText(from: now.addingTimeInterval(-120), now: now) == "2 мин")
    #expect(agoText(from: now.addingTimeInterval(-7200), now: now) == "2 ч")
    #expect(agoText(from: now.addingTimeInterval(-3 * 86_400), now: now) == "3 д")
    #expect(agoText(from: now.addingTimeInterval(60), now: now) == "сейчас")
}
