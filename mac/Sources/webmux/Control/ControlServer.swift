// The control socket for scripted testing (docs/macos-client.md rule 5). Enabled by
// WEBMUX_MAC_CONTROL=<unix socket path>. One JSON object per line in, one per line
// out; the protocol is documented in mac/README.md.
//
// Threads: a listener thread accepts; each connection gets a reader thread that
// parses lines and runs every command on the main queue (synchronously, so the
// reply carries the result), except `wait`, which sleeps or polls on its own
// thread so the UI keeps running.
import AppKit
import Darwin
import Foundation
import os
import WebmuxFiles
import WebmuxLayout
import WebmuxPanels
import WebmuxTerminal
import WebmuxWorkspace

final class ControlServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "control")

    enum Failure: Error, CustomStringConvertible {
        case socket(String, Int32)
        var description: String {
            switch self {
            case let .socket(what, errno): return "\(what): \(String(cString: strerror(errno)))"
            }
        }
    }

    private let path: String
    private let fd: Int32
    private weak var app: AppDelegate?
    private let stopped = NSLock()
    private var isStopped = false

    @MainActor
    init(path: String, app: AppDelegate) throws {
        self.app = app
        self.path = path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            throw Failure.socket("path longer than \(maxLen) bytes", ENAMETOOLONG)
        }
        unlink(path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                path.withCString { src in strlcpy(dst, src, maxLen + 1) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.socket("bind \(path)", e) }
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw Failure.socket("listen", e) }
        self.fd = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "webmux.control.accept"
        thread.start()
    }

    func stop() {
        stopped.lock()
        defer { stopped.unlock() }
        guard !isStopped else { return }
        isStopped = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "webmux.control.client"
            thread.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue } else { return } }
            if n == 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let reply = handle(line: line)
                var out = reply
                out.append(0x0a)
                var offset = 0
                while offset < out.count {
                    let written = out.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        return write(client, base.advanced(by: offset), out.count - offset)
                    }
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    // MARK: Commands

    private func handle(line: Data) -> Data {
        let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return encode(["ok": true]) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            return encode(["ok": false, "error": "expected {\"cmd\": ...}"])
        }

        switch cmd {
        case "wait":
            return encode(wait(obj))
        case "help":
            return encode(["ok": true, "commands": ControlCommands.help])
        default:
            var result: [String: Any] = [:]
            DispatchQueue.main.sync {
                result = MainActor.assumeIsolated {
                    guard let app = self.app else { return ["ok": false, "error": "app gone"] }
                    return ControlCommands(app: app).run(cmd, obj)
                }
            }
            return encode(result)
        }
    }

    /// `{"cmd":"wait","ms":N}` sleeps; `{"cmd":"wait","contains":"text","timeout_ms":5000}`
    /// polls the focused pane's visible text (every 50 ms) until it contains the string.
    private func wait(_ obj: [String: Any]) -> [String: Any] {
        if let contains = obj["contains"] as? String {
            let timeout = (obj["timeout_ms"] as? Double ?? 5000) / 1000
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                var text = ""
                DispatchQueue.main.sync {
                    text = MainActor.assumeIsolated {
                        self.app?.focusedTerminal?.visibleText() ?? ""
                    }
                }
                if text.contains(contains) { return ["ok": true, "found": true] }
                if Date() >= deadline { return ["ok": false, "found": false, "error": "timeout", "text": text] }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let ms = obj["ms"] as? Double ?? 100
        Thread.sleep(forTimeInterval: ms / 1000)
        return ["ok": true]
    }

    private func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"ok\":false,\"error\":\"unencodable reply\"}".utf8)
    }
}

/// The main-thread half: everything here touches AppKit.
@MainActor
struct ControlCommands {
    let app: AppDelegate

