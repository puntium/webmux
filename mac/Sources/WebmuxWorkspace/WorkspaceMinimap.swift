// The pane minimap (inside each host's pill in the toolbar): every column
// and pane of a workspace as a small block diagram, the focused pane
// highlighted, and — when the strip scrolls — an outline of the part of the
// strip on screen, so panes beyond the window are visible at a glance.
// Click a pane to focus it; a click elsewhere goes to the superview.
//
// Not to scale on purpose: column widths and pane heights keep their
// proportions, but every column gets at least `minColumn` points and the
// gaps are fixed (hairlines once squeezed), so a narrow column never vanishes. The viewport outline
// is mapped piecewise through the same columns and gaps.
//
// `attention`: pane ids drawn in the attention colour (for a later "this
// pane wants you" signal; nothing sets it yet).
import AppKit
import WebmuxLayout

/// The minimap's boxes, in its own (flipped) coordinates. Pure.
public struct MinimapLayout: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let id: String
        public let rect: CGRect
        public let focused: Bool
    }

    public let cells: [Cell]
    /// The on-screen part of the strip; nil when every column fits.
    public let viewport: CGRect?
    public let size: CGSize

    public static let defaultHeight: CGFloat = 18
    public static let defaultMaxWidth: CGFloat = 160
    public static let minColumn: CGFloat = 5
    public static let maxColumn: CGFloat = 36
    public static let columnGap: CGFloat = 2
    public static let rowGap: CGFloat = 1.5
    /// Room around the boxes for the viewport outline.
    public static let inset: CGFloat = 2

    public static func empty(height: CGFloat = defaultHeight) -> MinimapLayout {
        MinimapLayout(cells: [], viewport: nil, size: CGSize(width: minColumn + 2 * inset, height: height))
    }

    public var isEmpty: Bool { cells.isEmpty }

    init(cells: [Cell], viewport: CGRect?, size: CGSize) {
        self.cells = cells
        self.viewport = viewport
        self.size = size
    }

    /// The minimap of `layout` laid out as `geometry`, scrolled to `scroll`,
    /// `height` points tall and at most `maxWidth` wide.
    public init(layout: Layout, geometry: WorkspaceGeometry?, scroll: Double,
                height: CGFloat = defaultHeight, maxWidth: CGFloat = defaultMaxWidth) {
        guard let g = geometry, !layout.columns.isEmpty, g.strip.columns.count == layout.columns.count,
              g.stacks.count == layout.columns.count, g.viewportHeight > 0 else {
            self = .empty(height: height)
            return
        }
        let inset = Self.inset
        let inner = height - 2 * inset
        // Proportional widths at the strip's own aspect, clamped, then
        // squeezed to fit the max width.
        let sy = Double(inner) / g.viewportHeight
        var widths = g.strip.columns.map { min(Self.maxColumn, max(Self.minColumn, CGFloat($0.width * sy))) }
        var gap = Self.columnGap
        let total = widths.reduce(0, +)
        if total + CGFloat(widths.count - 1) * gap > maxWidth - 2 * inset {
            // Squeezed: hairline gaps, columns shrink to fit (never below 2 pt).
            gap = 1
            let room = maxWidth - 2 * inset - CGFloat(widths.count - 1) * gap
            let k = max(0, room) / total
            widths = widths.map { max(2, $0 * k) }
        }

        var cells: [Cell] = []
        var xs: [CGFloat] = []
        var x = inset
        for (ci, col) in layout.columns.enumerated() {
            xs.append(x)
            let w = widths[ci]
            let spans = g.stacks[ci].panes
            let sum = spans.reduce(0) { $0 + $1.height }
            let rowsH = inner - CGFloat(max(0, col.count - 1)) * Self.rowGap
            var y = inset
            for (ri, pane) in col.panes.enumerated() {
                let frac = sum > 0 && ri < spans.count ? CGFloat(spans[ri].height / sum) : 1 / CGFloat(col.count)
                let h = max(1, rowsH * frac)
                cells.append(Cell(id: pane.id, rect: CGRect(x: x, y: y, width: w, height: h), focused: pane.id == layout.focused))
                y += h + Self.rowGap
            }
            x += w + gap
        }
        let width = (x - gap + inset).rounded(.up)

        // Strip x → minimap x: linear inside a column, across a gap, and in
        // the padding before the first / after the last column.
        let cols = g.strip.columns
        func map(_ sx: Double) -> CGFloat {
            if sx <= cols[0].x { return xs[0] - (sx < cols[0].x ? inset : 0) }
            for (i, c) in cols.enumerated() {
                if sx <= c.right {
                    return xs[i] + widths[i] * CGFloat((sx - c.x) / max(1, c.width))
                }
                if i + 1 < cols.count, sx < cols[i + 1].x {
                    return xs[i] + widths[i] + gap * CGFloat((sx - c.right) / max(1, cols[i + 1].x - c.right))
                }
            }
            return width - inset + (sx > cols[cols.count - 1].right ? inset : 0)
        }
        var viewport: CGRect?
        let left = scroll, right = scroll + g.strip.viewport
        if cols[0].x < left - 0.5 || cols[cols.count - 1].right > right + 0.5 {
            let l = map(left), r = map(right)
            viewport = CGRect(x: l, y: 0.5, width: max(2, r - l), height: height - 1)
        }
        self.init(cells: cells, viewport: viewport, size: CGSize(width: width, height: height))
    }

    /// The pane under a point.
    public func pane(at p: CGPoint) -> String? {
        cells.first { $0.rect.insetBy(dx: -1, dy: -1).contains(p) }?.id
    }
}

