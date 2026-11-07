// A Ghostty surface attached to a webmux session: the terminal's bytes come from
// the host's session WebSocket through the fork's termio backend (GhosttyKit, see
// gtk/ghostty/WEBMUX.md "macOS: GhosttyKit"), not from a local pty.
//
// This is the Terminal area's base class. It owns exactly three things: creating
// the surface with the webmux fields, turning the backend's C events into
// `WebmuxEvent`s on the main queue for the delegate, and the two side-channel
// frames. Every pane behaviour (theme, fade, clipboard, image paste, links, IME
// extras) belongs to the Terminal area, built on top.
import AppKit
import os
import GhosttyKit

/// What a `WebmuxSurfaceView` tells its owner. All calls are on the main queue.
@MainActor
public protocol WebmuxSurfaceDelegate: AnyObject {
    /// Socket open (first attach or reconnect).
    func surfaceLinkUp(_ view: WebmuxSurfaceView)
    /// Socket lost; the backend retries by itself.
    func surfaceLinkDown(_ view: WebmuxSurfaceView)
    /// A snapshot was replayed (the grid is in `view.surfaceSize`).
    func surface(_ view: WebmuxSurfaceView, didApplySnapshot cols: Int, rows: Int, remoteCols: Int, remoteRows: Int, pid: Int64)
    /// This session's title changed (also on every attach; may be empty).
    func surface(_ view: WebmuxSurfaceView, sessionTitleDidChange title: String)
    /// Another session's title (the host multiplexes titles over the same socket).
    func surface(_ view: WebmuxSurfaceView, otherSession session: String, titleDidChange title: String)
    /// The shell exited; final. The backend already printed the red line.
    func surface(_ view: WebmuxSurfaceView, didExitWithCode code: Int64)
    /// No such session (or another fatal error); final.
    func surface(_ view: WebmuxSurfaceView, sessionError message: String)
    /// The result of a `paste-image` frame.
    func surface(_ view: WebmuxSurfaceView, pasteResult mode: String, path: String?)
    /// The host asked to open a URL; dedupe by `id`.
    func surface(_ view: WebmuxSurfaceView, openURL url: String, id: String)
    /// Socket lifecycle for the connection log.
    func surface(_ view: WebmuxSurfaceView, socketEvent event: WebmuxEvent.Socket)
}

public extension WebmuxSurfaceDelegate {
    func surfaceLinkUp(_ view: WebmuxSurfaceView) {}
    func surfaceLinkDown(_ view: WebmuxSurfaceView) {}
    func surface(_ view: WebmuxSurfaceView, didApplySnapshot cols: Int, rows: Int, remoteCols: Int, remoteRows: Int, pid: Int64) {}
    func surface(_ view: WebmuxSurfaceView, sessionTitleDidChange title: String) {}
    func surface(_ view: WebmuxSurfaceView, otherSession session: String, titleDidChange title: String) {}
    func surface(_ view: WebmuxSurfaceView, didExitWithCode code: Int64) {}
    func surface(_ view: WebmuxSurfaceView, sessionError message: String) {}
    func surface(_ view: WebmuxSurfaceView, pasteResult mode: String, path: String?) {}
    func surface(_ view: WebmuxSurfaceView, openURL url: String, id: String) {}
    func surface(_ view: WebmuxSurfaceView, socketEvent event: WebmuxEvent.Socket) {}
}

