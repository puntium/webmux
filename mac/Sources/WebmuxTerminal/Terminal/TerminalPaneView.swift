// The terminal pane: a `WebmuxSurfaceView` with the Electron client's pane
// behaviour on top (gtk/PARITY.md §§ 1, 2, 14 and the pane-local rows of § 3; GTK
// reference pane.zig + terminal/). This is the view the Workspace area puts in a
// pane frame and the one the Panels area talks to through `TerminalPaneDelegate`.
//
//   keys       ⌘C copies the selection (T-22), ⌘V / ⇧⌘V paste (image → paste-image,
//              text → paste, C-04…C-06), ⌃⌥V is a literal ^V (T-16); everything else
//              is Ghostty's encoding (⌥ as ESC prefix, T-12/T-13). ⌘ chords never
//              reach the pty: the workspace consumes them first and the core does
//              not encode ⌘ keys on macOS.
//   links      http(s) URLs are detected in the row under the pointer (TerminalLinks)
//              and OSC 8 hyperlinks asked of the fork (`ghostty_surface_webmux_osc8_at`,
//              T-25); a click opens the browser, Shift+click copies (T-24), also while
//              the program has mouse reporting on (the click is still reported). The
//              core underlines URLs on hover by itself (the config's link rule) and
//              its own link clicks (⌘-click, ⌘-click on a non-http OSC 8) arrive as
//              `.ghosttyOpenURL`; mailto:/other schemes and the host's `open-url` relay
//              (deduped by id, C-11) go to `chooseLink`.
//   Alt+click  moves the shell cursor to the clicked cell by arrow keys (T-20), done
//              by the fork from the core's cursor state (`ghostty_surface_webmux_alt_click`).
//   clipboard  OSC 52 writes land on the pasteboard (Ghostty.App) and show a status;
//              `syncClipboardImageIfAny()` is the C-09 sync the chrome calls on focus.
//   scrollbar  an overlay `TerminalScrollbar` on the right edge (T-10) fed by the core's
//              `scrollbar` action; ⌥+wheel scrolls 5× (T-27); a downward scroll that
//              lands within max(3, 15 % of rows) of the bottom snaps to it (T-30).
//   fade       `setUnfocused(fade:)` dims the pane like the Electron overlay (L-24).
//   lifecycle  exit / sessionError / linkUp / linkDown / snapshot are the base class's
//              delegate calls; `isDegraded` is the S-12 flag per pane.
import AppKit
import os
import GhosttyKit

/// What a `TerminalPaneView` tells its owner beyond `WebmuxSurfaceDelegate`. All
/// calls are on the main queue.
@MainActor
public protocol TerminalPaneDelegate: WebmuxSurfaceDelegate {
    /// A link that needs the chooser (PARITY M-04): `.relay` for the host's
    /// `open-url` (Cancel / Copy / Open in browser), `.mailto` (Copy / Open in the
    /// mail app), `.other` (Copy only). http(s) clicks never come here.
    func terminalPane(_ pane: TerminalPaneView, chooseLink url: String, kind: LinkKind)
    /// A status message for the HUD, in the Electron client's wording
    /// (`link copied`, `uploading pasted image…`, `pasted image → <path>`, …).
    func terminalPane(_ pane: TerminalPaneView, status message: String)
}

public extension TerminalPaneDelegate {
    func terminalPane(_ pane: TerminalPaneView, chooseLink url: String, kind: LinkKind) {}
    func terminalPane(_ pane: TerminalPaneView, status message: String) {}
}

