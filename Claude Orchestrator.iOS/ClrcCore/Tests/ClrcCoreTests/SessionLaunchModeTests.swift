import Testing
@testable import ClrcCore

@Suite("SessionLaunchMode")
struct SessionLaunchModeTests {
    @Test("Derives the mode from the stored display mode and terminal flag")
    func derivesFromStoredValues() {
        #expect(SessionLaunchMode(displayMode: .chat, inTerminal: false) == .chat)
        #expect(SessionLaunchMode(displayMode: .brief, inTerminal: false) == .brief)
        #expect(SessionLaunchMode(displayMode: .brief, inTerminal: true) == .terminal)
    }

    @Test("Chat modes carry their display mode, terminal carries none")
    func displayModes() {
        #expect(SessionLaunchMode.chat.displayMode == .chat)
        #expect(SessionLaunchMode.brief.displayMode == .brief)
        #expect(SessionLaunchMode.terminal.displayMode == nil)
    }

    @Test("Terminal command runs claude, in the project when one is given")
    func terminalCommand() {
        #expect(SessionLaunchMode.terminalCommand(cwd: nil) == "claude")
        #expect(SessionLaunchMode.terminalCommand(cwd: "~") == "claude")
        let cmd = SessionLaunchMode.terminalCommand(cwd: "/Users/me/my app")
        #expect(cmd == "cd '/Users/me/my app' && claude")
        #expect(SessionNaming.projectPath(from: cmd) == "/Users/me/my app")
    }

    @Test("Terminal command quotes paths so the shell cannot be injected")
    func terminalCommandQuoting() {
        let cmd = SessionLaunchMode.terminalCommand(cwd: "/Users/me/it's; rm -rf ~")
        #expect(cmd == "cd '/Users/me/it'\\''s; rm -rf ~' && claude")
    }

    @Test("Terminal command passes the task to claude, quoted literally")
    func terminalPromptIsShellQuoted() {
        #expect(SessionLaunchMode.terminalCommand(cwd: "/u/it's", prompt: #"fix "$HOME" now"#)
                == #"cd '/u/it'\''s' && claude 'fix "$HOME" now'"#)
        #expect(SessionLaunchMode.terminalCommand(cwd: nil, prompt: "a'b") == #"claude 'a'\''b'"#)
        #expect(SessionLaunchMode.terminalCommand(cwd: "/u/api", prompt: nil) == "cd '/u/api' && claude")
    }

    @Test("A prompt keeps the project path readable for session naming")
    func promptKeepsProjectPath() {
        let cmd = SessionLaunchMode.terminalCommand(cwd: "/u/api", prompt: "почини тесты")
        #expect(SessionNaming.projectPath(from: cmd) == "/u/api")
    }
}
