// The pane chords (PARITY § 5, macOS column: ⌘-based, secondary ⌥) as a
// table the workspace matches key events against and the app builds menu
// items from. One entry per `LayoutCommand`, with a primary key equivalent
// (what the menu shows) and alternates (K-06…K-09 letters next to arrows,
// K-14/K-15's ⇧⌘ variants).
//
// Matching (K-16, K-17): ⌘ held, ⌃ not held; the exact ⇧/⌥ set of a binding;
// letters and brackets by physical key (`keyCode`) so layouts and ⇧ do not
// change them, with the key's characters as a fallback for synthetic events;
// arrows and Return by key. Anything outside the table is not a chord and is
// not swallowed.
import AppKit
import Carbon.HIToolbox
import WebmuxLayout

public struct KeyChord: Equatable, Sendable {
    /// `NSMenuItem.keyEquivalent`: a character, "\r", or an arrow function key.
    public let key: String
    /// Only `.command`, `.shift`, `.option` matter.
    public let modifiers: NSEvent.ModifierFlags
    /// Physical keys that mean `key` (nil: match by character only).
    let keyCodes: [UInt16]

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags, codes: [UInt16] = []) {
        self.key = key
        self.modifiers = modifiers
        self.keyCodes = codes
    }

    /// A readable form (⌥⌘↩), for tooltips and logs.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case "\r": s += "↩"
        case KeyChord.upArrow: s += "↑"
        case KeyChord.downArrow: s += "↓"
        case KeyChord.leftArrow: s += "←"
        case KeyChord.rightArrow: s += "→"
        default: s += key.uppercased()
        }
        return s
    }

    static let upArrow = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey)).map { Character($0) } ?? "↑")
    static let downArrow = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey)).map { Character($0) } ?? "↓")
    static let leftArrow = String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey)).map { Character($0) } ?? "←")
    static let rightArrow = String(UnicodeScalar(UInt32(NSRightArrowFunctionKey)).map { Character($0) } ?? "→")
}

public struct WorkspaceCommand: Sendable {
    public let command: LayoutCommand
    /// PARITY id (K-01…).
    public let parityId: String
    public let menuTitle: String
    public let primary: KeyChord
    public let alternates: [KeyChord]

    public var chords: [KeyChord] { [primary] + alternates }

    /// The modifier flags a chord compares (fn, numeric pad and caps lock are
    /// ignored: arrows carry them).
    static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private static let cmd: NSEvent.ModifierFlags = [.command]
    private static let optCmd: NSEvent.ModifierFlags = [.command, .option]
    private static let shiftCmd: NSEvent.ModifierFlags = [.command, .shift]

    private static func letter(_ c: String, _ code: Int, _ mods: NSEvent.ModifierFlags) -> KeyChord {
        KeyChord(c, mods, codes: [UInt16(code)])
    }

