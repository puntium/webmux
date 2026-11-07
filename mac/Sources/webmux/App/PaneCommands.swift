// The seam between the chrome and the workspace (PARITY W-43, W-44, K-01…K-15):
// menu items and toolbar buttons send these selectors down the responder
// chain with a nil target. The workspace view implements `PaneCommandTarget`
// at integration; until something in the chain does, AppKit's automatic
// validation leaves the items disabled (deviation 25 is the GTK precedent for
// "enabled and a no-op"; here the Mac convention — disabled — wins).
import AppKit
import WebmuxPanels

/// Implemented by the workspace (an `NSResponder` in the key window's chain:
/// the first responder's ancestors, then the window, then the window
/// controller, then the app delegate).
@MainActor @objc protocol PaneCommandTarget {
    // W-44 / K-01…K-05
    func newTerminal(_ sender: Any?)
    func newTerminalBelow(_ sender: Any?)
    func newFileBrowser(_ sender: Any?)
    func closePane(_ sender: Any?)
    func toggleFullWindow(_ sender: Any?)
    // K-06…K-09
    func focusLeft(_ sender: Any?)
    func focusRight(_ sender: Any?)
    func focusUp(_ sender: Any?)
    func focusDown(_ sender: Any?)
    // K-10, K-11
    func consumeExpelLeft(_ sender: Any?)
    func consumeExpelRight(_ sender: Any?)
    // K-12…K-15
    func moveColumnLeft(_ sender: Any?)
    func moveColumnRight(_ sender: Any?)
    func movePaneUp(_ sender: Any?)
    func movePaneDown(_ sender: Any?)
    // W-43 / K-31: on the visible host's workspace
    func reloadWorkspace(_ sender: Any?)
    func actualSize(_ sender: Any?)
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
}

extension MenuCommand {
    /// The responder-chain selector of a pane command (nil for the others).
    var paneSelector: Selector? {
        switch self {
        case .newTerminal: return #selector(PaneCommandTarget.newTerminal(_:))
        case .newTerminalBelow: return #selector(PaneCommandTarget.newTerminalBelow(_:))
        case .newFileBrowser: return #selector(PaneCommandTarget.newFileBrowser(_:))
        case .closePane: return #selector(PaneCommandTarget.closePane(_:))
        case .toggleFullWindow: return #selector(PaneCommandTarget.toggleFullWindow(_:))
        case .focusLeft: return #selector(PaneCommandTarget.focusLeft(_:))
        case .focusRight: return #selector(PaneCommandTarget.focusRight(_:))
        case .focusUp: return #selector(PaneCommandTarget.focusUp(_:))
        case .focusDown: return #selector(PaneCommandTarget.focusDown(_:))
        case .consumeExpelLeft: return #selector(PaneCommandTarget.consumeExpelLeft(_:))
        case .consumeExpelRight: return #selector(PaneCommandTarget.consumeExpelRight(_:))
        case .moveColumnLeft: return #selector(PaneCommandTarget.moveColumnLeft(_:))
        case .moveColumnRight: return #selector(PaneCommandTarget.moveColumnRight(_:))
        case .movePaneUp: return #selector(PaneCommandTarget.movePaneUp(_:))
        case .movePaneDown: return #selector(PaneCommandTarget.movePaneDown(_:))
        case .reload: return #selector(PaneCommandTarget.reloadWorkspace(_:))
        case .actualSize: return #selector(PaneCommandTarget.actualSize(_:))
        case .zoomIn: return #selector(PaneCommandTarget.zoomIn(_:))
        case .zoomOut: return #selector(PaneCommandTarget.zoomOut(_:))
        default: return nil
        }
    }
}

/// One connection's content in the main window: a container the Workspace
/// area fills with its view (`setContent`) once the connection is up. Until
/// then it shows a one-line placeholder (deviation 23). The chrome owns the
/// container; the workspace owns what is inside.
@MainActor
final class HostContentView: NSView {
    /// The profile name (follows renames).
    var name: String {
        didSet { updatePlaceholder() }
    }
    /// The local tunnel socket, set when the connection first reaches
    /// `connected` (nil before). The workspace talks to the host through it.
    var socketPath: String? {
        didSet { updatePlaceholder() }
    }
    /// The host slug for per-host state files (layout, file browser).
    var slug: String?
    /// The workspace's view, if set.
    private(set) var content: NSView?
    /// The workspace behind `content` (nil until the connection is up).
    var workspace: HostWorkspace?
    /// Pane count reported by the workspace (for the control socket; W-03).
    var paneCount = 0
    /// Whether the workspace reports its session sockets down (degraded, S-12).
    var isOffline = false

    private let placeholder = NSTextField(labelWithString: "")

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
        updatePlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasContent: Bool { content != nil }

    /// Install (or remove) the workspace's view, filling the container.
    func setContent(_ view: NSView?) {
        content?.removeFromSuperview()
        content = view
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: placeholder)
        }
        placeholder.isHidden = view != nil
    }

    private func updatePlaceholder() {
        placeholder.stringValue = socketPath == nil ? "\(name) — connecting…" : "\(name) — waiting for the workspace…"
    }

    /// Keyboard focus goes to the content (W-05).
    override func becomeFirstResponder() -> Bool {
        if let c = content, let w = window { return w.makeFirstResponder(c) }
        return super.becomeFirstResponder()
    }
}
