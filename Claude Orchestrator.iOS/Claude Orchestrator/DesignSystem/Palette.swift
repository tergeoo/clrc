import SwiftUI
import UIKit
import ClrcCore

/// The 2.0 palette (docs/design/2.0.0, Inbox mockup). Every color follows
/// the system light/dark appearance except `code`, which is always dark.
enum Palette {
    static let bg = dynamic(light: 0xF2F2F7, dark: 0x000000)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let text = dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let sec = dynamic(light: 0x3C3C43, dark: 0xC7C7CC)
    static let meta = dynamic(light: 0x6C6C70, dark: 0x8E8E93)
    static let fill = dynamic(light: 0xE5E5EA, dark: 0x2C2C2E)
    static let tint = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let tintSoft = dynamic(light: 0xE3EEFF, dark: 0x0A2A4D)
    static let green = dynamic(light: 0x248A3D, dark: 0x30D158)
    static let orange = dynamic(light: 0xC93400, dark: 0xFF9F0A)
    static let red = dynamic(light: 0xD70015, dark: 0xFF453A)
    static let blue = Color(hex: 0x007AFF)
    /// Code, diff and terminal surfaces: dark in both themes.
    static let code = Color(hex: 0x1C1C21)

    static func status(_ status: SessionStatus) -> Color {
        switch status {
        case .needsInput: return orange
        case .failed: return red
        case .working: return blue
        case .done: return green
        case .idle: return meta
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}
