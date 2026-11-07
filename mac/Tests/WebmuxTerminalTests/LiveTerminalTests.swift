// Live tests: a real `TerminalPaneView` in a real window, attached to the isolated
// Darwin dev host (TermTestHost). The contract's rule 5 (verify by running): typing
// through the view's key path, reading back with `visibleText()`, the theme switch,
// ⌃⌥V, the exit event. Skipped without the host binary.
import XCTest
import AppKit
import GhosttyKit
@testable import WebmuxTerminal

@MainActor
final class LiveTerminalTests: XCTestCase {
    /// One Ghostty app per process (ghostty_init is once per process too).
    private static var ghostty: Ghostty.App?
    private static var initialized = false

    private var window: NSWindow?
    private var pane: TerminalPaneView?
    private var socket = ""
    private var sessionId = ""
    private var events: [WebmuxEvent] = []
    private var statuses: [String] = []
    private var chosen: [(url: String, kind: LinkKind)] = []

    @MainActor private final class Recorder: TerminalPaneDelegate {
        var statuses: [String] = []
        var chosen: [(url: String, kind: LinkKind)] = []
        var exitCode: Int64?
        func terminalPane(_ pane: TerminalPaneView, status message: String) { statuses.append(message) }
        func terminalPane(_ pane: TerminalPaneView, chooseLink url: String, kind: LinkKind) { chosen.append((url, kind)) }
        func surface(_ view: WebmuxSurfaceView, didExitWithCode code: Int64) { exitCode = code }
    }
    private let recorder = Recorder()

    override class func setUp() {
        super.setUp()
        _ = LiveTerminalTeardown.install
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        socket = try TermTestHost.socketPath()
        _ = NSApplication.shared
        if !Self.initialized {
            XCTAssertEqual(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv), GHOSTTY_SUCCESS)
            Self.initialized = true
        }
        if Self.ghostty == nil {
            let app = Ghostty.App(config: TerminalConfig.config(.dark))
            XCTAssertEqual(app.readiness, .ready)
            Self.ghostty = app
        }
        guard let app = Self.ghostty?.app else { throw XCTSkip("GhosttyKit did not start") }

