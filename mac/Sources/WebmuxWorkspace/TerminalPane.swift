// The terminal pane: a `TerminalPaneView` (the Terminal area's surface with
// the pane behaviours) attached to one session, behind the `WorkspacePane`
// interface. Port of the pane half of
// gtk/ghostty/src/apprt/webmux/terminal/remote.zig as far as the workspace
// needs it: titles from the TITLE event (T-40), the link flag (S-12), and
// the two ways a session ends (S-10 / T-37: `exit` closes the pane 1200 ms
// after the backend printed the red line; T-39: `session_error` closes it at
// once). Everything else about a terminal (theme, clipboard, links, IME) is
// the Terminal area's and lives on `TerminalPaneView`; the pane is the
// surface's `TerminalPaneDelegate` and relays what the chrome shows
// (`onChooseLink`, `onStatus`) and applies the unfocused fade (L-24).
//
// The pane's `view` is a container around the surface so that a move can
// hold the terminal at its old size (deviation 69): the container takes its
// final size at once and the surface follows when the hold is released.
import AppKit
import os
import GhosttyKit
import WebmuxLayout
import WebmuxTerminal

/// app.js `exit`: `setTimeout(removeTile, 1200)`.
public let terminalExitCloseDelay: TimeInterval = 1.2

@MainActor
public final class TerminalPane: NSObject, WorkspacePane, TerminalPaneDelegate {
    nonisolated private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "workspace")

    public let id: String
    public let kind: PaneKind = .terminal
    public let surface: TerminalPaneView
    private let container: TerminalPaneContainer
    public var view: NSView { container }
    public weak var host: WorkspacePaneHost?
    public private(set) var title: String?
    /// The exit code once the session ended.
    public private(set) var exitCode: Int64?
    private var exitTimer: Timer?
    private var closed = false

    /// Every event the surface delivers, after the pane handled it (the
    /// Terminal area and the control socket observe here).
    public var onEvent: ((WebmuxEvent) -> Void)?
    /// The frame's focus changed: `focused`, and the unfocused fade strength
    /// (0…1, 0 when focused) the Terminal area applies on the surface (L-24).
    public var onFocusChanged: ((_ focused: Bool, _ fadeStrength: Double) -> Void)?
    public private(set) var isFocusedInWorkspace = false
    /// The surface asks for the link chooser (M-04; `TerminalPaneDelegate`).
    public var onChooseLink: ((_ url: String, _ kind: LinkKind) -> Void)?
    /// A status line from the surface for the HUD (`TerminalPaneDelegate`).
    public var onStatus: ((String) -> Void)?

    public init(app: ghostty_app_t, socketPath: String, sessionId: String) {
        id = sessionId
        surface = TerminalPaneView(app: app, socketPath: socketPath, sessionId: sessionId)
        container = TerminalPaneContainer(surface: surface)
        super.init()
        surface.delegate = self
        surface.onEvent = { [weak self] e in self?.onEvent?(e) }
    }

    public var isLinkUp: Bool { surface.isLinkUp }
    public var isFinished: Bool { surface.isFinished }

    // MARK: WorkspacePane

    public func focus() {
        guard let window = surface.window else { return }
        if window.firstResponder !== surface { window.makeFirstResponder(surface) }
    }

    public func setShown(_ shown: Bool) {
        container.shown = shown
        if let s = surface.surface { ghostty_surface_set_occlusion(s, shown) }
    }

    public func holdResize(_ hold: Bool) {
        container.holdResize = hold
    }

    public func setFocused(_ focused: Bool, fadeStrength: Double) {
        // The ring is the frame's; the fade on the texture is the Terminal
        // area's (`setUnfocused(fade:)`, 0 when focused).
        isFocusedInWorkspace = focused
        surface.setUnfocused(fade: focused ? 0 : Int((fadeStrength * 100).rounded()))
        onFocusChanged?(focused, fadeStrength)
    }

    public var cellWidthPx: Double? {
        let w = surface.cellSize.width
        return w > 0 ? Double(w) : nil
    }

    public func close() {
        guard !closed else { return }
        closed = true
        exitTimer?.invalidate()
        exitTimer = nil
        surface.delegate = nil
        // Removing the view drops the last reference: the surface is freed,
        // its backend stops and the socket closes.
        container.removeFromSuperview()
    }

    // MARK: WebmuxSurfaceDelegate (main queue)

    public func surfaceLinkUp(_ view: WebmuxSurfaceView) {
        host?.pane(self, linkDidChange: true)
    }

    public func surfaceLinkDown(_ view: WebmuxSurfaceView) {
        host?.pane(self, linkDidChange: false)
    }

    public func surface(_ view: WebmuxSurfaceView, sessionTitleDidChange title: String) {
        let t: String? = title.isEmpty ? nil : title
        guard t != self.title else { return }
        self.title = t
        host?.paneTitleDidChange(self)
    }

    public func surface(_ view: WebmuxSurfaceView, didExitWithCode code: Int64) {
        exitCode = code
        Self.logger.info("session \(self.id, privacy: .public) exited code=\(code)")
        // The backend printed "[session exited: N]"; remove the pane after the
        // same delay as the Electron client. A pane the user closed meanwhile
        // (DELETE, then the exit frame during its close animation) is gone by
        // then and nothing happens.
        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(withTimeInterval: terminalExitCloseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.host?.paneRequestsClose(self)
            }
        }
    }

    public func surface(_ view: WebmuxSurfaceView, sessionError message: String) {
        Self.logger.warning("session gone on the host — closing its pane (session \(self.id, privacy: .public): \(message, privacy: .public))")
        host?.paneRequestsClose(self)
    }

    // MARK: TerminalPaneDelegate (main queue)

    public func terminalPane(_ pane: TerminalPaneView, chooseLink url: String, kind: LinkKind) {
        onChooseLink?(url, kind)
    }

    public func terminalPane(_ pane: TerminalPaneView, status message: String) {
        onStatus?(message)
    }
}

/// The surface's container: the frame's body. Holds the surface at its old
/// size while the workspace animates (`holdResize`), otherwise the surface
/// fills it. Flipped so the surface stays anchored at the top-left while held
/// (the part of the old grid that keeps its place).
@MainActor
final class TerminalPaneContainer: NSView {
    let surface: TerminalPaneView
    var shown = true

    var holdResize = false {
        didSet {
            guard holdResize != oldValue, !holdResize else { return }
            applySurfaceSize()
        }
    }

    init(surface: TerminalPaneView) {
        self.surface = surface
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.masksToBounds = true
        surface.frame = bounds
        addSubview(surface)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !holdResize { applySurfaceSize() }
    }

    private func applySurfaceSize() {
        // Once per release: the surface resizes (and tells the host) here only.
        if surface.frame != bounds { surface.frame = bounds }
    }
}
