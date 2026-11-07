// The Ghostty configuration webmux.app runs with. Mirrors
// gtk/ghostty/src/apprt/webmux/config.zig (the GTK client), which reproduces the
// Electron client's xterm.js setup (PARITY T-01...T-10):
//
//   electron/ui/app.js      `new Terminal({cursorBlink: true, fontSize: 13,
//                           scrollback: 5000, fontFamily: TERM_FONT})`
//   electron/ui/settings.js THEMES.dark / THEMES.light (`xterm` palettes)
//   electron/ui/index.html  `.term-holder { padding: 4px }`, JetBrainsMono Nerd Font
//
// The app never reads ~/.config/ghostty: `Ghostty.Config(text:)` loads this text and
// nothing else. Theme switching is `Ghostty.App.apply(theme:)` (TerminalTheme.swift).
//
// Differences from the GTK file, all because macOS points are CSS pixels at 1x:
// `font-size = 13` (the GTK file has 9.75 pt for 13 px at 96 dpi), padding 4 pt
// (GTK: 3 pt), no `adjust-cell-width` (GTK trims one pixel to match xterm.js's
// floor() at 96 dpi; measured on this Mac the cell is 8 pt wide for 13 pt JetBrains
// Mono, which xterm.js floors to the same 8 CSS px, so nothing to trim), and the
// Linux-only `gtk-single-instance` line is gone. `working-directory` and
// `shell-integration` are irrelevant (the shell runs on the remote host) and kept
// only so the two files diff cleanly.
//
// What the GTK client sets in Zig after `finalize` and this file cannot express:
// the URL link highlighted on *hover without a modifier* and matched with
// xterm.js's regex (T-24/T-25). Ghostty's `link` key has no file syntax
// (`RepeatableLink.parseCLI` is NotImplemented) and the default link needs ⌘ for
// hover and click. Until the fork exports a `ghostty_config_webmux_links()` the
// pane detects URLs itself for clicks (TerminalLinks.swift) and the underline on
// hover needs ⌘ (see docs/macos-client.md deviations).
import Foundation

public enum TerminalConfig {
    /// The terminal colour scheme (Electron: settings.theme). Kept as a name for
    /// `TerminalTheme`, which is the type the rest of the app uses.
    public typealias Scheme = TerminalTheme

    /// The font size in points (T-01: 13 px, which is 13 pt on macOS).
    public static let fontSize: Float = 13

    /// Padding around the grid, in points (T-09: 4 px on all sides). The pane's
    /// hit-testing (TerminalLinks) uses the same constant, so the two never drift.
    public static let padding: CGFloat = 4

    /// Bindings handed to the Ghostty core: none. The shell owns every chord and
    /// the terminal pane implements its own keys (copy, the paste variants),
    /// because they need the Electron client's logic, not Ghostty's.
    static let terminalKeybinds = ""

    static let common = """
    # JetBrains Mono is Ghostty's built-in default font (with the Nerd Font symbols
    # as fallback), the same glyphs the Electron client bundles, so font-family
    # stays unset.
    font-size = 13
    cursor-style = block
    cursor-style-blink = true
    # Ghostty trims whole pages, so ask for more than the 5000 lines xterm
    # keeps to never keep fewer (T-03).
    scrollback-limit-lines = 5600
    bold-color = bright
    # 4 px of padding around the grid (T-09).
    window-padding-x = 4
    window-padding-y = 4
    window-padding-balance = false
    window-padding-color = background
    # Typing snaps the viewport to the bottom (T-17); output does not yank a
    # reader back down (T-29).
    scroll-to-bottom = keystroke,no-output

    # The pane is a plain terminal; nothing Ghostty-specific leaks into it.
    shell-integration = none
    working-directory = ~/
    confirm-close-surface = false
    quit-after-last-window-closed = true
    # Alt+click is xterm's arrow-key cursor move (T-20), not Ghostty's
    # prompt-mark jump (which needs shell integration we do not have).
    cursor-click-to-move = false

    # Clipboard as in the Electron client: OSC 52 writes land on the
    # clipboard, OSC 52 reads are ignored, pastes are not second-guessed
    # (there is no confirmation dialog in this shell), no copy-on-select.
    clipboard-write = allow
    clipboard-read = deny
    clipboard-paste-protection = false
    copy-on-select = none
    right-click-action = ignore
    # xterm.js word separators: space and ()[]{}',"` (PARITY T-18).
    selection-word-chars = " ()[]{}',\\"`"
    # macOS: option is alt for the terminal (ESC prefix), as in the Electron
    # client (T-12).
    macos-option-as-alt = true

    keybind = clear

    """

    /// THEMES.dark: xterm.js's stock palette on the panel colour (T-05). The
    /// selection colour is xterm's rgba(255,255,255,0.3) blended onto #1f1f2b.
    static let dark = """
    background = #1f1f2b
    foreground = #ffffff
    cursor-color = #ffffff
    cursor-text = #000000
    selection-background = #62626b
    selection-foreground = cell-foreground
    palette = 0=#2e3436
    palette = 1=#cc0000
    palette = 2=#4e9a06
    palette = 3=#c4a000
    palette = 4=#3465a4
    palette = 5=#75507b
    palette = 6=#06989a
    palette = 7=#d3d7cf
    palette = 8=#555753
    palette = 9=#ef2929
    palette = 10=#8ae234
    palette = 11=#fce94f
    palette = 12=#729fcf
    palette = 13=#ad7fa8
    palette = 14=#34e2e2
    palette = 15=#eeeeec

    """

    /// THEMES.light (T-06). Selection: rgba(46,125,233,0.25) blended onto #f4f5f9.
    static let light = """
    background = #f4f5f9
    foreground = #343b58
    cursor-color = #343b58
    cursor-text = #f4f5f9
    selection-background = #c2d7f5
    selection-foreground = cell-foreground
    palette = 0=#3b3e4d
    palette = 1=#c8283f
    palette = 2=#587539
    palette = 3=#8c6c3e
    palette = 4=#2e7de9
    palette = 5=#9854f1
    palette = 6=#007197
    palette = 7=#7d84a3
    palette = 8=#6a6f87
    palette = 9=#f52a65
    palette = 10=#4d8a2f
    palette = 11=#a5772a
    palette = 12=#1c5fc4
    palette = 13=#7c3de0
    palette = 14=#0a8fb5
    palette = 15=#343b58

    """

    /// The config text for a theme, in Ghostty's config-file syntax.
    public static func text(_ theme: TerminalTheme) -> String {
        switch theme {
        case .dark: return common + terminalKeybinds + dark
        case .light: return common + terminalKeybinds + light
        }
    }

    /// The parsed, finalized configuration for a theme.
    public static func config(_ theme: TerminalTheme) -> Ghostty.Config {
        Ghostty.Config(text: text(theme))
    }
}
