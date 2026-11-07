// Status messages (M-01, M-02; reference: panels/toast.zig): a transient HUD
// at the bottom of a window, one at a time, hidden 3000 ms after the last
// message (a new message replaces the text and restarts the timer), never
// taking the pointer. The Electron status line belongs to a host's page, so
// a message from a host behind is kept with its deadline and shows for what
// is left of it if that host comes to the front in time (`setFront`).
import AppKit
import os

/// The HUD's timing and ownership, pure (unit-tested). Times are
/// milliseconds on any monotonic clock.
public struct StatusHUDModel: Equatable, Sendable {
    public static let hideAfterMs: Int64 = 3000

    public struct Pending: Equatable, Sendable {
        public var connection: String
        public var text: String
        public var until: Int64
    }

    /// What is showing: text and deadline, or nil.
    public private(set) var text: String?
    public private(set) var owner: String?
    public private(set) var until: Int64 = 0
    /// The last message of each connection not in front.
    public private(set) var pending: [Pending] = []
    public private(set) var front: String?
    public private(set) var frontKnown = false
    /// Messages shown since start (for the control socket).
    public private(set) var count = 0

    public init() {}

    public var isShowing: Bool { text != nil }

    /// Remaining display time at `now`, 0 when hidden.
    public func remainingMs(now: Int64) -> Int64 {
        guard text != nil else { return 0 }
        return max(0, until - now)
    }

    /// Show `text` from `connection` (nil: app-wide). Returns true when the
    /// HUD must (re)display, false when the message was only kept.
    @discardableResult
    public mutating func show(_ text: String, from connection: String? = nil, now: Int64) -> Bool {
        let deadline = now + Self.hideAfterMs
        if let c = connection {
            pending.removeAll { $0.connection == c }
            pending.append(Pending(connection: c, text: text, until: deadline))
            if !isFront(c) { return false }
        }
        self.text = text
        owner = connection
        until = deadline
        count += 1
        return true
    }

    /// The timer fired, or the display was taken down: forget the text if
    /// its deadline has passed.
    public mutating func expire(now: Int64) {
        if until <= now {
            text = nil
            owner = nil
        }
        pending.removeAll { $0.until <= now }
    }

    public mutating func hide() {
        text = nil
        owner = nil
    }

    /// Which connection is in front (nil: none/landing). Another host's
    /// message goes away with its host; the new front host's pending message
    /// reappears for the rest of its time. Returns what to display, if anything.
    @discardableResult
    public mutating func setFront(_ connection: String?, now: Int64) -> Pending? {
        frontKnown = true
        front = connection
        if let o = owner, !isFront(o) { hide() }
        guard let c = connection, let p = pending.first(where: { $0.connection == c }), p.until > now else { return nil }
        text = p.text
        owner = c
        until = p.until
        return p
    }

    func isFront(_ connection: String) -> Bool {
        if !frontKnown { return true }
        return front == connection
    }
}

/// The HUD on a window. One per window, created on first use; the API is the
/// static `show`.
@MainActor
public final class StatusHUD {
    private static let logger = Logger(subsystem: panelsLogSubsystem, category: "panels")
    private static var hosts: [ObjectIdentifier: StatusHUD] = [:]
    private static var model = StatusHUDModel()

    /// Messages shown since start, and the text showing (control socket).
    public static var shownCount: Int { model.count }
    public static var currentText: String? { model.text }

    /// Show `text` at the bottom of `window` (app-wide message).
    public static func show(_ text: String, in window: NSWindow?) {
        show(text, from: nil, in: window)
    }

    /// Show a message from a connection's workspace: only while that
    /// connection is in front (see `setFront`).
    public static func show(_ text: String, from connection: String?, in window: NSWindow?) {
        logger.info("status: \(text, privacy: .public)")
        let now = nowMs()
        let display = model.show(text, from: connection, now: now)
        guard display, let window else { return }
        host(for: window).display(text, forMs: StatusHUDModel.hideAfterMs)
    }

    /// The chrome reports which connection is in front of `window`.
    public static func setFront(_ connection: String?, in window: NSWindow?) {
        let now = nowMs()
        let wasShowing = model.isShowing
        let p = model.setFront(connection, now: now)
        guard let window else { return }
        if let p {
            host(for: window).display(p.text, forMs: p.until - now)
        } else if wasShowing && !model.isShowing {
            host(for: window).hide()
        }
    }

    static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private static func host(for window: NSWindow) -> StatusHUD {
        let key = ObjectIdentifier(window)
        if let h = hosts[key] { return h }
        let h = StatusHUD(window: window)
        hosts[key] = h
        return h
    }

    private weak var window: NSWindow?
    private let panel = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var timer: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    private init(window: NSWindow) {
        self.window = window
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        panel.alphaValue = 0
        panel.isHidden = true
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = StatusHUD.hosts.removeValue(forKey: ObjectIdentifier(window)) }
        }
    }

    private func attachIfNeeded() {
        guard let content = window?.contentView, panel.superview !== content else { return }
        panel.removeFromSuperview()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            panel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -36),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    fileprivate func display(_ text: String, forMs ms: Int64) {
        attachIfNeeded()
        label.stringValue = text
        panel.isHidden = false
        if let content = panel.superview { content.addSubview(panel, positioned: .above, relativeTo: nil) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            StatusHUD.model.expire(now: StatusHUD.nowMs())
            self?.hide()
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms))), execute: item)
    }

    fileprivate func hide() {
        timer?.cancel()
        timer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil else { return }
                self.panel.isHidden = true
            }
        })
    }
}
