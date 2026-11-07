// The toolbar's host switcher: one pill per live connection, coloured by its
// status (green connected, yellow connecting / degraded, red retrying /
// failed), with the host's name in small type above the minimap of its
// workspace's panes, so every host's layout is visible at once. Click a pill
// to bring its host to the front; click a pane in its minimap to bring the
// host to the front with that pane focused.
import AppKit
import WebmuxPanels
import WebmuxWorkspace

/// One switcher entry: a live connection (or the dev host).
struct HostEntry {
    var name: String
    var kind: HostStatusKind
    var active: Bool
    /// The host's workspace view (nil until the connection is up).
    var workspace: WorkspaceView?
}

@MainActor
final class HostPillsView: NSStackView {
    /// A pill clicked (host name).
    var onSelectHost: ((String) -> Void)?
    /// A pane in a pill's minimap clicked (host name, pane id).
    var onSelectPane: ((String, String) -> Void)?

    private(set) var pills: [HostPill] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        setHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuild to `entries`, reusing each host's pill (its minimap binding).
    func set(_ entries: [HostEntry]) {
        var next: [HostPill] = []
        for (i, e) in entries.enumerated() {
            let pill = pills.first { $0.name == e.name } ?? HostPill(name: e.name)
            pill.onSelect = { [weak self] in self?.onSelectHost?(e.name) }
            pill.onSelectPane = { [weak self] id in self?.onSelectPane?(e.name, id) }
            pill.update(e, shortcut: i < 9 ? i + 1 : nil)
            next.append(pill)
        }
        for old in pills where !next.contains(where: { $0 === old }) {
            old.minimap.workspace = nil
            removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        for (i, p) in next.enumerated() {
            if p.superview !== self {
                insertArrangedSubview(p, at: i)
            } else if arrangedSubviews.firstIndex(of: p) != i {
                removeArrangedSubview(p)
                insertArrangedSubview(p, at: i)
            }
        }
        pills = next
        invalidateIntrinsicContentSize()
    }

    func pill(named name: String) -> HostPill? { pills.first { $0.name == name } }
}

@MainActor
final class HostPill: NSView {
    static let height: CGFloat = 40
    static let mapHeight: CGFloat = 18

    private(set) var name: String
    private(set) var kind: HostStatusKind = .none
    private(set) var active = false
    let minimap = WorkspaceMinimapView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    var onSelect: (() -> Void)?
    var onSelectPane: ((String) -> Void)?

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        minimap.mapHeight = Self.mapHeight
        minimap.maxMapWidth = 140
        minimap.onSelectPane = { [weak self] id in self?.onSelectPane?(id) }
        minimap.onMapChange = { [weak self] in self?.updateMapShown() }

        // Name above map, centred; the stack sits centred in the pill so a
        // pill without a map shows its name in the middle.
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(minimap)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ e: HostEntry, shortcut: Int?) {
        name = e.name
        kind = e.kind
        active = e.active
        label.stringValue = e.name
        label.font = .systemFont(ofSize: 9, weight: e.active ? .semibold : .medium)
        if minimap.workspace !== e.workspace { minimap.workspace = e.workspace }
        minimap.emphasized = e.active
        let state = e.kind.stateText()
        toolTip = "\(e.name)" + (state.isEmpty ? "" : " — \(state)") + (shortcut.map { " (⌘\($0))" } ?? "")
        setAccessibilityLabel("\(e.name), \(state)")
        setAccessibilitySelected(e.active)
        updateMapShown()
        needsDisplay = true
    }

    private func updateMapShown() {
        let hide = minimap.map.isEmpty
        if minimap.isHidden != hide { minimap.isHidden = hide }
        superview?.invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        kind.color.withAlphaComponent(active ? 0.42 : 0.2).setFill()
        path.fill()
        if active {
            kind.color.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}