@MainActor
public class TerminalPaneView: WebmuxSurfaceView {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "terminal")

    /// T-37/S-10: how long an exited pane stays before the workspace removes it.
    nonisolated public static let exitCloseDelay: TimeInterval = 1.2

    private var paneDelegate: TerminalPaneDelegate? { delegate as? TerminalPaneDelegate }

    // MARK: Overlays

    private let scrollbar = TerminalScrollbar(frame: .zero)
    private let fadeOverlay = FadeOverlayView(frame: .zero)
    /// The current fade setting (0–100).
    public private(set) var unfocusedFade = 0

    // MARK: Links

    /// The http(s) URL under the pointer (own detection), with its row.
    private var hoveredLink: (match: TerminalLinks.Match, row: Int)?
    public var hoveredURL: String? { hoveredLink?.match.url }

    private struct PendingLink {
        var url: String
        var cell: Cell
        var point: NSPoint
        var mods: NSEvent.ModifierFlags
        /// The press was not forwarded to the core (no mouse reporting), so the
        /// release is not either; a drag replays it.
        var held: Bool
    }
    private var pendingLink: PendingLink?
    private var coreOpenedLink = false
    /// Where the left button went down (T-20: Alt+click must release on the same cell).
    private var leftPressCell: Cell?
    private var observers: [NSObjectProtocol] = []

    // MARK: Scrolling

    private var lastWheelDown: Date?
    /// T-30: a downward wheel scroll landing this close to the bottom snaps to it.
    nonisolated static func stickyBand(rows: Int) -> Int { max(3, Int((Double(rows) * 0.15).rounded())) }

    typealias Cell = (col: Int, row: Int)

    public override init(app: ghostty_app_t, socketPath: String, sessionId: String, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        super.init(app: app, socketPath: socketPath, sessionId: sessionId, baseConfig: baseConfig)

        scrollbar.theme = TerminalTheme.current
        scrollbar.onScrollToRow = { [weak self] row in
            _ = self?.surfaceModel?.perform(action: "scroll_to_row:\(row)")
        }
        addSubview(scrollbar)
        addSubview(fadeOverlay)
        layoutOverlays()

        // The core posts from the thread that handled the click (the main thread,
        // for mouse events); be safe about it.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ghosttyOpenURL, object: self, queue: nil) { [weak self] note in
            guard let action = note.userInfo?[Notification.Name.GhosttyOpenURLKey] as? Ghostty.Action.OpenURL else { return }
            Self.onMain { self?.coreDidOpenURL(action) }
        })
        observers.append(center.addObserver(forName: .webmuxTerminalThemeDidChange, object: nil, queue: nil) { [weak self] note in
            guard let theme = note.userInfo?[Notification.Name.TerminalThemeKey] as? TerminalTheme else { return }
            Self.onMain { self?.scrollbar.theme = theme }
        })
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
    }

    /// Run `body` on the main actor: now if this is the main thread (the common
    /// case, keeps the ordering with the caller), else queued.
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    private func layoutOverlays() {
        scrollbar.frame = NSRect(x: bounds.width - TerminalScrollbar.width, y: 0, width: TerminalScrollbar.width, height: bounds.height)
        fadeOverlay.frame = bounds
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutOverlays()
    }

    // MARK: Fade (PARITY L-24, settings E-02)

    /// Dim the pane as an unfocused pane with fade setting `fade` (0–100): the
    /// body at opacity `1 − 0.375k` under a black overlay of alpha `0.7k`, both
    /// over 0.12 s. 0 restores the focused look. The title bar (the pane frame's)
    /// is the workspace's and is not faded.
    public func setUnfocused(fade: Int) {
        let clamped = min(100, max(0, fade))
        unfocusedFade = clamped
        let k = CGFloat(clamped) / 100
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = UnfocusedFade.opacity(k)
            fadeOverlay.animator().alphaValue = UnfocusedFade.overlayAlpha(k)
        }
    }

    /// The fade arithmetic (L-24), pure for the tests.
    public enum UnfocusedFade {
        public static func opacity(_ k: CGFloat) -> CGFloat { 1 - 0.375 * k }
        public static func overlayAlpha(_ k: CGFloat) -> CGFloat { 0.7 * k }
    }

    // MARK: Scrollbar (T-10, T-27, T-30)

    override func scrollbarDidChange(_ sb: Ghostty.Action.Scrollbar) {
        let state = TerminalScrollbar.State(total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
        scrollbar.state = state
        // T-30: the viewport moved down by the wheel and is now within the
        // sticky band of the bottom: snap the rest of the way.
        if let t = lastWheelDown, Date().timeIntervalSince(t) < 0.3, state.scrollable {
            let below = state.total - (state.offset + state.len)
            if below > 0, below <= Self.stickyBand(rows: state.len) {
                lastWheelDown = nil
                _ = surfaceModel?.perform(action: "scroll_to_bottom")
            }
        }
    }

    /// The scrollback geometry the core last reported.
    public var scrollbackState: TerminalScrollbar.State { scrollbar.state }

    public override func scrollWheel(with event: NSEvent) {
        lastWheelDown = event.scrollingDeltaY < 0 ? Date() : nil
        // T-27: ⌥+wheel scrolls 5× faster (xterm fastScrollModifier: alt).
        guard event.modifierFlags.contains(.option), let surfaceModel else {
            super.scrollWheel(with: event)
            return
        }
        let precision = event.hasPreciseScrollingDeltas
        let factor: Double = precision ? 2 * 5 : 5  // the base does 2× for precise deltas
        surfaceModel.sendMouseScroll(Ghostty.Input.MouseScrollEvent(
            x: event.scrollingDeltaX * factor,
            y: event.scrollingDeltaY * factor,
            mods: .init(precision: precision, momentum: .init(event.momentumPhase))))
    }

    // MARK: Keys (T-15, T-16, C-04…C-06)

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == [.command] {
            switch key {
            case "c":
                // Edit › Copy (T-22). Consumed with or without a selection: ⌘C is
                // never the pty's ^C.
                _ = copySelection()
                return true
            case "v":
                paste()
                return true
            default:
                break
            }
        }
        if mods == [.command, .shift], key == "v" {
            paste()  // Paste and Match Style: the same paste
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if mods == [.control, .option], Self.isVKey(event) {
            // T-16: a literal ^V whatever the clipboard holds (vim visual block).
            sendLiteralCtrlV()
            return
        }
        // T-15/K-19: a ⌘ key that nobody above consumed (a chord without a
        // handler, an unbound ⌘ combination) is never terminal input on the Mac;
        // the core would not encode its text either, but it would encode ⌘↩ as a
        // plain Return.
        if mods.contains(.command) { return }
        // T-13: the xterm.js fixups only while the program has not asked for the
        // kitty keyboard protocol; with it on, every key is Ghostty's encoding.
        if !kittyKeyboardActive, let fix = XtermKeys.fixup(for: event) {
            switch fix {
            case .drop: break
            case .text(let t): _ = surfaceModel?.perform(action: "text:\(t)")
            case .action(let a): _ = surfaceModel?.perform(action: a)
            }
            return
        }
        super.keyDown(with: event)
    }

    /// True while the program has the kitty keyboard protocol enabled on the
    /// active screen (the fork reads the core's state).
    public var kittyKeyboardActive: Bool {
        guard let surface else { return false }
        return ghostty_surface_webmux_kitty_keyboard(surface)
    }

    /// Where Ghostty's legacy key encoding differs from xterm.js 5.5 (PARITY T-13;
    /// the GTK client ports all of xterm's Keyboard.ts, terminal/xterm_keys.zig).
    /// Measured on this Mac against `cat -v`; everything else matched. Skipped
    /// while the kitty keyboard protocol is on (`kittyKeyboardActive`).
    enum XtermKeys {
        enum Fix: Equatable {
            case drop
            /// Bytes for a `text:` binding action (Ghostty string escapes).
            case text(String)
            case action(String)
        }

        static func fixup(for event: NSEvent) -> Fix? {
            let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
            guard let key = Ghostty.Input.Key(keyCode: event.keyCode) else { return nil }
            let letter = key.rawValue.count == 1 && key.rawValue.first.map { $0.isLetter } == true
            switch (key, mods) {
            // Ctrl+Shift+letter sends nothing to the pty (Ghostty: CSI u).
            case (_, [.control, .shift]) where letter: return .drop
            // Ctrl+[ is ESC (Ghostty: CSI 91;5u), the vim escape.
            case (.bracketLeft, [.control]): return .text("\\x1b")
            // Ctrl+- is US (Ghostty: CSI 45;5u).
            case (.minus, [.control]): return .text("\\x1f")
            // Shift+Return is a plain CR (Ghostty: CSI 27;2;13~).
            case (.enter, [.shift]): return .text("\\r")
            // Ctrl+Backspace is DEL like Backspace (Ghostty: BS).
            case (.backspace, [.control]): return .text("\\x7f")
            // Shift+PageUp/PageDown scroll the viewport and send nothing.
            case (.pageUp, [.shift]): return .action("scroll_page_up")
            case (.pageDown, [.shift]): return .action("scroll_page_down")
            default: return nil
            }
        }
    }

    static func isVKey(_ event: NSEvent) -> Bool {
        if let key = Ghostty.Input.Key(keyCode: event.keyCode), key == .v { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// T-16 / C-04 fallback: 0x16 to the pty, then the viewport to the bottom.
    public func sendLiteralCtrlV() {
        guard let surfaceModel else { return }
        _ = surfaceModel.perform(action: "text:\\x16")
        _ = surfaceModel.perform(action: "scroll_to_bottom")
    }

    // MARK: Clipboard (C-01…C-10, T-22)

    /// Edit › Copy / ⌘C: the selection to the pasteboard. False without one.
    @discardableResult
    public func copySelection() -> Bool {
        guard let surface, ghostty_surface_has_selection(surface) else { return false }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return false }
        let s = String(cString: ptr)
        guard !s.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        return true
    }

    /// Edit › Paste / ⌘V (C-04…C-06): an image on the pasteboard takes the
    /// image-paste flow, text is pasted (bracketed when the program asked),
    /// anything else does nothing.
    public func paste() {
        let pb = NSPasteboard.general
        if ImagePaste.hasImage(pb) {
            pasteImage(from: pb)
            return
        }
        if let data = pb.ghosttyData(forMime: "text/plain"), !data.isEmpty {
            pasteText()
        }
    }

    /// The core's clipboard paste (reads text/plain through Ghostty.App's callback),
    /// then the viewport to the bottom (T-17).
    func pasteText() {
        guard let surfaceModel else { return }
        _ = surfaceModel.perform(action: "paste_from_clipboard")
        _ = surfaceModel.perform(action: "scroll_to_bottom")
    }

    /// C-07: with the session socket open, send the image as `paste-image`; the
    /// host answers with a `paste-result` (C-08) that becomes a status message.
    func pasteImage(from pasteboard: NSPasteboard) {
        guard isLinkUp else { return }  // socket closed: do nothing
        status("uploading pasted image…")
        guard let encoded = ImagePaste.encode(pasteboard) else {
            status("image paste failed: the clipboard image could not be read")
            return
        }
        if !sendPasteImage(mime: encoded.mime, base64: encoded.base64) {
            Self.logger.info("image paste dropped: session socket closed")
        }
    }

    /// C-09: the chrome calls this on the host's visible pane when the window
    /// gains focus (and when the visible host changes). Throttled to once per
    /// second per host; text clipboards are never synced; the same image is not
    /// sent twice; read failures are silent. True if a frame went out.
    @discardableResult
    public func syncClipboardImageIfAny() -> Bool {
        let state = ClipboardSyncState.shared
        guard state.shouldLook(host: socketPath) else { return false }
        let pb = NSPasteboard.general
        guard ImagePaste.hasImage(pb), isLinkUp else { return false }
        guard let encoded = ImagePaste.encode(pb) else { return false }
        guard state.isNew(encoded, host: socketPath) else { return false }
        guard sendClipboardSync(mime: encoded.mime, base64: encoded.base64) else { return false }
        state.recordSent(encoded, host: socketPath)
        status("clipboard image synced to sessions")
        return true
    }

    /// C-09 on a host: the first pane with an open socket does the sync.
    @discardableResult
    public static func syncClipboardImage(through panes: [TerminalPaneView]) -> Bool {
        guard let pane = panes.first(where: { $0.isLinkUp }) else { return false }
        return pane.syncClipboardImageIfAny()
    }

    override func clipboardDidWrite() {
        // An OSC 52 write from the program (C-01); our own copies write the
        // pasteboard directly and never come through here.
        status("clipboard set from terminal")
    }

    // Menu actions (Edit menu) take the same paths as the keys.
    override func copy(_ sender: Any?) { _ = copySelection() }
    override func paste(_ sender: Any?) { paste() }
    override func pasteAsPlainText(_ sender: Any?) { paste() }

    // MARK: Lifecycle messages

    override func didReceive(_ event: WebmuxEvent) {
        switch event {
        case let .pasteResult(mode, path):
            // C-08
            switch mode {
            case "claude": status("image in clipboard — Ctrl+V forwarded to Claude")
            case "path": status("pasted image → \(path ?? "")")
            default: break
            }
        case let .openURL(url, id):
            // C-11: the chooser, once per id per host.
            guard OpenURLDedupe.shared.shouldShow(id: id, host: socketPath) else { return }
            paneDelegate?.terminalPane(self, chooseLink: url, kind: .relay)
        default:
            break
        }
    }

    private func status(_ message: String) {
        paneDelegate?.terminalPane(self, status: message)
    }

    // MARK: Links (T-24, T-25, T-26)

    /// The grid cell under a point in view coordinates.
    func cell(at point: NSPoint) -> Cell? {
        let grid = self.grid
        var size = cellSize
        if size.width <= 0 || size.height <= 0, let s = surfaceSize, let scale = window?.backingScaleFactor, scale > 0 {
            size = CGSize(width: CGFloat(s.cell_width_px) / scale, height: CGFloat(s.cell_height_px) / scale)
        }
        return TerminalLinks.cell(x: point.x, topY: bounds.height - point.y, cellSize: size, columns: grid.cols, rows: grid.rows)
    }

    /// One viewport row as text (empty cells read as spaces or NUL).
    func rowText(_ row: Int) -> String {
        guard let surface else { return "" }
        let cols = grid.cols
        guard cols > 0 else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(cols - 1), y: UInt32(row)),
            rectangle: true)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }

    /// The OSC 8 hyperlink at a point (any scheme), from the core's cell state.
    public func osc8URL(at point: NSPoint) -> String? {
        guard let surface else { return nil }
        let str = ghostty_surface_webmux_osc8_at(surface, point.x, bounds.height - point.y)
        guard let ptr = str.ptr, str.len > 0 else { return nil }
        defer { ghostty_string_free(str) }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(str.len)), as: UTF8.self)
    }

    /// The http(s) URL under a point, if any: an OSC 8 hyperlink first (T-25;
    /// its match covers just that cell, the hyperlink's extent is the core's), then
    /// a URL in the row's text (T-24).
    func link(at point: NSPoint) -> (match: TerminalLinks.Match, row: Int)? {
        guard let cell = cell(at: point) else { return nil }
        if let uri = osc8URL(at: point), LinkKind(url: uri) == .http {
            return (TerminalLinks.Match(url: uri, range: cell.col..<(cell.col + 1)), cell.row)
        }
        guard let match = TerminalLinks.url(in: rowText(cell.row), atColumn: cell.col) else { return nil }
        return (match, cell.row)
    }

    private func updateHover(at point: NSPoint?) {
        let new = point.flatMap { link(at: $0) }
        let changed = new?.match != hoveredLink?.match || new?.row != hoveredLink?.row
        hoveredLink = new
        if changed { window?.invalidateCursorRects(for: self) }
    }

    public override func resetCursorRects() {
        if hoveredLink != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        } else {
            super.resetCursorRects()
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: nil)
    }

    /// True if a left click right now goes to the program (mouse reporting on).
    var mouseReportingActive: Bool {
        surfaceModel?.mouseCaptured ?? false
    }

    public override func mouseDown(with event: NSEvent) {
        coreOpenedLink = false
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        leftPressCell = cell(at: point)
        updateHover(at: point)
        if let hovered = hoveredLink, let cell = cell(at: point), mods.isDisjoint(with: [.control, .option, .command]) {
            // A click (or Shift+click) on a link. If the program gets the click
            // (mouse reporting), it still does and the link opens too (T-24 with
            // T-19); otherwise the press is held so no selection starts, and a
            // drag replays it.
            let reported = mouseReportingActive && !mods.contains(.shift)
            pendingLink = PendingLink(url: hovered.match.url, cell: cell, point: point, mods: mods, held: !reported)
            if !reported { return }
        }
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if let pl = pendingLink {
            let point = convert(event.locationInWindow, from: nil)
            if let cell = cell(at: point), cell != pl.cell {
                pendingLink = nil
                if pl.held { replayPress(pl) }
            }
        }
        super.mouseDragged(with: event)
    }

    /// A held press turned into a drag: give the core the press where it happened.
    private func replayPress(_ pl: PendingLink) {
        guard let surface else { return }
        let mods = Ghostty.ghosttyMods(pl.mods)
        ghostty_surface_mouse_pos(surface, pl.point.x, frame.height - pl.point.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    public override func mouseUp(with event: NSEvent) {
        let pressCell = leftPressCell
        leftPressCell = nil
        guard let pl = pendingLink else {
            super.mouseUp(with: event)
            // T-20: Alt+click (no drag, the program not reporting the mouse)
            // moves the shell cursor to the cell.
            let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if mods == [.option], let pressCell, let surface, !mouseReportingActive {
                let point = convert(event.locationInWindow, from: nil)
                if let release = cell(at: point), release == pressCell {
                    _ = ghostty_surface_webmux_alt_click(surface, point.x, bounds.height - point.y)
                }
            }
            return
        }
        pendingLink = nil
        let point = convert(event.locationInWindow, from: nil)
        let same = cell(at: point).map { $0 == pl.cell } ?? false
        if pl.held {
            // The core never saw the press; it does not see the release either.
            if same {
                act(on: pl.url, shift: event.modifierFlags.contains(.shift))
            } else {
                replayPress(pl)
                super.mouseUp(with: event)
            }
            return
        }
        // A reported click is the program's too.
        super.mouseUp(with: event)
        if same, !coreOpenedLink {
            act(on: pl.url, shift: event.modifierFlags.contains(.shift))
        }
    }

    /// The core opened a link itself (⌘-click on a URL, or an OSC 8 hyperlink):
    /// the same rules as our own clicks (T-24/T-25, GTK deviation 26).
    private func coreDidOpenURL(_ action: Ghostty.Action.OpenURL) {
        coreOpenedLink = true
        act(on: action.url, shift: NSEvent.modifierFlags.contains(.shift))
    }

    /// A click on a link: http(s) opens the browser or, with Shift, copies the
    /// URL (`link copied`); other schemes go to the chooser.
    func act(on url: String, shift: Bool) {
        let kind = LinkKind(url: url)
        switch kind {
        case .http:
            if shift {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url, forType: .string)
                status("link copied")
            } else {
                Self.open(url)
            }
        case .mailto, .other, .relay:
            paneDelegate?.terminalPane(self, chooseLink: url, kind: kind)
        }
    }

    /// Open an http(s) URL in the default browser (T-26: never inside the app).
    public static func open(_ url: String) {
        guard LinkKind(url: url) == .http, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

/// The L-24 black overlay: takes no mouse events.
final class FadeOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        alphaValue = 0
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
