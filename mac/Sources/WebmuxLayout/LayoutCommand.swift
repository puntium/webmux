// Commands by name (app.js PANE_COMMANDS; the shell's keymap and menu).
// Port of the `Command` enum in gtk/ghostty/src/webmux/layout/Layout.zig.

import Foundation

public enum LayoutCommand: String, Sendable, Equatable, CaseIterable {
    case newTerminal = "new-terminal"
    case newFiles = "new-files"
    case newTerminalBelow = "new-terminal-below"
    case closePane = "close-pane"
    case toggleFull = "toggle-full"
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case focusUp = "focus-up"
    case focusDown = "focus-down"
    case moveColumnLeft = "move-column-left"
    case moveColumnRight = "move-column-right"
    case movePaneUp = "move-pane-up"
    case movePaneDown = "move-pane-down"
    case consumeExpelLeft = "consume-expel-left"
    case consumeExpelRight = "consume-expel-right"

    /// The app.js name: `new-terminal`, `focus-left`, …
    public var name: String { rawValue }

    public init?(name: String) {
        self.init(rawValue: name)
    }

    /// The commands the shell carries out itself, because they need the
    /// server first (a new session id) or after (killing the session):
    /// newTerminal → `Layout.newTerminal`, newTerminalBelow →
    /// `Layout.newTerminalBelow`, newFiles → `Layout.newFiles`, closePane →
    /// `Layout.remove(focused)`.
    public var needsShell: Bool {
        switch self {
        case .newTerminal, .newFiles, .newTerminalBelow, .closePane: return true
        default: return false
        }
    }
}

extension Layout {
    /// Run one of the pure layout commands (`!cmd.needsShell`); returns
    /// whether anything changed (for the focus commands: whether focus
    /// moved). The shell-side commands return false without doing anything.
    @discardableResult
    public mutating func run(_ cmd: LayoutCommand) -> Bool {
        switch cmd {
        case .newTerminal, .newFiles, .newTerminalBelow, .closePane: return false
        case .toggleFull: return toggleFull()
        case .focusLeft: return focus(.left)
        case .focusRight: return focus(.right)
        case .focusUp: return focus(.up)
        case .focusDown: return focus(.down)
        case .moveColumnLeft: return moveColumn(.left)
        case .moveColumnRight: return moveColumn(.right)
        case .movePaneUp: return movePane(.up)
        case .movePaneDown: return movePane(.down)
        case .consumeExpelLeft: return consumeOrExpel(.left)
        case .consumeExpelRight: return consumeOrExpel(.right)
        }
    }
}
