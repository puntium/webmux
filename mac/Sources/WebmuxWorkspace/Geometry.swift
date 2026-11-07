// Where every pane and divider of a layout goes, in strip space, from the
// model's width rule and stack geometry (`WebmuxLayout.StripGeometry` /
// `StackGeometry`). Pure (no AppKit). Port of
// gtk/ghostty/src/apprt/webmux/workspace/geometry.zig. The view gives each
// pane its snapped box once and scrolls by moving the strip's origin.
import Foundation
import WebmuxLayout

public enum WorkspaceMetrics {
    /// The native pane's chrome for the width rule, as app.js PANE_CHROME_PX:
    /// the frame's border (2) + the terminal's own padding (4 each side: 8) +
    /// the scrollbar column xterm.js has (10) + rounding slack (4). Kept as the
    /// rule says even though Ghostty draws no scrollbar: it is a rule, not a
    /// measurement, and the three clients must agree on column widths.
    public static let strip = StripMetrics(paneChromePx: 2 + 8 + 10 + 4)

    /// A JetBrains Mono cell at 13 pt is 0.6 em = 7.8 pt; Ghostty rounds its
    /// cell to whole device pixels, so 8 at scale 1 and 7.5 at scale 2. Used
    /// until a terminal reports its own.
    public static let defaultCellPx: Double = 8

    /// The pane frame's title bar height (points).
    public static let titleBarHeight: Double = 22
}

public struct PaneSlot: Equatable, Sendable {
    public let col: Int
    public let row: Int
    /// Unsnapped (fractional) box.
    public let box: Box
}

public struct WorkspaceGeometry: Equatable, Sendable {
    public let strip: StripGeometry
    /// One per pane, in layout order (column by column, top to bottom).
    public let panes: [PaneSlot]
    /// One per divider, in layout order.
    public let dividers: [PaneSlot]
    /// Per column, its stack geometry (for divider drags).
    public let stacks: [StackGeometry]
    public let viewportHeight: Double

    /// Lay a layout out in a viewport of `width` × `height` points with the
    /// given cell width and width settings (sanitized here).
    public init(layout: Layout, width: Double, height: Double, cellPx: Double, settings: WidthSettings) {
        self.init(snapshot: layout.snapshot(), width: width, height: height, cellPx: cellPx, settings: settings)
    }

    public init(snapshot: LayoutSnapshot, width: Double, height: Double, cellPx: Double, settings: WidthSettings) {
        let m = WorkspaceMetrics.strip
        let s = settings.sanitized
        let strip = StripGeometry(snapshot: snapshot, viewport: width, cellPx: cellPx, settings: s, metrics: m)
        var panes: [PaneSlot] = []
        var dividers: [PaneSlot] = []
        var stacks: [StackGeometry] = []
        for (ci, col) in snapshot.columns.enumerated() {
            let st = StackGeometry(sizes: col.sizes, stripHeight: height, metrics: m)
            stacks.append(st)
            let cb = strip.columns[ci]
            for (row, span) in st.panes.enumerated() {
                panes.append(PaneSlot(col: ci, row: row, box: Box(x: cb.x, y: span.y, w: cb.width, h: span.height)))
            }
            for (row, span) in st.dividers.enumerated() {
                dividers.append(PaneSlot(col: ci, row: row, box: Box(x: cb.x, y: span.y, w: cb.width, h: span.height)))
            }
        }
        self.strip = strip
        self.panes = panes
        self.dividers = dividers
        self.stacks = stacks
        self.viewportHeight = height
    }

    public func columnBox(_ col: Int) -> Box? {
        guard col >= 0, col < strip.columns.count else { return nil }
        let c = strip.columns[col]
        let pad = strip.stripPad
        return Box(x: c.x, y: pad, w: c.width, h: max(0, viewportHeight - 2 * pad))
    }

    public func paneBox(col: Int, row: Int) -> Box? {
        panes.first { $0.col == col && $0.row == row }?.box
    }

    public func dividerBox(col: Int, row: Int) -> Box? {
        dividers.first { $0.col == col && $0.row == row }?.box
    }

    /// The rounded scroll width (what a browser reports as scrollWidth).
    public var extent: Double { strip.scrollWidth.rounded() }

    /// app.js scrollStripTo's clamp, against an extent that a running layout
    /// animation may hold open (`keeper`, the old scroll width).
    public func clampScroll(_ target: Double, keeper: Double?) -> Double {
        max(0, min(target.rounded(), maxScroll(keeper: keeper)))
    }

    /// The largest scroll offset the strip allows right now.
    public func maxScroll(keeper: Double?) -> Double {
        var m = strip.maxScroll
        if let k = keeper { m = max(m, k.rounded() - strip.viewport) }
        return max(0, m)
    }
}
