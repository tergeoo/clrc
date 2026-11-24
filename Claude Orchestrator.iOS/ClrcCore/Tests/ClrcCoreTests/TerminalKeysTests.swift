import Testing
import Foundation
@testable import ClrcCore

@Test func specialKeyBytes() {
    #expect(TerminalKey.esc.bytes == [0x1B])
    #expect(TerminalKey.tab.bytes == [0x09])
    #expect(TerminalKey.up.bytes == [0x1B, 0x5B, 0x41])
    #expect(TerminalKey.down.bytes == [0x1B, 0x5B, 0x42])
    #expect(TerminalKey.right.bytes == [0x1B, 0x5B, 0x43])
    #expect(TerminalKey.left.bytes == [0x1B, 0x5B, 0x44])
    #expect(TerminalKey.pipe.bytes == Array("|".utf8))
    #expect(TerminalKey.allCases.map(\.label) == ["Esc", "Tab", "↑", "↓", "←", "→", "|", "~", "/", "-"])
    #expect(TerminalKeys.historyUp == TerminalKey.up.bytes)
    #expect(TerminalKeys.interrupt == [0x03])
}

@Test func ctrlLetterBytes() {
    #expect(TerminalKeys.ctrl("c") == 0x03)
    #expect(TerminalKeys.ctrl("A") == 0x01)
    #expect(TerminalKeys.ctrl("Z") == 0x1A)
    #expect(TerminalKeys.ctrl("1") == nil)
    #expect(TerminalKeys.ctrl("я") == nil)
}

@Test func fontClampAndPinch() {
    #expect(TerminalFont.clamped(9) == 10)
    #expect(TerminalFont.clamped(20) == 18)
    #expect(TerminalFont.clamped(13) == 13)
    #expect(TerminalFont.pinched(from: 13, scale: 1.5) == 18)
    #expect(TerminalFont.pinched(from: 13, scale: 0.9) == 11.5)
}

@Test func commandGroups() {
    #expect(TerminalCommands.groups.map(\.title) == ["Навигация", "Git", "Claude", "Система"])
    #expect(TerminalCommands.groups.allSatisfy { !$0.commands.isEmpty })
    let all = TerminalCommands.groups.flatMap(\.commands)
    #expect(all.allSatisfy { $0.bytes.last == 0x0A })
    #expect(Set(all.map(\.id)).count == all.count)
}
