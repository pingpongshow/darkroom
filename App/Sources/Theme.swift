import SwiftUI
import AppKit

/// Lightroom-style neutral palette. Neutral greys keep colours in photos unbiased; every colour
/// adapts between DarkRoom's dark (default) and light appearance.
enum Theme {
    static let background = dynamic(dark: 0x1D1D1D, light: 0xE9E9E9)
    static let panel = dynamic(dark: 0x262626, light: 0xF4F4F4)
    static let panelRaised = dynamic(dark: 0x303030, light: 0xFFFFFF)
    static let separator = dynamic(dark: 0x3A3A3A, light: 0xCFCFCF)
    static let text = dynamic(dark: 0xD8D8D8, light: 0x222222)
    static let textSecondary = dynamic(dark: 0x9A9A9A, light: 0x5E5E5E)
    static let textTertiary = dynamic(dark: 0x6E6E6E, light: 0x8C8C8C)
    static let accent = dynamic(dark: 0xE6E6E6, light: 0x1D1D1D)
    static let highlight = Color(red: 0.36, green: 0.62, blue: 0.98)
    static let danger = Color(red: 0.92, green: 0.36, blue: 0.33)
    static let gridBackground = dynamic(dark: 0x161616, light: 0xDDDDDD)

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Immich avatar colours (UserAvatarColor).
    static func avatar(_ name: String?) -> Color {
        switch name {
        case "primary": Color(red: 0.26, green: 0.42, blue: 0.95)
        case "pink": Color(red: 0.93, green: 0.36, blue: 0.62)
        case "red": Color(red: 0.88, green: 0.27, blue: 0.27)
        case "yellow": Color(red: 0.93, green: 0.73, blue: 0.16)
        case "blue": Color(red: 0.23, green: 0.55, blue: 0.93)
        case "green": Color(red: 0.25, green: 0.70, blue: 0.40)
        case "purple": Color(red: 0.55, green: 0.36, blue: 0.86)
        case "orange": Color(red: 0.95, green: 0.52, blue: 0.20)
        case "gray": Color(white: 0.5)
        case "amber": Color(red: 0.96, green: 0.62, blue: 0.04)
        default: Color(white: 0.45)
        }
    }
}

/// User-selectable appearance (Preferences → Appearance).
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

extension View {
    /// Section header style used in side panels (Lightroom-like small caps).
    func panelHeader() -> some View {
        font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.textSecondary)
    }
}