    nonisolated static let help: [String] = [
        "dump: windows (title, subtitle, kind), the main window's hosts and workspace (columns → panes: id, kind, title, cols/rows/text or directory; focused, offline), open windows, appearance, settings, hud",
        "menu {title}: perform the menu item with that title (any menu), honouring its enabled state",
        "menus: every menu item (menu, title, keyEquivalent, mods, enabled)",
        "setting {key, value}: drive the Settings window as its controls would (theme: system|dark|light; fade: 0-100)",
        "window {kind: main|connections|settings|log, action: front|close}",
        "connections {select?, fields?, press?}: drive the Connections window (press: new|save|connect|show|reconnect)",
        "key {key, mods:[cmd|shift|ctrl|alt]}: one key press through NSApp.sendEvent",
        "text {text}: type a string key by key",
        "resize {w, h}: set the window's content size in points",
        "wait {ms} | {contains, timeout_ms}",
        "screenshot {path}: PNG of the window (best effort; needs Screen Recording)",
        "quit",
    ]

    func run(_ cmd: String, _ obj: [String: Any]) -> [String: Any] {
        switch cmd {
        case "dump": return dump()
        case "menu": return menu(obj)
        case "menus": return menus()
        case "setting": return setting(obj)
        case "window": return window(obj)
        case "connections": return connections(obj)
        case "key": return key(obj)
        case "text": return text(obj)
        case "resize": return resize(obj)
        case "screenshot": return screenshot(obj)
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown cmd \(cmd)"]
        }
    }

    // MARK: dump

