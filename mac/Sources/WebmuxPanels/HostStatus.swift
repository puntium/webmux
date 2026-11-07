// Host status as the chrome shows it: the status dot (W-12, W-22 → one
// palette, deviation 67), the state texts (W-14, W-21) and the detail
// paragraphs of the Connections window (W-30). Pure, except the dot image.
import AppKit
import WebmuxConnection

/// The six states the chrome distinguishes (main.js `snapshot`: the engine's
/// four plus `degraded` — connected while the workspace reports its session
/// sockets down — and `none` for a profile with no connection).
public enum HostStatusKind: String, Sendable, CaseIterable {
    case none, connecting, connected, degraded, retry, failed

    /// main.js snapshot: `connected` with the page's link down is `degraded`.
    public init(status: ConnectionStatus?, offline: Bool = false) {
        guard let s = status else {
            self = .none
            return
        }
        switch s.state {
        case .connecting: self = .connecting
        case .connected: self = offline ? .degraded : .connected
        case .retry: self = .retry
        case .failed: self = .failed
        }
    }

    /// True when the tunnel is up (connected or degraded).
    public var isUp: Bool { self == .connected || self == .degraded }

    /// The Connections window's state label (W-21).
    public var cardLabel: String {
        switch self {
        case .none: return ""
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .degraded: return "degraded"
        case .retry: return "retrying…"
        case .failed: return "failed"
        }
    }

    /// The pill/popup tooltip and the window subtitle (W-14), with the retry
    /// countdown when known.
    public func stateText(retrySeconds: Int? = nil) -> String {
        switch self {
        case .none: return ""
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .degraded: return "server unreachable — page retrying"
        case .retry:
            if let s = retrySeconds { return "interrupted — retrying in \(s)s" }
            return "interrupted — retrying"
        case .failed: return "connection failed"
        }
    }

    /// The dot colour (W-12's semantics, system colours instead of the
    /// Electron hexes: deviation 1). Connecting pulses.
    public var color: NSColor {
        switch self {
        case .none: return .tertiaryLabelColor
        case .connecting, .degraded: return .systemYellow
        case .connected: return .systemGreen
        case .retry, .failed: return .systemRed
        }
    }

    /// The SF Symbol the toolbar popup shows next to a host name.
    public var symbolName: String { self == .none ? "circle" : "circle.fill" }

    /// A filled dot of `diameter` points in this state's colour, for popup
    /// items and table cells (template images would lose the colour).
    public func dotImage(diameter: CGFloat = 8) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            self.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The Connections window's status detail for one connection (W-30): the
/// message line, the explanatory paragraph and the diagnostics tail.
/// Healthy connections have none.
public struct StatusDetail: Equatable, Sendable {
    public var name: String
    public var kind: HostStatusKind
    /// `ConnectionStatus.msg` (e.g. `ssh host`, `pushing webmux… 40% of 3.2 MB`).
    public var message: String
    /// The explanatory paragraph by state, or nil.
    public var explanation: String?
    /// The last ssh stderr / diagnostics lines, or empty.
    public var diagnostics: String
    /// Push progress 0…1 while the payload streams, else nil.
    public var pushFraction: Double?

    public init(name: String, kind: HostStatusKind, message: String, explanation: String?, diagnostics: String, pushFraction: Double? = nil) {
        self.name = name
        self.kind = kind
        self.message = message
        self.explanation = explanation
        self.diagnostics = diagnostics
        self.pushFraction = pushFraction
    }

    /// W-30 verbatim (with "workspace" for "page", deviation 34). `retrySeconds`
    /// is the live countdown (deviation 23). Nil for `connected`/`none`.
    public init?(status: ConnectionStatus, offline: Bool, retrySeconds: Int?) {
        let kind = HostStatusKind(status: status, offline: offline)
        var explanation: String?
        switch kind {
        case .connected, .none: return nil
        case .connecting: explanation = nil
        case .degraded:
            explanation = "The tunnel is up but the workspace's session sockets are down and retrying — the server may be restarting. The client reconnects on its own if the server stops answering."
        case .retry:
            if let s = retrySeconds {
                explanation = "Connection interrupted — retrying in \(s)s… (sessions keep running on the server)"
            } else {
                explanation = "Connection interrupted — retrying… (sessions keep running on the server)"
            }
        case .failed:
            explanation = "Not retrying automatically — hit Connect to try again. The connection log (⌃⌘L, or the log button under the list) has the full sequence."
        }
        var fraction: Double?
        if status.step == .pushing, status.pushTotal > 0 {
            fraction = min(1, Double(status.pushSent) / Double(status.pushTotal))
        }
        self.init(name: status.name, kind: kind, message: status.msg, explanation: explanation, diagnostics: status.stderr, pushFraction: fraction)
    }

    /// Whether the message is the macOS Local Network hint (X-41), which the
    /// window shows with a button to System Settings.
    public var isLocalNetworkHint: Bool { message.hasPrefix(LocalNetwork.hint.prefix(40)) }
}

/// The whole seconds left on a retry countdown, as main.js reports delays:
/// rounded up so the display never says 0s while the retry is still pending.
public func retryCountdownSeconds(remainingMs: Int64) -> Int {
    Int((remainingMs + 999) / 1000)
}
