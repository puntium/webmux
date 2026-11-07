// `PaneFrame`: the chrome around one pane (electron/ui/index.html `.pane`,
// gtk/ghostty/src/apprt/webmux/workspace/frame.zig): a title bar (kind icon,
// title, ✕) over the pane's own view, the 1 pt border with 8 pt corners, and
// the focus ring (L-23). The pane view is the frame's body and is never drawn
// into. The unfocused fade (L-24) is applied on the terminal's texture by the
// Terminal area; the frame only tells the pane its focus state.
//
// The frame is layer-backed and clips to its rounded bounds, which is what the
// workspace animates: a move is a Core Animation of this layer's position and
// bounds, so nothing inside is laid out per frame.
import AppKit
import WebmuxLayout

/// The colours of both schemes (index.html :root / [data-theme=light]). Looks
/// are not binding (deviation 1); these are the Electron values so the three
/// clients read alike.
public enum WorkspaceColors {
    public static func panel(dark: Bool) -> NSColor { dark ? rgb(0x1f, 0x1f, 0x2b) : rgb(0xf4, 0xf5, 0xf9) }
    public static func strip(dark: Bool) -> NSColor { dark ? rgb(0x16, 0x16, 0x1e) : rgb(0xdf, 0xe1, 0xe8) }
    public static func border(dark: Bool) -> NSColor { dark ? rgb(0x34, 0x34, 0x4a) : rgb(0xc4, 0xc8, 0xd8) }
    public static func accent(dark: Bool) -> NSColor { dark ? rgb(0x7a, 0xa2, 0xf7) : rgb(0x2e, 0x7d, 0xe9) }
    public static func text(dark: Bool) -> NSColor { dark ? rgb(0xc8, 0xc8, 0xd8) : rgb(0x34, 0x3b, 0x58) }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Whether an appearance is dark.
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

@MainActor
public final class PaneFrame: NSView {
    public let id: String
    public let kind: PaneKind
    public private(set) var isFocused = false
    /// The pane behind the body, if it is one (not a placeholder).
    public private(set) weak var pane: WorkspacePane?
    public private(set) var body: NSView?

    /// Any press inside the frame (app.js pointerdown capture → setFocus).
    var onPressed: (() -> Void)?
    /// A click on the bar (not ✕): keyboard focus into the content.
    var onBarClicked: (() -> Void)?
    var onClose: (() -> Void)?

    private let bar = BarView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)
    private var detached = false

    public static let barHeight: CGFloat = CGFloat(WorkspaceMetrics.titleBarHeight)

    public init(id: String, kind: PaneKind) {
        self.id = id
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = CGFloat(StripAnimation.paneRadius)
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        bar.onClick = { [weak self] in self?.onBarClicked?() }
        addSubview(bar)

        icon.image = NSImage(systemSymbolName: kind == .files ? "folder" : "terminal", accessibilityDescription: kind == .files ? "file browser" : "terminal")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        bar.addSubview(icon)

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.stringValue = id
        bar.addSubview(label)

        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = kind == .files ? "Close" : "Kill session"
        closeButton.setButtonType(.momentaryChange)
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        bar.addSubview(closeButton)
        bar.toolTip = kind == .files ? "file browser" : "session \(id)"

        applyColors()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }

    /// Parent the pane's view (or a placeholder, `pane` nil) as the body.
    public func setBody(_ view: NSView, pane: WorkspacePane?) {
        body?.removeFromSuperview()
        body = view
        self.pane = pane
        addSubview(view)
        needsLayout = true
    }

    public var title: String { label.stringValue }

    public func setTitle(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
    }

    /// Focus ring and (through the pane) fade. `k` is the fade strength for
    /// an unfocused pane (settings › unfocused fade / 100).
    public func setFocused(_ focused: Bool, fadeStrength k: Double) {
        if focused != isFocused {
            isFocused = focused
            applyColors()
        }
        pane?.setFocused(focused, fadeStrength: focused ? 0 : k)
    }

    /// The frame leaves the layout (closing animation, then gone): no more
    /// input, no more calls into the workspace.
    public func detach() {
        detached = true
        onPressed = nil
        onBarClicked = nil
        onClose = nil
        closeButton.isEnabled = false
    }

    // MARK: Appearance

    private func applyColors() {
        let dark = WorkspaceColors.isDark(effectiveAppearance)
        layer?.backgroundColor = WorkspaceColors.panel(dark: dark).cgColor
        layer?.borderColor = (isFocused ? WorkspaceColors.accent(dark: dark) : WorkspaceColors.border(dark: dark)).cgColor
        // L-23: 1 px plus a 1 px ring reads as 2 px; here the ring is the border itself.
        layer?.borderWidth = isFocused ? 2 : 1
        label.textColor = WorkspaceColors.text(dark: dark)
        closeButton.contentTintColor = WorkspaceColors.text(dark: dark)
        bar.layer?.backgroundColor = WorkspaceColors.panel(dark: dark).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let bh = min(Self.barHeight, h)
        bar.frame = NSRect(x: 0, y: 0, width: w, height: bh)
        let iconSize: CGFloat = 12
        icon.frame = NSRect(x: 8, y: (bh - iconSize) / 2, width: iconSize, height: iconSize)
        let closeW: CGFloat = 22
        closeButton.frame = NSRect(x: max(0, w - closeW - 2), y: 0, width: closeW, height: bh)
        let lx = 8 + iconSize + 5
        label.frame = NSRect(x: lx, y: (bh - 15) / 2, width: max(0, w - lx - closeW - 6), height: 15)
        body?.frame = NSRect(x: 0, y: bh, width: w, height: max(0, h - bh))
    }

    // MARK: Input

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if detached { return nil }
        let v = super.hitTest(point)
        // L-20: a press anywhere in the pane focuses it before the click is handled.
        if v != nil, let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .rightMouseDown || e.type == .otherMouseDown {
            onPressed?()
        }
        return v
    }

    @objc private func closeClicked() {
        onClose?()
    }

    /// The title bar: a click (not on ✕) moves keyboard focus into the content.
    final class BarView: NSView {
        var onClick: (() -> Void)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isFlipped: Bool { true }

        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p) { onClick?() }
        }
    }
}