    /// The table (PARITY § 5, macOS column).
    public static let all: [WorkspaceCommand] = [
        WorkspaceCommand(command: .newTerminal, parityId: "K-01", menuTitle: "New Terminal",
                         primary: KeyChord("\r", cmd, codes: [UInt16(kVK_Return)]), alternates: []),
        WorkspaceCommand(command: .newTerminalBelow, parityId: "K-02", menuTitle: "New Terminal Below",
                         primary: KeyChord("\r", optCmd, codes: [UInt16(kVK_Return)]), alternates: []),
        WorkspaceCommand(command: .newFiles, parityId: "K-03", menuTitle: "New File Browser",
                         primary: KeyChord("\r", shiftCmd, codes: [UInt16(kVK_Return)]), alternates: []),
        WorkspaceCommand(command: .closePane, parityId: "K-04", menuTitle: "Close Pane",
                         primary: letter("w", kVK_ANSI_W, cmd), alternates: []),
        WorkspaceCommand(command: .toggleFull, parityId: "K-05", menuTitle: "Toggle Full Width",
                         primary: letter("f", kVK_ANSI_F, cmd), alternates: []),
        WorkspaceCommand(command: .focusLeft, parityId: "K-06", menuTitle: "Focus Left",
                         primary: KeyChord(KeyChord.leftArrow, cmd, codes: [UInt16(kVK_LeftArrow)]), alternates: [letter("h", kVK_ANSI_H, cmd)]),
        WorkspaceCommand(command: .focusRight, parityId: "K-07", menuTitle: "Focus Right",
                         primary: KeyChord(KeyChord.rightArrow, cmd, codes: [UInt16(kVK_RightArrow)]), alternates: [letter("l", kVK_ANSI_L, cmd)]),
        WorkspaceCommand(command: .focusUp, parityId: "K-08", menuTitle: "Focus Up",
                         primary: KeyChord(KeyChord.upArrow, cmd, codes: [UInt16(kVK_UpArrow)]), alternates: [letter("k", kVK_ANSI_K, cmd)]),
        WorkspaceCommand(command: .focusDown, parityId: "K-09", menuTitle: "Focus Down",
                         primary: KeyChord(KeyChord.downArrow, cmd, codes: [UInt16(kVK_DownArrow)]), alternates: [letter("j", kVK_ANSI_J, cmd)]),
        WorkspaceCommand(command: .consumeExpelLeft, parityId: "K-10", menuTitle: "Consume or Expel Left",
                         primary: letter("[", kVK_ANSI_LeftBracket, cmd), alternates: []),
        WorkspaceCommand(command: .consumeExpelRight, parityId: "K-11", menuTitle: "Consume or Expel Right",
                         primary: letter("]", kVK_ANSI_RightBracket, cmd), alternates: []),
        WorkspaceCommand(command: .moveColumnLeft, parityId: "K-12", menuTitle: "Move Column Left",
                         primary: KeyChord(KeyChord.leftArrow, optCmd, codes: [UInt16(kVK_LeftArrow)]), alternates: [letter("h", kVK_ANSI_H, optCmd)]),
        WorkspaceCommand(command: .moveColumnRight, parityId: "K-13", menuTitle: "Move Column Right",
                         primary: KeyChord(KeyChord.rightArrow, optCmd, codes: [UInt16(kVK_RightArrow)]), alternates: [letter("l", kVK_ANSI_L, optCmd)]),
        WorkspaceCommand(command: .movePaneUp, parityId: "K-14", menuTitle: "Move Pane Up",
                         primary: KeyChord(KeyChord.upArrow, optCmd, codes: [UInt16(kVK_UpArrow)]),
                         alternates: [letter("k", kVK_ANSI_K, optCmd), KeyChord(KeyChord.upArrow, shiftCmd, codes: [UInt16(kVK_UpArrow)]), letter("k", kVK_ANSI_K, shiftCmd)]),
        WorkspaceCommand(command: .movePaneDown, parityId: "K-15", menuTitle: "Move Pane Down",
                         primary: KeyChord(KeyChord.downArrow, optCmd, codes: [UInt16(kVK_DownArrow)]),
                         alternates: [letter("j", kVK_ANSI_J, optCmd), KeyChord(KeyChord.downArrow, shiftCmd, codes: [UInt16(kVK_DownArrow)]), letter("j", kVK_ANSI_J, shiftCmd)]),
    ]

    public static func entry(for command: LayoutCommand) -> WorkspaceCommand? {
        all.first { $0.command == command }
    }

    /// The command a key event is a chord for, or nil (K-16, K-17).
    public static func match(_ event: NSEvent) -> LayoutCommand? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(relevantFlags)
        guard flags.contains(.command), !flags.contains(.control) else { return nil }
        let code = event.keyCode
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        for c in all {
            for chord in c.chords where chord.modifiers == flags {
                if !chord.keyCodes.isEmpty, chord.keyCodes.contains(code) { return c.command }
                if !chars.isEmpty, chars == chord.key.lowercased() { return c.command }
            }
        }
        return nil
    }

    /// A menu item for this command: `target`/`action` are the app's (the
    /// action receives the item; `representedObject` is the `LayoutCommand`
    /// name). The key equivalent is informational: the workspace consumes
    /// the chord in `performKeyEquivalent` before the menu sees it (T-15).
    public func menuItem(target: AnyObject?, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: menuTitle, action: action, keyEquivalent: primary.key)
        item.keyEquivalentModifierMask = primary.modifiers
        item.target = target
        item.representedObject = command.name
        return item
    }
}
