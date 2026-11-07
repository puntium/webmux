import XCTest
import GhosttyKit
@testable import WebmuxTerminal

/// The built-in Ghostty configuration (PARITY T-01...T-10) parses cleanly and
/// carries the Electron defaults.
final class TerminalConfigTests: XCTestCase {
    private static var initialized = false

    override func setUp() {
        super.setUp()
        // The config C API needs Ghostty's global state; once per process.
        if !Self.initialized {
            XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), GHOSTTY_SUCCESS)
            Self.initialized = true
        }
    }

    func testTextCarriesTheElectronDefaults() {
        for scheme in TerminalConfig.Scheme.allCases {
            let text = TerminalConfig.text(scheme)
            XCTAssertTrue(text.contains("font-size = 13\n"), "T-01")
            XCTAssertTrue(text.contains("scrollback-limit-lines = 5600\n"), "T-03")
            XCTAssertTrue(text.contains("cursor-style = block\n"), "T-04")
            XCTAssertTrue(text.contains("cursor-style-blink = true\n"), "T-04")
            XCTAssertTrue(text.contains("bold-color = bright\n"), "T-08")
            XCTAssertTrue(text.contains("keybind = clear\n"))
            XCTAssertTrue(text.contains("window-padding-x = 4\n"), "T-09")
            XCTAssertTrue(text.contains("macos-option-as-alt = true\n"), "T-12")
            XCTAssertTrue(text.contains("scroll-to-bottom = keystroke,no-output\n"), "T-17/T-29")
            XCTAssertTrue(text.contains("right-click-action = ignore\n"), "T-23")
            XCTAssertTrue(text.contains("clipboard-paste-protection = false\n"))
            XCTAssertFalse(text.contains("config-file"), "the app never reads config files")
        }
        XCTAssertTrue(TerminalConfig.text(.dark).contains("background = #1f1f2b\n"), "T-05")
        XCTAssertTrue(TerminalConfig.text(.dark).contains("palette = 15=#eeeeec\n"), "T-05")
        XCTAssertTrue(TerminalConfig.text(.light).contains("background = #f4f5f9\n"), "T-06")
        XCTAssertTrue(TerminalConfig.text(.light).contains("palette = 15=#343b58\n"), "T-06")
    }

    func testBothSchemesParseWithoutDiagnostics() {
        for scheme in TerminalConfig.Scheme.allCases {
            let config = TerminalConfig.config(scheme)
            XCTAssertTrue(config.loaded, "\(scheme)")
            XCTAssertEqual(config.errors, [], "\(scheme)")
            XCTAssertEqual(config.fontSize, 13, "\(scheme)")
            XCTAssertTrue(config.shouldQuitAfterLastWindowClosed)
        }
    }

    func testThemeFromSettings() {
        XCTAssertEqual(TerminalTheme(settingsValue: "light"), .light)
        XCTAssertEqual(TerminalTheme(settingsValue: "dark"), .dark)
        XCTAssertEqual(TerminalTheme(settingsValue: "solarized"), .dark, "A-12: unknown ids fall back to dark")
        XCTAssertEqual(TerminalTheme(settingsValue: nil), .dark)
        XCTAssertEqual(TerminalTheme.light.background.usingColorSpace(.deviceRGB)?.hexString, "#F4F5F9")
    }

    func testSchemeBackgrounds() {
        let dark = TerminalConfig.config(.dark).backgroundColor.usingColorSpace(.deviceRGB)
        XCTAssertEqual(dark?.hexString, "#1F1F2B")
        let light = TerminalConfig.config(.light).backgroundColor.usingColorSpace(.deviceRGB)
        XCTAssertEqual(light?.hexString, "#F4F5F9")
        XCTAssertEqual(TerminalConfig.config(.light).foregroundColor.usingColorSpace(.deviceRGB)?.hexString, "#343B58")
    }
}
