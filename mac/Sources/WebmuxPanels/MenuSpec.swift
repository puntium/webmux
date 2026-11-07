// The menu bar as data (PARITY W-41…W-45, macOS column; the pane chords and
// app shortcuts of § 5). The app builds `NSMenu`s from this table and maps
// each `MenuCommand` to a selector; the table itself is unit-tested against
// PARITY so the key equivalents cannot drift.
import AppKit

/// Every command a menu item can run.
public enum MenuCommand: String, CaseIterable, Sendable {
    // webmux menu (W-41)
    case about, connections, reconnect, openConfigFile, connectionLog, settings, hide, hideOthers, showAll, quit
    // Edit (W-42): the standard roles
    case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
    // View (W-43, K-31): on the visible host's workspace
    case reload, actualSize, zoomIn, zoomOut, toggleFullScreen
    // Pane (W-44, K-01…K-15): on the focused workspace
    case newTerminal, newTerminalBelow, newFileBrowser, closePane, toggleFullWindow
    case focusLeft, focusRight, focusUp, focusDown
    case consumeExpelLeft, consumeExpelRight
    case moveColumnLeft, moveColumnRight, movePaneUp, movePaneDown
    // Window (W-45, K-24…K-26)
    case minimize, zoom, previousHost, nextHost
    case host1, host2, host3, host4, host5, host6, host7, host8, host9
    case bringAllToFront
    // Help
    case help

    /// The pane commands: items whose action travels the responder chain to
    /// the workspace (`PaneCommandTarget`); disabled while nothing implements it.
    public var isPaneCommand: Bool {
        switch self {
        case .reload, .actualSize, .zoomIn, .zoomOut,
             .newTerminal, .newTerminalBelow, .newFileBrowser, .closePane, .toggleFullWindow,
             .focusLeft, .focusRight, .focusUp, .focusDown, .consumeExpelLeft, .consumeExpelRight,
             .moveColumnLeft, .moveColumnRight, .movePaneUp, .movePaneDown:
            return true
        default:
            return false
        }
    }

    /// `host1`…`host9` → 1…9 (K-24).
    public var hostIndex: Int? {
        guard rawValue.hasPrefix("host"), let n = Int(rawValue.dropFirst(4)) else { return nil }
        return n
    }
}

public struct MenuItemSpec: Equatable, Sendable {
    public var title: String
    /// `NSMenuItem.keyEquivalent` ("" = none; "\r" = Return).
    public var key: String
    public var mods: NSEvent.ModifierFlags
    /// nil = separator.
    public var command: MenuCommand?

    public static let separator = MenuItemSpec(title: "", key: "", mods: [], command: nil)

    public init(title: String, key: String, mods: NSEvent.ModifierFlags, command: MenuCommand?) {
        self.title = title
        self.key = key
        self.mods = mods
        self.command = command
    }

    static func item(_ title: String, _ command: MenuCommand, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> MenuItemSpec {
        MenuItemSpec(title: title, key: key, mods: key.isEmpty ? [] : (mods.isEmpty ? [.command] : mods), command: command)
    }

    public var isSeparator: Bool { command == nil }

    /// The shortcut as PARITY writes it (⌃⌥⇧⌘ + key), "" for none.
    public var shortcutText: String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key {
        case "\r": s += "↩"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): s += "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): s += "→"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): s += "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): s += "↓"
        default: s += key.uppercased()
        }
        return s
    }
}

public struct MenuSpec: Equatable, Sendable {
    public var title: String
    public var items: [MenuItemSpec]

    public init(title: String, items: [MenuItemSpec]) {
        self.title = title
        self.items = items
    }

    static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    static let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    static let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    static let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    /// The menu bar, in order. Hide / Hide Others / Show All have no
    /// accelerators (⌘H and ⌥⌘H are pane chords, W-41). There is no
    /// window-close item (W-07, W-45).
    public static let menuBar: [MenuSpec] = [
        MenuSpec(title: "webmux", items: [
            .item("About webmux", .about),
            .separator,
            .item("Connections…", .connections, "O", [.command, .shift]),
            .item("Reconnect", .reconnect, "R", [.command, .shift]),
            .item("Open Config File", .openConfigFile),
            .item("Connection Log…", .connectionLog, "l", [.command, .control]),
            .separator,
            .item("Settings…", .settings, ","),
            .separator,
            .item("Hide webmux", .hide),
            .item("Hide Others", .hideOthers),
            .item("Show All", .showAll),
            .separator,
            .item("Quit webmux", .quit, "q"),
        ]),
        MenuSpec(title: "Edit", items: [
            .item("Undo", .undo, "z"),
            .item("Redo", .redo, "Z", [.command, .shift]),
            .separator,
            .item("Cut", .cut, "x"),
            .item("Copy", .copy, "c"),
            .item("Paste", .paste, "v"),
            .item("Paste and Match Style", .pasteAndMatchStyle, "V", [.command, .option, .shift]),
            .item("Delete", .delete),
            .item("Select All", .selectAll, "a"),
        ]),
        MenuSpec(title: "View", items: [
            .item("Reload", .reload, "r"),
            .separator,
            .item("Actual Size", .actualSize, "0"),
            .item("Zoom In", .zoomIn, "="),
            .item("Zoom Out", .zoomOut, "-"),
            .separator,
            .item("Toggle Full Screen", .toggleFullScreen, "f", [.command, .control]),
        ]),
        MenuSpec(title: "Pane", items: [
            .item("New Terminal", .newTerminal, "\r"),
            .item("New Terminal Below", .newTerminalBelow, "\r", [.command, .option]),
            .item("New File Browser", .newFileBrowser, "\r", [.command, .shift]),
            .item("Close Pane", .closePane, "w"),
            .item("Full Window", .toggleFullWindow, "f"),
            .separator,
            .item("Focus Left", .focusLeft, left),
            .item("Focus Right", .focusRight, right),
            .item("Focus Up", .focusUp, up),
            .item("Focus Down", .focusDown, down),
            .separator,
            .item("Expel or Merge Left", .consumeExpelLeft, "["),
            .item("Expel or Merge Right", .consumeExpelRight, "]"),
            .separator,
            .item("Move Column Left", .moveColumnLeft, left, [.command, .option]),
            .item("Move Column Right", .moveColumnRight, right, [.command, .option]),
            .item("Move Pane Up", .movePaneUp, up, [.command, .option]),
            .item("Move Pane Down", .movePaneDown, down, [.command, .option]),
        ]),
        MenuSpec(title: "Window", items: [
            .item("Minimize", .minimize, "m"),
            .item("Zoom", .zoom),
            .separator,
            .item("Previous Host", .previousHost, "[", [.command, .shift]),
            .item("Next Host", .nextHost, "]", [.command, .shift]),
            .separator,
            .item("Host 1", .host1, "1"), .item("Host 2", .host2, "2"), .item("Host 3", .host3, "3"),
            .item("Host 4", .host4, "4"), .item("Host 5", .host5, "5"), .item("Host 6", .host6, "6"),
            .item("Host 7", .host7, "7"), .item("Host 8", .host8, "8"), .item("Host 9", .host9, "9"),
            .separator,
            .item("Bring All to Front", .bringAllToFront),
        ]),
        MenuSpec(title: "Help", items: [
            .item("webmux Help", .help),
        ]),
    ]

    /// Every non-separator item in menu-bar order.
    public static var allItems: [MenuItemSpec] { menuBar.flatMap { $0.items }.filter { !$0.isSeparator } }

    public static func item(for command: MenuCommand) -> MenuItemSpec? {
        allItems.first { $0.command == command }
    }
}