@MainActor
public final class WorkspaceMinimapView: NSView {
    /// The workspace shown; its view changes redraw the map.
    public weak var workspace: WorkspaceView? {
        didSet {
            if oldValue !== workspace { oldValue?.onViewportChange = nil }
            workspace?.onViewportChange = { [weak self] in self?.refresh() }
            refresh()
        }
    }
    /// Panes that want attention (drawn in `attentionColor`).
    public var attention: Set<String> = [] {
        didSet { if attention != oldValue { needsDisplay = true } }
    }
    /// A pane was clicked.
    public var onSelectPane: ((String) -> Void)?
    /// The map's height and width cap (points).
    public var mapHeight: CGFloat = MinimapLayout.defaultHeight {
        didSet { if mapHeight != oldValue { refresh() } }
    }
    public var maxMapWidth: CGFloat = MinimapLayout.defaultMaxWidth {
        didSet { if maxMapWidth != oldValue { refresh() } }
    }
    /// The focused pane in the accent colour (the workspace in front);
    /// otherwise a stronger grey.
    public var emphasized = true {
        didSet { if emphasized != oldValue { needsDisplay = true } }
    }
    /// The map changed (size or emptiness): the container may relayout.
    public var onMapChange: (() -> Void)?

    public private(set) var map = MinimapLayout.empty()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        toolTip = "Panes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override var intrinsicContentSize: NSSize { map.size }

    public func refresh() {
        let next: MinimapLayout
        if let w = workspace {
            // A workspace never shown has no geometry yet: lay it out at a
            // typical window size (the map is not to scale anyway).
            let g = w.geometry ?? (w.model.isEmpty ? nil : WorkspaceGeometry(
                layout: w.model, width: w.bounds.width > 0 ? w.bounds.width : 1400,
                height: w.bounds.height > 0 ? w.bounds.height : 900,
                cellPx: w.cellPx * max(0.1, w.zoom), settings: w.widthSettings))
            next = MinimapLayout(layout: w.model, geometry: g, scroll: w.scroll, height: mapHeight, maxWidth: maxMapWidth)
        } else {
            next = .empty(height: mapHeight)
        }
        guard next != map else { return }
        let changed = next.size != map.size || next.isEmpty != map.isEmpty
        if next.size != map.size { invalidateIntrinsicContentSize() }
        map = next
        needsDisplay = true
        if changed { onMapChange?() }
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Centre the map vertically in whatever height the toolbar gives.
        let dy = max(0, (bounds.height - map.size.height) / 2)
        let dx = max(0, (bounds.width - map.size.width) / 2)
        func place(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }

        let idle = NSColor.labelColor.withAlphaComponent(0.28)
        for c in map.cells {
            let color: NSColor
            if attention.contains(c.id) {
                color = .systemOrange
            } else if c.focused {
                color = emphasized ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.6)
            } else {
                color = idle
            }
            color.setFill()
            NSBezierPath(roundedRect: place(c.rect), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let v = map.viewport {
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let p = NSBezierPath(roundedRect: place(v).insetBy(dx: 0.5, dy: 0), xRadius: 2.5, yRadius: 2.5)
            p.lineWidth = 1
            p.stroke()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dy = max(0, (bounds.height - map.size.height) / 2)
        let dx = max(0, (bounds.width - map.size.width) / 2)
        if let id = map.pane(at: CGPoint(x: p.x - dx, y: p.y - dy)), let onSelectPane {
            onSelectPane(id)
        } else {
            super.mouseDown(with: event)
        }
    }
}
