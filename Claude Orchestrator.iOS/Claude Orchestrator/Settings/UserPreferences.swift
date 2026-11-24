import Foundation
import ClrcCore

/// Settings other screens read, with their UserDefaults keys.
enum UserPreferences {
    static let quickRepliesKey = "quick_replies"
    static let templatesKey = "task_templates"
    static let terminalFontKey = "terminal_font_size"
    static let fileWrapKey = "file_wrap"

    static var quickReplies: [String] {
        StoredList.decode(UserDefaults.standard.string(forKey: quickRepliesKey), defaults: QuickReplies.permanent)
    }

    static var templates: [String] {
        StoredList.decode(UserDefaults.standard.string(forKey: templatesKey), defaults: NewTaskPlanner.templates)
    }

    /// Starting size for new terminals.
    static var terminalFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: terminalFontKey)
        return stored > 0 ? TerminalFont.clamped(stored) : TerminalFont.defaultSize
    }

    static var fileWrap: Bool {
        UserDefaults.standard.object(forKey: fileWrapKey) as? Bool ?? true
    }
}