        sessionId = try TermTestHost.createSession(socket)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 660, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "webmux term-tests"
        let pane = TerminalPaneView(app: app, socketPath: socket, sessionId: sessionId)
        pane.delegate = recorder
        pane.onEvent = { [weak self] in self?.events.append($0) }
        pane.frame = window.contentView?.bounds ?? .zero
        pane.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pane)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pane)
        self.window = window
        self.pane = pane

        try waitUntil("link up", timeout: 10) { pane.isLinkUp }
        try waitUntil("prompt", timeout: 10) { pane.visibleText().contains("$") }
    }

    override func tearDownWithError() throws {
        if let pane {
            pane.removeFromSuperview()
            self.pane = nil
        }
        window?.orderOut(nil)
        window = nil
        pump(0.1)
        if !sessionId.isEmpty { TermTestHost.deleteSession(socket, id: sessionId) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    /// Run the main run loop so the backend's events and the app ticks land.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval, _ cond: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what); screen: \(pane?.visibleText() ?? "")")
                throw NSError(domain: "LiveTerminalTests", code: 1)
            }
            pump(0.05)
        }
    }

    /// Type a chord through the view's own key path (keyDown + keyUp), as AppKit
    /// would deliver it to the first responder.
    private func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        guard let pane, let window else { return }
        let chars = KeyboardLayout.character(for: keyCode, modifiers: flags.subtracting(.command)).map(String.init) ?? ""
        let ignoring = KeyboardLayout.character(for: keyCode, modifiers: flags.intersection(.shift)).map(String.init) ?? chars
        let now = ProcessInfo.processInfo.systemUptime
        for (type, ts) in [(NSEvent.EventType.keyDown, now), (.keyUp, now + 0.001)] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ts,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown {
                if !pane.performKeyEquivalent(with: event) { pane.keyDown(with: event) }
            } else {
                pane.keyUp(with: event)
            }
        }
    }

    private static let keyCodes: [Character: UInt16] = {
        var m: [Character: UInt16] = [:]
        for key in Ghostty.Input.Key.allCases {
            guard let code = key.keyCode else { continue }
            if let c = KeyboardLayout.character(for: code, modifiers: []) { m[c] = m[c] ?? code }
            if let c = KeyboardLayout.character(for: code, modifiers: .shift), m[c] == nil { m[c] = code | 0x8000 }
        }
        return m
    }()

    /// Type a string key by key (`\n` is Return).
    private func type(_ text: String) {
        for ch in text {
            if ch == "\n" { press(0x24); continue }
            guard let code = Self.keyCodes[ch] else {
                pane?.sendCommittedText(String(ch))
                continue
            }
            if code & 0x8000 != 0 { press(code & 0x7fff, .shift) } else { press(code) }
        }
    }

    private func run(_ command: String, expect marker: String, timeout: TimeInterval = 10) throws {
        type(command + "\n")
        try waitUntil(marker, timeout: timeout) { self.pane?.visibleText().contains(marker) ?? false }
    }

    // MARK: Tests

    func testAttachTypeAndReadBack() throws {
        guard let pane else { return }
        XCTAssertTrue(pane.isAttached)
        XCTAssertFalse(pane.isDegraded)
        XCTAssertGreaterThan(pane.grid.cols, 20)
        try run("echo wm-$((6*7))", expect: "wm-42")
        XCTAssertTrue(events.contains(.linkUp))
        XCTAssertTrue(events.contains { if case .snapshot = $0 { return true } else { return false } })
    }

    func testOptionIsEscapePrefixAndControlKeys() throws {
        // T-12/T-13 on macOS: ⌥b is ESC b, ⌃a is 0x01, ⌃Space is NUL, ⌃[ is ESC.
        // `cat -v` shows them as ^[b, ^A, ^@, ^[.
        type("stty -echo; cat -v\n")
        pump(0.5)
        press(Self.keyCodes["b"]!, .option)
        press(0x24)
        try waitUntil("alt prefix", timeout: 5) { self.pane?.visibleText().contains("^[b") ?? false }
        press(Self.keyCodes["a"]!, .control)
        press(0x24)
        try waitUntil("ctrl-a", timeout: 5) { self.pane?.visibleText().contains("^A") ?? false }
        press(0x31, .control)  // space
        press(0x24)
        try waitUntil("ctrl-space", timeout: 5) { self.pane?.visibleText().contains("^@") ?? false }
        press(Self.keyCodes["d"]!, .control)  // end cat
        pump(0.3)
        type("stty echo\n")
    }

    func testXtermKeyFixups() throws {
        // T-13 where Ghostty's encoding differs from xterm.js: Ctrl+[ is ESC,
        // Ctrl+- is US, Shift+Return is CR, Ctrl+Backspace is DEL,
        // Ctrl+Shift+letter sends nothing. -icanon so cat shows each key as it
        // comes; -isig so ^\ and friends are not signals.
        // -icrnl so a CR shows as ^M rather than becoming a line break.
        type("stty -echo -icanon -isig -icrnl lnext undef; cat -v\n")
        pump(0.5)
        guard let pane else { return }
        func sent(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> String {
            let before = pane.visibleText()
            press(code, flags)
            pump(0.3)
            // The first key's output starts on the line after the command echo.
            return String(pane.visibleText().dropFirst(before.count)).trimmingCharacters(in: .newlines)
        }
        XCTAssertEqual(sent(0x21, .control), "^[", "Ctrl+[")
        XCTAssertEqual(sent(0x1b, .control), "^_", "Ctrl+-")
        XCTAssertEqual(sent(0x24, .shift), "^M", "Shift+Return")
        XCTAssertEqual(sent(0x33, .control), "^?", "Ctrl+Backspace")
        XCTAssertEqual(sent(Self.keyCodes["a"]!, [.control, .shift]), "", "Ctrl+Shift+A")
        XCTAssertEqual(sent(Self.keyCodes["a"]!, .control), "^A", "Ctrl+A still encodes")
        XCTAssertEqual(sent(Self.keyCodes["3"]!, .control), "^[", "Ctrl+3")
        XCTAssertEqual(sent(Self.keyCodes["8"]!, .control), "^?", "Ctrl+8")
        XCTAssertEqual(sent(0x7e, .shift), "^[[1;2A", "Shift+Up")
        XCTAssertEqual(sent(0x74, .shift), "", "Shift+PageUp scrolls, sends nothing")
        press(Self.keyCodes["d"]!, .control)
        pump(0.3)
        type("stty echo icanon isig icrnl\n")
    }

    func testControlOptionVIsLiteralCtrlV() throws {
        // T-16: ⌃⌥V arrives as a bare 0x16 (not ESC-prefixed, not a paste). The
        // tty's own ^V is `lnext` (it would quote the Return), so undefine it.
        type("stty -echo lnext undef; cat -v\n")
        pump(0.5)
        press(Self.keyCodes["v"]!, [.control, .option])
        press(0x24)
        try waitUntil("^V", timeout: 5) { self.pane?.visibleText().contains("^V") ?? false }
        let text = pane?.visibleText() ?? ""
        XCTAssertFalse(text.contains("^[^V"), "no ESC prefix: \(text)")
        press(Self.keyCodes["d"]!, .control)
        pump(0.3)
        type("stty echo\n")
    }

    func testCommandKeysNeverReachThePty() throws {
        // T-15: ⌘↩ (a pane chord the workspace would consume) and ⌘H encode nothing
        // even when they get to the surface's keyDown.
        type("stty -echo; cat -v\n")
        pump(0.5)
        press(0x24, .command)
        press(Self.keyCodes["h"]!, .command)
        press(Self.keyCodes["x"]!)
        press(0x24)
        try waitUntil("x", timeout: 5) { self.pane?.visibleText().contains("\nx") ?? false }
        let text = pane?.visibleText() ?? ""
        XCTAssertFalse(text.contains("^M"), "⌘↩ reached the pty: \(text)")
        XCTAssertFalse(text.contains("\nh"), "⌘H reached the pty: \(text)")
        press(Self.keyCodes["d"]!, .control)
        pump(0.3)
        type("stty echo\n")
    }

    func testThemeSwitchKeepsText() throws {
        guard let pane, let app = Self.ghostty else { return }
        try run("echo theme-$((5*5))", expect: "theme-25")
        XCTAssertTrue(app.apply(theme: .light))
        pump(0.5)
        XCTAssertEqual(TerminalTheme.current, .light)
        XCTAssertEqual(app.config.backgroundColor.usingColorSpace(.deviceRGB)?.hexString, "#F4F5F9", "the app's config followed")
        XCTAssertTrue(pane.visibleText().contains("theme-25"), "T-07: the screen survives the theme change")
        XCTAssertTrue(pane.isAttached)
        try run("echo after-$((2*2))", expect: "after-4")
        XCTAssertTrue(app.apply(theme: .dark))
        pump(0.3)
        XCTAssertTrue(pane.visibleText().contains("theme-25"))
    }

    func testPasteTextAndCopySelection() throws {
        guard let pane else { return }
        // ⌘V with text on the pasteboard pastes it (C-04 text branch).
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer { pb.clearContents(); if let saved { pb.setString(saved, forType: .string) } }
        pb.clearContents()
        pb.setString("echo paste-$((7*6))\n", forType: .string)
        press(Self.keyCodes["v"]!, .command)
        try waitUntil("pasted", timeout: 5) { pane.visibleText().contains("paste-42") }
        // ⌘C without a selection copies nothing and sends nothing.
        pb.clearContents()
        pb.setString("untouched", forType: .string)
        press(Self.keyCodes["c"]!, .command)
        pump(0.2)
        XCTAssertEqual(pb.string(forType: .string), "untouched")
        // Select all, then ⌘C copies the screen text.
        _ = pane.surfaceModel?.perform(action: "select_all")
        pump(0.1)
        XCTAssertTrue(pane.copySelection())
        XCTAssertTrue(pb.string(forType: .string)?.contains("paste-42") ?? false)
    }

    func testOSC52WriteSetsTheClipboardAndAStatus() throws {
        guard let pane else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer { pb.clearContents(); if let saved { pb.setString(saved, forType: .string) } }
        pb.clearContents()
        // "from-osc52" in base64.
        type("printf '\\033]52;c;ZnJvbS1vc2M1Mg==\\007'\n")
        try waitUntil("clipboard", timeout: 5) { pb.string(forType: .string) == "from-osc52" }
        pump(0.1)
        XCTAssertTrue(recorder.statuses.contains("clipboard set from terminal"), "\(recorder.statuses)")
        _ = pane
    }

    func testLinkDetectionUnderThePointer() throws {
        guard let pane else { return }
        try run("echo see https://ex.invalid/path?q=1, ok", expect: "ok")
        pump(0.3)
        // Find the row with the URL and point at its first character.
        let rows = pane.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
        guard let row = rows.lastIndex(where: { $0.contains("https://ex.invalid/path") && !$0.contains("echo") }),
              let range = rows[row].range(of: "https://") else {
            return XCTFail("URL row not found in \(rows)")
        }
        let col = rows[row].distance(from: rows[row].startIndex, to: range.lowerBound)
        let cell = pane.cellSize
        XCTAssertGreaterThan(cell.width, 0)
        let x = TerminalConfig.padding + CGFloat(col) * cell.width + 1
        let topY = TerminalConfig.padding + CGFloat(row) * cell.height + 1
        let point = NSPoint(x: x, y: pane.bounds.height - topY)
        XCTAssertEqual(pane.link(at: point)?.match.url, "https://ex.invalid/path?q=1", "T-24: the URL under the pointer, without the trailing comma")
        XCTAssertNil(pane.link(at: NSPoint(x: TerminalConfig.padding + 1, y: pane.bounds.height - topY)), "the `see` before it")
        // The relay: once per id (C-11).
        pane.onEvent = nil
        pane.delegate = recorder
        XCTAssertTrue(OpenURLDedupe.shared.shouldShow(id: "live-1", host: socket))
        XCTAssertFalse(OpenURLDedupe.shared.shouldShow(id: "live-1", host: socket))
    }

    /// A mouse event over the pane at a point in view coordinates.
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let pane, let window else { return nil }
        let inWindow = pane.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    }

    /// The view point over the first character of `needle` on screen.
    private func point(of needle: String) -> NSPoint? {
        guard let pane else { return nil }
        let rows = pane.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
        guard let row = rows.lastIndex(where: { $0.contains(needle) && !$0.contains("echo") }),
              let range = rows[row].range(of: needle) else { return nil }
        let col = rows[row].distance(from: rows[row].startIndex, to: range.lowerBound)
        let cell = pane.cellSize
        let x = TerminalConfig.padding + CGFloat(col) * cell.width + 1
        let topY = TerminalConfig.padding + CGFloat(row) * cell.height + 1
        return NSPoint(x: x, y: pane.bounds.height - topY)
    }

    func testShiftClickCopiesTheLink() throws {
        // T-24: Shift+click on a URL copies it and shows `link copied`; a click
        // elsewhere does nothing of the kind. (A plain click would open the
        // browser, so it is not exercised here.)
        guard let pane else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer { pb.clearContents(); if let saved { pb.setString(saved, forType: .string) } }
        pb.clearContents()
        pb.setString("before", forType: .string)
        try run("echo go https://ex.invalid/copy-me now", expect: "now")
        pump(0.3)
        guard let p = point(of: "https://ex.invalid/copy-me"), let down = mouse(.leftMouseDown, at: p, flags: .shift),
              let up = mouse(.leftMouseUp, at: p, flags: .shift) else { return XCTFail("no URL on screen") }
        pane.mouseMoved(with: down)
        XCTAssertEqual(pane.hoveredURL, "https://ex.invalid/copy-me")
        pane.mouseDown(with: down)
        pane.mouseUp(with: up)
        pump(0.1)
        XCTAssertEqual(pb.string(forType: .string), "https://ex.invalid/copy-me")
        XCTAssertTrue(recorder.statuses.contains("link copied"))
        XCTAssertFalse(pane.visibleText().contains("\u{1b}"), "the held click never reached the pty")
        // Elsewhere: a plain click, no link.
        pb.clearContents()
        pb.setString("untouched", forType: .string)
        guard let q = point(of: "go "), let d2 = mouse(.leftMouseDown, at: q), let u2 = mouse(.leftMouseUp, at: q) else { return }
        pane.mouseMoved(with: d2)
        XCTAssertNil(pane.hoveredURL)
        pane.mouseDown(with: d2)
        pane.mouseUp(with: u2)
        pump(0.1)
        XCTAssertEqual(pb.string(forType: .string), "untouched")
    }

    func testImagePasteAndClipboardSync() throws {
        // C-06/C-07/C-08: ⌘V with an image on the pasteboard sends paste-image and
        // the host's paste-result becomes a status; C-09: the sync sends the
        // image once per host.
        guard let pane else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer { pb.clearContents(); if let saved { pb.setString(saved, forType: .string) } }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pb.clearContents()
        pb.setData(rep.tiffRepresentation!, forType: .tiff)
        press(Self.keyCodes["v"]!, .command)
        XCTAssertEqual(recorder.statuses.first, "uploading pasted image…")
        try waitUntil("paste-result", timeout: 10) {
            self.events.contains { if case .pasteResult = $0 { return true } else { return false } }
        }
        pump(0.1)
        XCTAssertTrue(recorder.statuses.contains { $0.hasPrefix("pasted image → ") || $0.hasPrefix("image in clipboard") }, "\(recorder.statuses)")
        XCTAssertFalse(pane.visibleText().contains("TIFF"), "the image bytes never went to the pty")

        ClipboardSyncState.shared.reset(host: socket)
        XCTAssertTrue(pane.syncClipboardImageIfAny())
        XCTAssertTrue(recorder.statuses.contains("clipboard image synced to sessions"))
        XCTAssertFalse(pane.syncClipboardImageIfAny(), "throttled, and the same image")
        XCTAssertFalse(TerminalPaneView.syncClipboardImage(through: [pane]))
    }

    func testScrollbarFollowsScrollback() throws {
        guard let pane else { return }
        try run("for i in $(seq 1 200); do echo line-$i; done; echo done-$((3*3))", expect: "done-9")
        try waitUntil("scrollbar", timeout: 5) { pane.scrollbackState.scrollable }
        let s = pane.scrollbackState
        XCTAssertGreaterThan(s.total, s.len)
        XCTAssertEqual(s.offset + s.len, s.total, "at the bottom")
        _ = pane.surfaceModel?.perform(action: "scroll_to_row:0")
        try waitUntil("top", timeout: 5) { pane.scrollbackState.offset == 0 }
        XCTAssertTrue(pane.visibleText().contains("line-1\n"))
        // Typing snaps back to the bottom (T-17).
        type("\n")
        try waitUntil("bottom", timeout: 5) { pane.scrollbackState.offset + pane.scrollbackState.len == pane.scrollbackState.total }
    }

    func testFadeAndUnfocused() throws {
        guard let pane else { return }
        pane.setUnfocused(fade: 40)
        XCTAssertEqual(pane.unfocusedFade, 40)
        pump(0.3)
        XCTAssertEqual(pane.alphaValue, 0.85, accuracy: 0.01)
        pane.setUnfocused(fade: 0)
        pump(0.3)
        XCTAssertEqual(pane.alphaValue, 1, accuracy: 0.01)
    }

    func testExitReachesTheDelegate() throws {
        guard let pane else { return }
        type("exit 7\n")
        try waitUntil("exit", timeout: 10) { pane.isFinished }
        XCTAssertEqual(recorder.exitCode, 7)
        XCTAssertEqual(pane.exitCode, 7)
        XCTAssertFalse(pane.isLinkUp)
        XCTAssertFalse(pane.isDegraded)
        XCTAssertTrue(pane.visibleText().contains("[session exited: 7]"), "the backend printed the red line")
        sessionId = ""  // gone on the host already (T-37: no DELETE)
    }
}

/// Stops the test host after the suite (one per process).
final class LiveTerminalTeardown: NSObject, XCTestObservation {
    static let install: Void = {
        XCTestObservationCenter.shared.addTestObserver(LiveTerminalTeardown())
    }()

    func testBundleDidFinish(_ testBundle: Bundle) {
        TermTestHost.stop()
    }
}

