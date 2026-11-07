// The pane's vertical scrollbar (PARITY T-10): 10 pt wide on a transparent track,
// a pill thumb inset by 3 pt, in the theme's thumb colour and brighter under the
// pointer. It overlays the right edge of the terminal (the grid's spare width and
// padding), is driven by the core's `scrollbar` action (total / offset / len rows)
// and drives the viewport back with `scroll_to_row:N`. Hidden when there is no
// scrollback to scroll.
import AppKit

@MainActor
public final class TerminalScrollbar: NSView {
    nonisolated public static let width: CGFloat = 10
    nonisolated static let inset: CGFloat = 3
    nonisolated static let minThumb: CGFloat = 20

    /// Scrollback geometry in rows, as the core reports it.
    public struct State: Equatable {
        public var total: Int
        public var offset: Int
        public var len: Int

        public init(total: Int, offset: Int, len: Int) {
            self.total = total
            self.offset = offset
            self.len = len
        }

        public var scrollable: Bool { total > len && len > 0 }
    }

    /// The thumb geometry, pure for the tests. Coordinates are top-down.
    public struct Geometry: Equatable {
        public var trackTop: CGFloat
        public var trackHeight: CGFloat
        public var thumbTop: CGFloat
        public var thumbHeight: CGFloat

        public init(height: CGFloat, state: State) {
            trackTop = TerminalScrollbar.inset
            trackHeight = max(0, height - 2 * TerminalScrollbar.inset)
            guard state.scrollable, trackHeight > 0 else {
                thumbTop = trackTop
                thumbHeight = trackHeight
                return
            }
            let proportion = CGFloat(state.len) / CGFloat(state.total)
            thumbHeight = min(trackHeight, max(TerminalScrollbar.minThumb, trackHeight * proportion))
            let travel = trackHeight - thumbHeight
            let maxOffset = CGFloat(state.total - state.len)
            thumbTop = trackTop + (maxOffset > 0 ? travel * CGFloat(state.offset) / maxOffset : 0)
        }

        /// The first visible row for a thumb top at `thumbTop` (top-down).
        public func row(forThumbTop top: CGFloat, state: State) -> Int {
            let travel = trackHeight - thumbHeight
            guard travel > 0 else { return 0 }
            let f = min(1, max(0, (top - trackTop) / travel))
            return Int((f * CGFloat(state.total - state.len)).rounded())
        }
    }

    public var state = State(total: 0, offset: 0, len: 0) {
        didSet { if state != oldValue { update() } }
    }
    public var theme: TerminalTheme = .dark {
        didSet { needsDisplay = true }
    }
    /// Called with the row the user dragged the thumb to.
    public var onScrollToRow: ((Int) -> Void)?

    private var hovering = false
    private var dragging = false
    private var dragGrabOffset: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }

    private func update() {
        isHidden = !state.scrollable
        needsDisplay = true
    }

    var geometry: Geometry { Geometry(height: bounds.height, state: state) }

    var thumbRect: NSRect {
        let g = geometry
        return NSRect(x: Self.inset, y: g.thumbTop, width: bounds.width - 2 * Self.inset, height: g.thumbHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard state.scrollable else { return }
        let rect = thumbRect
        let color = (hovering || dragging) ? theme.scrollbarThumbHover : theme.scrollbarThumb
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        guard state.scrollable else { return }
        let p = convert(event.locationInWindow, from: nil)
        let thumb = thumbRect
        if thumb.contains(p) {
            dragGrabOffset = p.y - thumb.minY
        } else {
            // A click on the track centres the thumb on the pointer.
            dragGrabOffset = thumb.height / 2
            scroll(toThumbTop: p.y - dragGrabOffset)
        }
        dragging = true
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        scroll(toThumbTop: p.y - dragGrabOffset)
    }

    public override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
    }

    private func scroll(toThumbTop top: CGFloat) {
        let row = geometry.row(forThumbTop: top, state: state)
        guard row != state.offset else { return }
        onScrollToRow?(row)
    }

    /// Only the thumb and track take clicks; the wheel over the scrollbar goes
    /// to the terminal underneath.
    public override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, state.scrollable else { return nil }
        return super.hitTest(point)
    }
}