@MainActor
public class WebmuxSurfaceView: Ghostty.SurfaceView {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "terminal")

    /// The host's HTTP unix socket this surface is attached through.
    public let socketPath: String
    /// The session id.
    public let sessionId: String
    /// The session's title as last reported by the host (TITLE event).
    public var sessionTitle: String { lifecycle.sessionTitle }
    /// True between link-up and link-down (false until the first attach).
    public var isLinkUp: Bool { lifecycle.isLinkUp }
    /// Set once the backend reported `exit` or `session_error`; the surface is
    /// then final (the backend never reconnects).
    public var isFinished: Bool { lifecycle.isFinished }
    /// True while the session socket is down and the backend is retrying (PARITY
    /// S-12, X-17 "degraded"): set by link-down, cleared by link-up and by the
    /// final events. The chrome ORs this over the host's panes.
    public var isDegraded: Bool { lifecycle.isDegraded }
    /// The exit code once `exit` arrived.
    public var exitCode: Int64? { lifecycle.exitCode }

    private var lifecycle = SessionLifecycle()

    public weak var delegate: WebmuxSurfaceDelegate?

    /// Every delivered event, in order, also goes here (the Terminal area and the
    /// control socket can observe without being the delegate).
    public var onEvent: ((WebmuxEvent) -> Void)?

    /// The `webmux_userdata`: a box with a weak back-reference, because `self`
    /// cannot be handed to the C config before `super.init`. The C side holds a
    /// retain on it that `deinit` releases on the main queue *after* this view
    /// (and, with it, the surface) is gone; the backend stops calling before
    /// `ghostty_surface_free` returns (WEBMUX.md).
    private final class EventBox {
        weak var view: WebmuxSurfaceView?
    }
    private let eventBox: Unmanaged<EventBox>

    /// Create a surface attached to `sessionId` on the host at `socketPath`.
    /// `app` is the ready `ghostty_app_t` (`Ghostty.App.app`).
    public init(app: ghostty_app_t, socketPath: String, sessionId: String, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.socketPath = socketPath
        self.sessionId = sessionId
        let box = Unmanaged.passRetained(EventBox())
        self.eventBox = box

        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.webmux = Ghostty.WebmuxAttachment(
            socketPath: socketPath,
            sessionId: sessionId,
            userdata: box.toOpaque(),
            eventCallback: WebmuxSurfaceView.eventCallback)

        super.init(app, baseConfig: config)
        box.takeUnretainedValue().view = self
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        nonisolated(unsafe) let box = eventBox
        DispatchQueue.main.async { box.release() }
    }

    // MARK: Attachment state

    /// True if the surface was created with a webmux session (always, here) and
    /// the core still has it.
    public var isAttached: Bool {
        guard let surface else { return false }
        return ghostty_surface_webmux_attached(surface)
    }

    /// The text on screen (the viewport, scrollback excluded), uncached.
    public func visibleText() -> String {
        readText(tag: GHOSTTY_POINT_VIEWPORT)
    }

    /// The current grid, from the core.
    public var grid: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    // MARK: Side-channel frames

    /// Queue a `paste-image` frame (the host saves the image and answers with a
    /// PASTE_RESULT event). `data` is base64. Returns false if no socket is open;
    /// the frame is then dropped, as in the Electron client.
    @discardableResult
    public func sendPasteImage(mime: String, base64 data: String) -> Bool {
        send(GHOSTTY_WEBMUX_FRAME_PASTE_IMAGE, mime: mime, data: data)
    }

    /// Queue a `clipboard-sync` frame (an image the user copied, for the remote
    /// clipboard). Returns false if dropped.
    @discardableResult
    public func sendClipboardSync(mime: String, base64 data: String) -> Bool {
        send(GHOSTTY_WEBMUX_FRAME_CLIPBOARD_SYNC, mime: mime, data: data)
    }

    private func send(_ kind: ghostty_webmux_frame_e, mime: String, data: String) -> Bool {
        guard let surface else { return false }
        return mime.withCString { cMime in
            data.withCString { cData in
                ghostty_surface_webmux_send(surface, kind, cMime, cData)
            }
        }
    }

    // MARK: AppKit plumbing

    /// Upstream's SwiftUI wrapper reported size changes; in AppKit the frame does.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let surface else { return }
        if let screen = window.screen {
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
        }
        viewDidChangeBackingProperties()
        sizeDidChange(frame.size)
    }

    // MARK: Events

    /// The C callback: runs on the backend's reader thread with borrowed strings.
    /// Copy, hop, return; never block (closing the surface joins that thread).
    private static let eventCallback: ghostty_webmux_event_cb = { userdata, cEvent in
        guard let userdata else { return }
        guard let event = WebmuxEvent(c: cEvent.pointee) else { return }
        let box = Unmanaged<EventBox>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            box.view?.handle(event)
        }
    }

    /// Subclass hook: runs after the state changed and before the delegate hears.
    func didReceive(_ event: WebmuxEvent) {}

    private func handle(_ event: WebmuxEvent) {
        // A final event ends the session; the backend never reconnects after
        // it, and neither does anything here (late events are dropped).
        if lifecycle.isFinished, event.isFinal || event == .linkUp || event == .linkDown { return }
        lifecycle.apply(event)
        onEvent?(event)
        didReceive(event)
        switch event {
        case .linkUp:
            delegate?.surfaceLinkUp(self)
        case .linkDown:
            delegate?.surfaceLinkDown(self)
        case let .snapshot(cols, rows, remoteCols, remoteRows, _, pid):
            if let surface { surfaceSize = ghostty_surface_size(surface) }
            delegate?.surface(self, didApplySnapshot: cols, rows: rows, remoteCols: remoteCols, remoteRows: remoteRows, pid: pid)
        case let .title(title):
            delegate?.surface(self, sessionTitleDidChange: title)
        case let .sessionTitle(session, title):
            delegate?.surface(self, otherSession: session, titleDidChange: title)
        case let .exit(code):
            delegate?.surface(self, didExitWithCode: code)
        case let .sessionError(message):
            Self.logger.error("session \(self.sessionId, privacy: .public): \(message, privacy: .public)")
            delegate?.surface(self, sessionError: message)
        case let .pasteResult(mode, path):
            delegate?.surface(self, pasteResult: mode, path: path)
        case let .openURL(url, id):
            delegate?.surface(self, openURL: url, id: id)
        case let .socket(socket):
            delegate?.surface(self, socketEvent: socket)
        }
    }
}

/// The pane-local session state the backend's events drive (PARITY T-32, T-35,
/// T-37, T-39, T-40, S-12), as a value so the semantics are unit-tested without
/// a surface.
public struct SessionLifecycle: Equatable, Sendable {
    public var sessionTitle: String = ""
    public var isLinkUp = false
    public var isFinished = false
    public var isDegraded = false
    public var exitCode: Int64?
    /// Set if the host said the session does not exist (T-39).
    public var sessionError: String?
    /// Snapshots replayed so far (one per attach).
    public var snapshots = 0

    public init() {}

    public mutating func apply(_ event: WebmuxEvent) {
        switch event {
        case .linkUp:
            guard !isFinished else { return }
            isLinkUp = true
            isDegraded = false
        case .linkDown:
            guard !isFinished else { return }
            isLinkUp = false
            isDegraded = true
        case .snapshot:
            snapshots += 1
        case let .title(title):
            sessionTitle = title
        case let .exit(code):
            isFinished = true
            isLinkUp = false
            isDegraded = false
            exitCode = code
        case let .sessionError(message):
            isFinished = true
            isLinkUp = false
            isDegraded = false
            sessionError = message
        case .sessionTitle, .pasteResult, .openURL, .socket:
            break
        }
    }
}

public extension WebmuxEvent {
    /// `exit` and `sessionError` end the session for good.
    var isFinal: Bool {
        switch self {
        case .exit, .sessionError: return true
        default: return false
        }
    }
}
