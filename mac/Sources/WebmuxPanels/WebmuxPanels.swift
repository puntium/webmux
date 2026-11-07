// WebmuxPanels: the app's native chrome around the workspace — the Connections
// window, the Settings window, the Connection Log window, the status HUD, the
// link chooser and the About panel (docs/macos-client.md › Idiomatic macOS;
// PARITY §§ 7 (UI items), 9–12; reference: gtk/ghostty/src/apprt/webmux/panels
// and chrome/page.zig, with docs/native-client.md deviations 23, 25, 27, 31,
// 32, 34, 66, 67, 68 as precedent for "native, not copied").
//
// Everything here is AppKit on the main thread (`@MainActor`). Engine events
// and log entries arrive on engine threads; the app hops them to the main
// queue and calls the controllers' `apply…` methods. The pure parts (status
// mapping, the profile form model, the log filter, the menu table, the HUD
// timer, URL kinds) have no AppKit dependency and are unit-tested.
import AppKit
import WebmuxConnection

/// The app's logger subsystem and category for this area.
let panelsLogSubsystem = "me.puntium.webmux.mac"

/// Notifications the panels post; the terminal/workspace areas observe them.
public enum PanelNotification {
    /// The colour scheme changed. `userInfo[appearanceKey]` is the
    /// `Appearance.rawValue` (`system`, `dark`, `light`) and
    /// `userInfo[schemeKey]` the resolved terminal scheme (`dark` or `light`).
    public static let themeChange = Notification.Name("me.puntium.webmux.mac.themeChange")
    /// The unfocused-pane fade changed (live preview while the slider moves,
    /// then the saved value). `userInfo[fadeKey]` is an `Int` 0…100.
    public static let fadeChange = Notification.Name("me.puntium.webmux.mac.fadeChange")
    public static let appearanceKey = "appearance"
    public static let schemeKey = "scheme"
    public static let fadeKey = "fade"
}

/// The Settings window's colour-scheme choice (PARITY E-01 plus the Mac's
/// `system`, which follows the desktop). Stored as `Settings.theme`.
public enum Appearance: String, CaseIterable, Sendable {
    case system
    case dark
    case light

    /// settings.js: unknown ids render as dark.
    public init(theme: String) {
        self = Appearance(rawValue: theme) ?? .dark
    }

    /// The label the popup shows (E-01's labels for the two Electron themes).
    public var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// `NSApp.appearance` for this choice: nil follows the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    /// Which terminal palette this resolves to (T-05/T-06), given whether
    /// the system is currently dark.
    public func scheme(systemIsDark: Bool) -> String {
        switch self {
        case .system: return systemIsDark ? "dark" : "light"
        case .dark: return "dark"
        case .light: return "light"
        }
    }
}

/// Applies the appearance to the app and tells the other areas.
@MainActor
public enum ThemeController {
    /// Whether the effective system appearance is dark right now.
    public static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Set `NSApp.appearance` and post `PanelNotification.themeChange`.
    public static func apply(_ appearance: Appearance) {
        NSApp.appearance = appearance.nsAppearance
        let scheme = appearance.scheme(systemIsDark: systemIsDark)
        NotificationCenter.default.post(name: PanelNotification.themeChange, object: nil, userInfo: [
            PanelNotification.appearanceKey: appearance.rawValue,
            PanelNotification.schemeKey: scheme,
        ])
    }

    /// Post `PanelNotification.fadeChange`.
    public static func applyFade(_ fade: Int) {
        NotificationCenter.default.post(name: PanelNotification.fadeChange, object: nil, userInfo: [PanelNotification.fadeKey: fade])
    }
}

/// The standard About panel (W-41 "About").
@MainActor
public enum AboutPanel {
    public static func show(engineVersion: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.1"
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "webmux",
            .applicationVersion: version,
            .version: "GhosttyKit \(engineVersion)",
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        options[.credits] = NSAttributedString(
            string: "A native macOS client for webmux. Terminal engine: Ghostty (MIT).",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

/// The panels' window class: Escape closes the window (G-28 for the log; the
/// Mac convention for the others). `cancelOperation` reaches the window
/// through the key-binding chain whatever the first responder is; the window
/// controller is not on that chain.
@MainActor
final class PanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Views that do not run the key-binding path (a table, a popup) let an
    /// unhandled key fall through to the window.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}
