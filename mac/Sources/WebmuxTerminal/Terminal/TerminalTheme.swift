// The two terminal palettes (PARITY T-05, T-06) and switching between them at
// run time (T-07): `Ghostty.App.apply(theme:)` hands the core a new configuration,
// which repaints every open surface in place; nothing is reopened and scrollback
// and selection survive (verified by LiveTerminalTests.testThemeSwitchKeepsText).
import AppKit
import GhosttyKit

/// The terminal colour scheme (Electron: settings.theme; ruling A-12: unknown
/// ids fall back to dark).
public enum TerminalTheme: String, CaseIterable, Sendable {
    case dark
    case light

    /// Parse a settings value; anything unknown is dark (A-12).
    public init(settingsValue: String?) {
        self = settingsValue.flatMap(TerminalTheme.init(rawValue:)) ?? .dark
    }

    /// The theme the Ghostty app currently runs with (set by `apply(theme:)`).
    @MainActor public private(set) static var current: TerminalTheme = .dark

    /// The pane panel colour, the terminal background (T-05/T-06).
    public var background: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 0x1f / 255, green: 0x1f / 255, blue: 0x2b / 255, alpha: 1)
        case .light: return NSColor(srgbRed: 0xf4 / 255, green: 0xf5 / 255, blue: 0xf9 / 255, alpha: 1)
        }
    }

    /// The scrollbar thumb (T-10): rgba(200,200,216,0.22) / rgba(52,59,88,0.25).
    public var scrollbarThumb: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 200 / 255, green: 200 / 255, blue: 216 / 255, alpha: 0.22)
        case .light: return NSColor(srgbRed: 52 / 255, green: 59 / 255, blue: 88 / 255, alpha: 0.25)
        }
    }

    /// The scrollbar thumb under the pointer (T-10): alpha 0.4 / 0.45.
    public var scrollbarThumbHover: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 200 / 255, green: 200 / 255, blue: 216 / 255, alpha: 0.4)
        case .light: return NSColor(srgbRed: 52 / 255, green: 59 / 255, blue: 88 / 255, alpha: 0.45)
        }
    }

    @MainActor static func setCurrent(_ theme: TerminalTheme) {
        current = theme
    }
}

extension Notification.Name {
    /// Posted on the main queue after `Ghostty.App.apply(theme:)`; `object` is
    /// the `Ghostty.App`, userInfo[TerminalThemeKey] the `TerminalTheme`.
    public static let webmuxTerminalThemeDidChange = Notification.Name("me.puntium.webmux.mac.terminalThemeDidChange")
    public static let TerminalThemeKey = webmuxTerminalThemeDidChange.rawValue
}

extension Ghostty.App {
    /// Switch every open terminal to `theme` (T-07). Builds the configuration
    /// from `TerminalConfig.text`, hands it to the core (`ghostty_app_update_config`
    /// pushes a derived copy to each surface's renderer and IO thread, so the
    /// screen, scrollback and selection stay) and records it as the current theme.
    /// Returns false if the configuration failed to parse (a bug in the text).
    @MainActor
    @discardableResult
    public func apply(theme: TerminalTheme) -> Bool {
        let config = TerminalConfig.config(theme)
        guard config.loaded else { return false }
        update(config: config)
        TerminalTheme.setCurrent(theme)
        NotificationCenter.default.post(
            name: .webmuxTerminalThemeDidChange,
            object: self,
            userInfo: [Notification.Name.TerminalThemeKey: theme])
        return true
    }
}
