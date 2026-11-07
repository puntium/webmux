// What the workspace needs from a pane, and how it gets one. Port of the
// `Pane`, `PaneHost` and `PaneFactory` interfaces in
// gtk/ghostty/src/apprt/webmux/iface.zig. The workspace draws everything
// around a pane (title bar, border, focus ring: `PaneFrame`); the pane is the
// frame's body and is never drawn into.
//
// Two kinds exist (`PaneKind`, from WebmuxLayout): `.terminal` panes are built
// in (`TerminalPane`); `.files` panes come from the factory the Files area
// registers with `WorkspacePaneFactories.shared` at app start.
import AppKit
import WebmuxHost
import WebmuxLayout

/// The connection a workspace shows.
public struct WorkspaceConnection: Sendable, Equatable {
    /// The host's HTTP unix socket (the tunnel's local end, or the dev host).
    public let socketPath: String
    /// The profile's display name (status lines, logs).
    public let name: String
    /// The host slug (per-host state is keyed on it).
    public let slug: String

    public init(socketPath: String, name: String, slug: String) {
        self.socketPath = socketPath
        self.name = name
        self.slug = slug
    }

    public var api: HostAPI { HostAPI(socketPath: socketPath) }
}

/// What a pane tells its container. Set by the workspace right after the
/// pane is created; a pane never calls into it from inside a container call.
@MainActor
public protocol WorkspacePaneHost: AnyObject {
    /// The pane's title changed; read it with `pane.title`.
    func paneTitleDidChange(_ pane: WorkspacePane)
    /// The pane asks to be removed (its session exited or no longer exists;
    /// a file browser's own close). The container removes it on the next
    /// run-loop turn, never from inside this call. No DELETE is sent.
    func paneRequestsClose(_ pane: WorkspacePane)
    /// The pane's persistable state changed; the container schedules a save.
    func paneStateDidChange(_ pane: WorkspacePane)
    /// Keyboard focus entered the pane (click, programmatic).
    func paneDidTakeFocus(_ pane: WorkspacePane)
    /// Terminal panes: the link to the host went down (`false`) or came back.
    func pane(_ pane: WorkspacePane, linkDidChange up: Bool)
}

/// A pane as its container sees it. `view` is a view the workspace parents
/// (and thereby owns); removing it from the container ends the pane.
@MainActor
public protocol WorkspacePane: AnyObject {
    /// The layout's pane id: for terminals the host's session id, for file
    /// browsers the `files-…` id the layout model generated.
    var id: String { get }
    var kind: PaneKind { get }
    /// The pane's content. The container sizes it; nothing here may push back.
    var view: NSView { get }
    /// Current title, or nil if the pane has none yet (the frame then shows
    /// a seed title or the id).
    var title: String? { get }
    /// Set by the container once; the pane reports through it.
    var host: WorkspacePaneHost? { get set }

    /// Move keyboard focus into the pane.
    func focus()
    /// The container is hiding (`false`) or showing (`true`) the pane without
    /// unparenting it (another host in front, a new pane still on its way
    /// in). Lets a terminal pause rendering.
    func setShown(_ shown: Bool)
    /// The container is moving the pane to a new size (`true`) and has
    /// arrived (`false`). The view is given its final size when the move
    /// starts; a pane for which a new size is expensive (a terminal) keeps
    /// drawing at its old size until released and takes the new one then,
    /// once (deviation 69).
    func holdResize(_ hold: Bool)
    /// The frame's focus state changed (ring and the unfocused fade; the
    /// Terminal area applies the fade on the surface).
    func setFocused(_ focused: Bool, fadeStrength: Double)
    /// Width of one terminal cell in points at the current font and scale,
    /// or nil if this pane cannot say. The width rule needs one terminal's answer.
    var cellWidthPx: Double? { get }
    /// The pane's state to persist with the layout, as the text of one JSON
    /// object (what `LayoutPersistence` stores under `widgets`), or nil.
    var persistedState: String? { get }
    /// Restore a state saved by an earlier run (untrusted input).
    func restore(state: String)
    /// A horizontal scroll over this pane: true if the pane consumed it
    /// (a file browser's own Miller columns scroll first, L-27).
    func consumeHorizontalScroll(deltaX: Double) -> Bool
    /// The container is done with the pane: stop everything, release resources.
    func close()
}

public extension WorkspacePane {
    func setShown(_ shown: Bool) {}
    func holdResize(_ hold: Bool) {}
    func setFocused(_ focused: Bool, fadeStrength: Double) {}
    var cellWidthPx: Double? { nil }
    var persistedState: String? { nil }
    func restore(state: String) {}
    func consumeHorizontalScroll(deltaX: Double) -> Bool { false }
}

/// How a workspace gets panes. One factory per pane kind, registered by the
/// feature that implements the kind.
@MainActor
public protocol WorkspacePaneFactory: AnyObject {
    /// Create a pane for `id` of `kind` on `connection`. `state` is the JSON
    /// object text saved by `persistedState` in an earlier run, or nil. Throw
    /// to get a placeholder pane in the frame instead.
    func makePane(id: String, kind: PaneKind, state: String?, connection: WorkspaceConnection) throws -> WorkspacePane
}

/// The registry: `WorkspacePaneFactories.shared.register(.files, factory)`
/// at app start (the Files area's `FilesPaneView` behind a factory). The
/// terminal factory is registered by `WorkspaceController` with its
/// `Ghostty.App`.
@MainActor
public final class WorkspacePaneFactories {
    public static let shared = WorkspacePaneFactories()

    private var factories: [PaneKind: WorkspacePaneFactory] = [:]

    public init() {}

    public func register(_ kind: PaneKind, _ factory: WorkspacePaneFactory) {
        factories[kind] = factory
    }

    public func factory(for kind: PaneKind) -> WorkspacePaneFactory? {
        factories[kind]
    }
}

/// A pane kind with no factory (or one that failed): a box with a line of
/// text, so the pane still takes focus and the chords.
@MainActor
final class PlaceholderPane: WorkspacePane {
    let id: String
    let kind: PaneKind
    let view: NSView
    var title: String? { nil }
    weak var host: WorkspacePaneHost?

    init(id: String, kind: PaneKind, text: String) {
        self.id = id
        self.kind = kind
        let v = PlaceholderView()
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 12),
        ])
        view = v
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    func close() {}
}

final class PlaceholderView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
}