    private func dump() -> [String: Any] {
        var windows: [[String: Any]] = []
        var open: [String] = []
        for window in NSApp.windows where window.isVisible {
            let f = window.frame
            var w: [String: Any] = [
                "title": window.title,
                "subtitle": window.subtitle,
                "frame": ["x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height],
                "focused": window.isKeyWindow,
                "kind": kind(of: window),
                "class": window.className,
            ]
            if let controller = window.windowController as? MainWindowController {
                var panes: [[String: Any]] = []
                if let ws = controller.frontWorkspace {
                    let (workspace, flat) = describe(ws, window: window)
                    w["workspace"] = workspace
                    panes = flat
                }
                w["panes"] = panes
                w["hosts"] = controller.hostEntries.map { ["name": $0.name, "state": $0.kind.rawValue, "active": $0.active] }
                w["front"] = controller.frontView?.name as Any? ?? NSNull()
                w["landing"] = controller.isLandingShown
            }
            if let c = window.windowController as? ConnectionsWindowController {
                w["selected"] = c.selectedProfile as Any? ?? NSNull()
                w["error"] = c.currentError
                w["notice"] = c.currentNotice
                w["detail"] = c.currentDetail
                w["diagnostics"] = c.currentDiagnostics
            }
            if let l = window.windowController as? LogWindowController {
                w["lines"] = l.visibleLines
                w["entries"] = l.entryCount
            }
            if let s = window.windowController as? SettingsWindowController {
                w["appearance"] = s.selectedAppearance.rawValue
            }
            windows.append(w)
            open.append(kind(of: window))
        }
        var result: [String: Any] = [
            "ok": true,
            "windows": windows,
            "openWindows": open,
            "appearance": NSApp.effectiveAppearance.name.rawValue,
            "hud": ["text": StatusHUD.currentText as Any? ?? NSNull(), "count": StatusHUD.shownCount],
        ]
        if let s = app.engine?.settings {
            result["settings"] = ["theme": s.theme, "unfocusedFade": s.unfocusedFade, "minCols": s.minCols, "maxCols": s.maxCols]
        }
        // T-07: the palette the terminals run with, and its background.
        var terminal: [String: Any] = ["theme": TerminalTheme.current.rawValue]
        if let bg = app.ghostty?.config.backgroundColor.usingColorSpace(.sRGB) {
            terminal["background"] = String(format: "#%02x%02x%02x", Int(bg.redComponent * 255 + 0.5), Int(bg.greenComponent * 255 + 0.5), Int(bg.blueComponent * 255 + 0.5))
        }
        result["terminal"] = terminal
        return result
    }

    /// The front workspace: columns → panes, plus the flat list of the same
    /// pane objects (layout order) for the older `panes` key.
    private func describe(_ ws: WorkspaceController, window: NSWindow) -> ([String: Any], [[String: Any]]) {
        var flat: [[String: Any]] = []
        var columns: [[String: Any]] = []
        let infos = Dictionary(uniqueKeysWithValues: ws.view.paneInfos().map { ($0.id, $0) })
        for col in ws.layout.columns {
            var items: [[String: Any]] = []
            for p in col.panes {
                var d: [String: Any] = [
                    "id": p.id,
                    "kind": p.kind.rawValue,
                    "focused": ws.layout.focused == p.id,
                ]
                if let info = infos[p.id] {
                    d["title"] = info.title
                    d["box"] = ["x": info.box.x, "y": info.box.y, "w": info.box.w, "h": info.box.h]
                    d["placeholder"] = info.placeholder
                }
                switch ws.pane(id: p.id) {
                case let t as TerminalPane:
                    let grid = t.surface.grid
                    d["session"] = t.id
                    d["attached"] = t.surface.isAttached
                    d["linkUp"] = t.isLinkUp
                    d["finished"] = t.isFinished
                    d["keyboard"] = window.firstResponder === t.surface
                    d["cols"] = grid.cols
                    d["rows"] = grid.rows
                    d["text"] = t.surface.visibleText()
                    d["fade"] = t.surface.unfocusedFade
                case let f as FilesPane:
                    d["directory"] = f.files.currentDirectory
                    d["cursor"] = f.files.cursor as Any? ?? NSNull()
                    d["columns"] = f.files.columnDirectories
                    d["opened"] = f.files.isOpened
                    d["keyboard"] = window.firstResponder === f.files
                    if let names = f.files.listedNames(in: f.files.currentDirectory) { d["listed"] = names }
                    if let e = f.files.openError { d["openError"] = e }
                    if let p = f.files.previewPath { d["preview"] = p }
                default:
                    break
                }
                items.append(d)
                flat.append(d)
            }
            columns.append(["panes": items, "full": col.full])
        }
        let workspace: [String: Any] = [
            "name": ws.connection.name,
            "loaded": ws.isLoaded,
            "offline": ws.isOffline,
            "paneCount": ws.paneCount,
            "focused": ws.layout.focused as Any? ?? NSNull(),
            "columns": columns,
            "animating": ws.view.isAnimating,
            "zoom": ws.view.zoom,
            "scroll": ws.view.scroll,
        ]
        return (workspace, flat)
    }

    private func kind(of window: NSWindow) -> String {
        switch window.windowController {
        case is MainWindowController: return "main"
        case is ConnectionsWindowController: return "connections"
        case is SettingsWindowController: return "settings"
        case is LogWindowController: return "log"
        default:
            if window.isSheet { return "sheet" }
            if window is NSPanel, window.windowController == nil, window.title.isEmpty || window.title == "webmux" || window.title.hasPrefix("About") {
                return "about"
            }
            return "other"
        }
    }

    // MARK: menu / setting

    /// `{"cmd":"menu","title":"Settings…"}`: the item's action through its
    /// menu, so validation (enabled state) applies as for a click. Without a
    /// key window (the app is not active: a background launch cannot take
    /// activation on macOS 14+) AppKit would validate a nil-target item against
    /// nothing; the main window's responder chain is walked here instead, the
    /// way it would be with that window key.
    private func menu(_ obj: [String: Any]) -> [String: Any] {
        guard let title = obj["title"] as? String else { return ["ok": false, "error": "missing title"] }
        guard let item = MainMenu.item(titled: title) else { return ["ok": false, "error": "no menu item titled \(title)"] }
        guard let menu = item.menu else { return ["ok": false, "error": "item has no menu"] }
        if NSApp.keyWindow != nil {
            menu.update()
            guard item.isEnabled else { return ["ok": false, "error": "menu item \(title) is disabled", "enabled": false] }
            menu.performActionForItem(at: menu.index(of: item))
            return ["ok": true, "enabled": true, "keyEquivalent": item.keyEquivalent]
        }
        guard let action = item.action else { return ["ok": false, "error": "menu item \(title) has no action", "enabled": false] }
        guard let target = chainTarget(for: action, from: item) else {
            return ["ok": false, "error": "menu item \(title) is disabled (nothing in the chain responds)", "enabled": false]
        }
        let enabled: Bool
        if let v = target as? NSUserInterfaceValidations { enabled = v.validateUserInterfaceItem(item) }
        else if let v = target as? NSMenuItemValidation { enabled = v.validateMenuItem(item) }
        else { enabled = true }
        guard enabled else {
            return ["ok": false, "error": "menu item \(title) is disabled", "enabled": false, "target": String(describing: type(of: target))]
        }
        NSApp.sendAction(action, to: target, from: item)
        return ["ok": true, "enabled": true, "keyEquivalent": item.keyEquivalent, "target": String(describing: type(of: target))]
    }

    /// `{"cmd":"menus"}`: the menu bar as data (what the key equivalents are).
    private func menus() -> [String: Any] {
        var out: [[String: Any]] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                var mods: [String] = []
                let m = item.keyEquivalentModifierMask
                if m.contains(.function) { mods.append("fn") }
                if m.contains(.control) { mods.append("ctrl") }
                if m.contains(.option) { mods.append("alt") }
                if m.contains(.shift) { mods.append("shift") }
                if m.contains(.command) { mods.append("cmd") }
                out.append(["menu": path, "title": item.title, "keyEquivalent": item.keyEquivalent, "mods": mods,
                            "enabled": item.isEnabled, "hidden": item.isHidden])
                if let sub = item.submenu { walk(sub, path.isEmpty ? item.title : "\(path) › \(item.title)") }
            }
        }
        if let bar = NSApp.mainMenu { walk(bar, "") }
        return ["ok": true, "items": out]
    }

    /// The main window's responder chain, as AppKit walks it for a nil-target
    /// action: first responder → superviews → window → window controller →
    /// the application → its delegate.
    private func chainTarget(for action: Selector, from item: NSMenuItem) -> AnyObject? {
        if let t = item.target { return t }
        guard let window = app.mainWindow?.window else { return nil }
        var r: NSResponder? = window.firstResponder ?? window
        while let cur = r {
            if cur.responds(to: action) { return cur }
            r = cur.nextResponder
        }
        if window.responds(to: action) { return window }
        if let wc = window.windowController, wc.responds(to: action) { return wc }
        if NSApp.responds(to: action) { return NSApp }
        if let d = NSApp.delegate as? NSObject, d.responds(to: action) { return d }
        return nil
    }

    /// `{"cmd":"setting","key":"theme","value":"light"}` drives the Settings
    /// window's controls (creating the window if needed).
    private func setting(_ obj: [String: Any]) -> [String: Any] {
        guard let key = obj["key"] as? String else { return ["ok": false, "error": "missing key"] }
        guard let settings = app.settingsController() else { return ["ok": false, "error": "no engine"] }
        switch key {
        case "theme":
            guard let v = obj["value"] as? String, let a = Appearance(rawValue: v) else {
                return ["ok": false, "error": "value must be system|dark|light"]
            }
            settings.select(appearance: a)
        case "fade":
            guard let v = obj["value"] as? Double else { return ["ok": false, "error": "value must be a number"] }
            settings.setFade(Int(v))
        default:
            return ["ok": false, "error": "unknown key \(key)"]
        }
        return ["ok": true, "appearance": NSApp.effectiveAppearance.name.rawValue]
    }

    /// `{"cmd":"window","kind":"main","action":"front"}`: make a window key
    /// (and active) or close it.
    private func window(_ obj: [String: Any]) -> [String: Any] {
        guard let kindName = obj["kind"] as? String else { return ["ok": false, "error": "missing kind"] }
        guard let window = NSApp.windows.first(where: { $0.isVisible && kind(of: $0) == kindName }) else {
            return ["ok": false, "error": "no visible \(kindName) window"]
        }
        switch obj["action"] as? String ?? "front" {
        case "front":
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case "close":
            window.performClose(nil)
        default:
            return ["ok": false, "error": "action must be front|close"]
        }
        return ["ok": true]
    }

    /// `{"cmd":"connections","select":"box","fields":{…},"press":"save"}`, in
    /// that order; the reply carries the form, error and notice afterwards.
    private func connections(_ obj: [String: Any]) -> [String: Any] {
        guard let c = app.connectionsController() else { return ["ok": false, "error": "no engine"] }
        if obj["select"] != nil { c.select(name: obj["select"] as? String) }
        let press = obj["press"] as? String
        // "new" first, so fields in the same command land in the fresh form.
        if press == "new" { c.press("new") }
        if let fields = obj["fields"] as? [String: Any] {
            var strings: [String: String] = [:]
            for (k, v) in fields { strings[k] = v as? String ?? (v as? NSNumber)?.stringValue ?? "" }
            c.setForm(strings)
        }
        if let press, press != "new", !c.press(press) {
            return ["ok": false, "error": "unknown button \(press)"]
        }
        return ["ok": true, "form": c.formFields, "error": c.currentError, "notice": c.currentNotice,
                "selected": c.selectedProfile as Any? ?? NSNull(), "detail": c.currentDetail]
    }

    // MARK: key / text

    private struct Chord {
        var keyCode: UInt16
        var flags: NSEvent.ModifierFlags
    }

    private static let namedKeys: [String: Ghostty.Input.Key] = [
        "return": .enter, "enter": .enter, "escape": .escape, "esc": .escape, "tab": .tab,
        "backspace": .backspace, "delete": .backspace, "forwarddelete": .delete, "space": .space,
        "up": .arrowUp, "down": .arrowDown, "left": .arrowLeft, "right": .arrowRight,
        "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown, "insert": .insert,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
        "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
    ]

    private static func flags(_ mods: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command", "super", "meta": f.insert(.command)
            case "shift": f.insert(.shift)
            case "ctrl", "control": f.insert(.control)
            case "alt", "opt", "option": f.insert(.option)
            case "fn", "function": f.insert(.function)
            default: break
            }
        }
        return f
    }

    /// Physical key + shift for a character, through the current keyboard layout.
    private static func chord(for ch: Character) -> Chord? {
        for key in Ghostty.Input.Key.allCases {
            guard let code = key.keyCode else { continue }
            if KeyboardLayout.character(for: code, modifiers: []) == ch { return Chord(keyCode: code, flags: []) }
        }
        for key in Ghostty.Input.Key.allCases {
            guard let code = key.keyCode else { continue }
            if KeyboardLayout.character(for: code, modifiers: .shift) == ch { return Chord(keyCode: code, flags: .shift) }
        }
        return nil
    }

    private static func chord(named name: String, mods: NSEvent.ModifierFlags) -> Chord? {
        if let key = namedKeys[name.lowercased()] ?? Ghostty.Input.Key(rawValue: name), let code = key.keyCode {
            return Chord(keyCode: code, flags: mods)
        }
        guard name.count == 1, let ch = name.first, var c = chord(for: ch) else { return nil }
        c.flags.formUnion(mods)
        return c
    }

    private func key(_ obj: [String: Any]) -> [String: Any] {
        guard let name = obj["key"] as? String else { return ["ok": false, "error": "missing key"] }
        let mods = Self.flags(obj["mods"] as? [String] ?? [])
        guard let chord = Self.chord(named: name, mods: mods) else {
            return ["ok": false, "error": "cannot map key \(name) on this keyboard layout"]
        }
        guard let route = deliver(chord) else { return ["ok": false, "error": "no key window"] }
        return ["ok": true, "route": route]
    }

    private func text(_ obj: [String: Any]) -> [String: Any] {
        guard let text = obj["text"] as? String else { return ["ok": false, "error": "missing text"] }
        var typed = 0
        for ch in text {
            var chord: Chord?
            switch ch {
            case "\n", "\r": chord = Chord(keyCode: 0x24, flags: [])
            case "\t": chord = Chord(keyCode: 0x30, flags: [])
            case "\u{7f}", "\u{8}": chord = Chord(keyCode: 0x33, flags: [])
            case "\u{1b}": chord = Chord(keyCode: 0x35, flags: [])
            default:
                if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
                   scalar.value >= 1, scalar.value <= 26,
                   let letter = Unicode.Scalar(scalar.value + 96),
                   var c = Self.chord(for: Character(letter)) {
                    c.flags.insert(.control)
                    chord = c
                } else {
                    chord = Self.chord(for: ch)
                }
            }
            if let chord {
                guard deliver(chord) != nil else { return ["ok": false, "error": "no key window", "typed": typed] }
            } else {
                // Not on this keyboard layout: hand the character over as committed
                // text (the IME path), so it still arrives in order.
                guard let view = app.focusedTerminal else {
                    return ["ok": false, "error": "no terminal for \(ch)", "typed": typed]
                }
                view.sendCommittedText(String(ch))
            }
            typed += 1
        }
        return ["ok": true, "typed": typed]
    }

    /// Synthesize keyDown + keyUp for a chord and send them through NSApp, so they
    /// take the real path (menu key equivalents, the window, the first responder).
    /// Returns where the keyDown went (`app`, or on the inactive path `view`,
    /// `menu` or `window`), nil without a window.
    private func deliver(_ chord: Chord) -> String? {
        // The key window; without one (the app is not active) the frontmost
        // visible window, as a user would see it.
        guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }) ?? app.mainWindow?.window else { return nil }
        var route = "app"
        let chars = KeyboardLayout.character(for: chord.keyCode, modifiers: chord.flags.subtracting(.command))
            .map(String.init) ?? ""
        let charsIgnoring = KeyboardLayout.character(for: chord.keyCode, modifiers: chord.flags.intersection(.shift))
            .map(String.init) ?? chars
        let now = ProcessInfo.processInfo.systemUptime
        for (type, ts) in [(NSEvent.EventType.keyDown, now), (.keyUp, now + 0.001)] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: chord.flags,
                timestamp: ts,
                windowNumber: window.windowNumber,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: charsIgnoring,
                isARepeat: false,
                keyCode: chord.keyCode) else { return nil }
            if NSApp.keyWindow != nil {
                NSApp.sendEvent(event)
            } else {
                // The app is not active (no key window): NSApp.sendEvent would
                // drop the key. Take the real order by hand: the window's views
                // get the key equivalent (the pane chords, ⌘C/⌘V), then the menu
                // bar, then the event goes to the window a user would see in front.
                if type == .keyDown {
                    // Only a ⌘/⌃ key is a key equivalent (a plain `e` must not
                    // reach the menu bar's hidden fn-E "Emoji & Symbols" item).
                    if !chord.flags.intersection([.command, .control]).isEmpty {
                        if window.performKeyEquivalent(with: event) { route = "view"; continue }
                        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { route = "menu"; continue }
                    }
                    route = "window"
                }
                window.sendEvent(event)
            }
        }
        return route
    }

    // MARK: resize / screenshot

    private func resize(_ obj: [String: Any]) -> [String: Any] {
        guard let w = obj["w"] as? Double, let h = obj["h"] as? Double else {
            return ["ok": false, "error": "need w and h (points)"]
        }
        guard let window = app.mainWindow?.window else { return ["ok": false, "error": "no window"] }
        window.setContentSize(NSSize(width: w, height: h))
        window.contentView?.layoutSubtreeIfNeeded()
        var result: [String: Any] = ["ok": true]
        if let view = app.focusedTerminal {
            let grid = view.grid
            result["cols"] = grid.cols
            result["rows"] = grid.rows
        }
        let f = window.frame
        result["frame"] = ["x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height]
        return result
    }

    private func screenshot(_ obj: [String: Any]) -> [String: Any] {
        guard let path = obj["path"] as? String else { return ["ok": false, "error": "missing path"] }
        guard let window = app.mainWindow?.window else { return ["ok": false, "error": "no window"] }
        // CGWindowListCreateImage is deprecated for ScreenCaptureKit but is the one
        // call that needs no async permission dance; without Screen Recording
        // permission it returns an image without our content (or nil).
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            return ["ok": false, "error": "CGWindowListCreateImage returned nil (Screen Recording permission?)"]
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["ok": false, "error": "PNG encoding failed"]
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            return ["ok": false, "error": "write: \(error)"]
        }
        return ["ok": true, "path": path, "width": image.width, "height": image.height,
                "note": "blank unless the app has Screen Recording permission"]
    }
}
