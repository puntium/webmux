// The horizontal divider between stacked panes (L-29, L-30): 6 pt tall with
// 1 pt margins (the stack gap is 8), radius 3, border colour, accent on hover
// and while dragging, row-resize cursor. A drag re-splits the two panes it
// separates; the pointer's own y (in strip space) is reported on every move
// because the divider itself moves under the pointer.
import AppKit

@MainActor
final class DividerView: NSView {
    var col = 0
    var row = 0
    /// Final box, snapped, strip space.
    var box = Box()
    var flight: Flight?

    /// Pointer y in strip space at each step; `began`/`ended` bracket a drag.
    var onDragBegan: ((Double) -> Void)?
    var onDragMoved: ((Double) -> Void)?
    var onDragEnded: (() -> Void)?

    private var hot = false
    private var dragging = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 6))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = CGFloat(StripAnimation.dividerRadius)
        layer?.masksToBounds = true
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func applyColors() {
        let dark = WorkspaceColors.isDark(effectiveAppearance)
        layer?.backgroundColor = ((hot || dragging) ? WorkspaceColors.accent(dark: dark) : WorkspaceColors.border(dark: dark)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseEntered(with event: NSEvent) {
        hot = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        hot = false
        applyColors()
    }

    /// The pointer's y in the strip's (unscrolled) space.
    private func stripY(_ event: NSEvent) -> Double? {
        guard let strip = superview else { return nil }
        return Double(strip.convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        applyColors()
        onDragBegan?(stripY(event) ?? box.y + box.h / 2)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let y = stripY(event) else { return }
        onDragMoved?(y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        applyColors()
        onDragEnded?()
    }
}

/// A ghost of a shrinking element's shell (L-32): panel background, border,
/// focus ring if focused; it sits under the element and is clipped from the
/// old box down to the new one.
@MainActor
final class GhostView: NSView {
    var flight: Flight?

    init(pane: Bool, focused: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let dark = WorkspaceColors.isDark(NSApp.effectiveAppearance)
        layer?.cornerRadius = CGFloat(pane ? StripAnimation.paneRadius : StripAnimation.dividerRadius)
        layer?.masksToBounds = true
        if pane {
            layer?.backgroundColor = WorkspaceColors.panel(dark: dark).cgColor
            layer?.borderWidth = focused ? 2 : 1
            layer?.borderColor = (focused ? WorkspaceColors.accent(dark: dark) : WorkspaceColors.border(dark: dark)).cgColor
        } else {
            layer?.backgroundColor = WorkspaceColors.border(dark: dark).cgColor
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
