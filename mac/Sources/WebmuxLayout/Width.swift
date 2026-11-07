// The width rule and the strip's geometry, as pure functions of the
// viewport, the cell width, the per-pane chrome and the min/max terminal
// width settings. Port of gtk/ghostty/src/webmux/layout/width.zig, itself a
// port of app.js `columnWidths` / `applyColumnWidths`, of the stylesheet
// that turns its two numbers into boxes (index.html: `#layout` is a flex
// row with `gap: 6px; padding: 6px; justify-content: safe center`,
// `.column` is `flex: 1 0 min(--col-min, 100%); max-width: --col-max`,
// `.column.full` is `flex-basis: 100%; max-width: 100%`), and of
// `revealFocusedNow` / `scrollStripTo` / `chaseStripEnd`.
//
// Coordinates are in "strip space": x from the strip's left edge,
// unscrolled (what app.js reads as `offsetLeft`); y from its top edge.
// What the browser rounds (offsetLeft, scrollWidth) is kept fractional
// here except where app.js rounds explicitly (the scroll target).
//
// Zoom: the model takes the cell width as given. The caller passes the
// zoomed cell width (and, if it scales the chrome too, scaled metrics);
// fewer columns then fit the same viewport, which is what the Electron
// page's CSS zoom does.

import Foundation

/// The CSS constants the arithmetic depends on (index.html, app.js).
public struct StripMetrics: Sendable, Equatable {
    /// Horizontal pixels a pane spends beyond its cells. app.js
    /// PANE_CHROME_PX: pane border (2) + term-holder padding (8) + xterm's
    /// scrollbar (10) + rounding slack (4). The native pane passes its own.
    public var paneChromePx: Double = 2 + 8 + 10 + 4
    /// `#layout` padding, on all four sides (STRIP_PAD_PX).
    public var stripPadPx: Double = 6
    /// `#layout` gap between columns (COL_GAP_PX).
    public var colGapPx: Double = 6
    /// `.divider` height.
    public var dividerPx: Double = 6
    /// `.divider` margin, above and below.
    public var dividerMarginPx: Double = 1
    /// A stacked pane's fixed height that its flex weight does not share:
    /// `.pane`'s 1 px top and bottom border (its basis is 0, so the border
    /// box starts at the border and the free space is shared on top).
    public var paneBorderPx: Double = 2

    public init(paneChromePx: Double = 2 + 8 + 10 + 4, stripPadPx: Double = 6, colGapPx: Double = 6, dividerPx: Double = 6, dividerMarginPx: Double = 1, paneBorderPx: Double = 2) {
        self.paneChromePx = paneChromePx
        self.stripPadPx = stripPadPx
        self.colGapPx = colGapPx
        self.dividerPx = dividerPx
        self.dividerMarginPx = dividerMarginPx
        self.paneBorderPx = paneBorderPx
    }

    /// Pane-to-pane distance in a stack (app.js STACK_GAP_PX = 8).
    public var stackGap: Double { dividerPx + 2 * dividerMarginPx }
}

/// settings.js: the two width settings in terminal cells, defaults 90 and
/// 200, each clamped to 40…400 and max never below min.
public struct WidthSettings: Sendable, Equatable {
    public var minCols: Int = 90
    public var maxCols: Int = 200

    public static let lowest = 40
    public static let highest = 400

    public init(minCols: Int = 90, maxCols: Int = 200) {
        self.minCols = minCols
        self.maxCols = maxCols
    }

    /// settings.js `sanitize` for these two fields (already integers here).
    public var sanitized: WidthSettings {
        let lo = min(max(minCols, WidthSettings.lowest), WidthSettings.highest)
        let hi = max(lo, min(max(maxCols, WidthSettings.lowest), WidthSettings.highest))
        return WidthSettings(minCols: lo, maxCols: hi)
    }
}

public struct ColumnWidths: Sendable, Equatable {
    /// How many columns fit side by side at the minimum: the most the
    /// strip ever shows whole at once.
    public let fit: Int
    /// `--col-min`: the width of a column when the strip is full (the
    /// strip's width split `fit` ways, at least the cell minimum, at most
    /// `max`). Integer pixels.
    public let min: Double
    /// `--col-max`: the widest a column grows when fewer than `fit` share
    /// the strip. Integer pixels when the cell width times maxCols rounds so.
    public let max: Double

    /// app.js `columnWidths(stripWidth, cellPx, minCols, maxCols)`, same
    /// float operations in the same order, so the same results bit for bit.
    public init(stripWidth: Double, cellPx: Double, settings: WidthSettings = WidthSettings(), metrics m: StripMetrics = StripMetrics()) {
        func cellsPx(_ cols: Int) -> Double { (Double(cols) * cellPx).rounded(.up) + m.paneChromePx }
        let minW = cellsPx(settings.minCols)
        let maxW = Swift.max(minW, cellsPx(settings.maxCols))
        let inner = stripWidth - 2 * m.stripPadPx
        let fitF = Swift.max(1, ((inner + m.colGapPx) / (minW + m.colGapPx)).rounded(.down))
        let fit = fitF.isFinite && fitF < 1e9 ? Int(fitF) : 1
        let share = ((inner - Double(fit - 1) * m.colGapPx) / Double(fit)).rounded(.down)
        self.fit = fit
        self.min = Swift.min(maxW, Swift.max(minW, share))
        self.max = maxW
    }
}

public struct ColumnBox: Sendable, Equatable {
    public var x: Double
    public var width: Double
    public var right: Double { x + width }
}

public struct StripGeometry: Sendable, Equatable {
    public let widths: ColumnWidths
    public let viewport: Double
    /// One per column, in order.
    public let columns: [ColumnBox]
    /// The strip's scrollable width (`scrollWidth`): the last column's right
    /// edge plus the end padding, never less than the viewport.
    public let scrollWidth: Double
    /// Largest scroll offset (`scrollWidth - clientWidth`), rounded as the
    /// browser's integer scrollWidth is.
    public let maxScroll: Double
    /// Whether the columns overflow the viewport (the strip scrolls).
    public let overflows: Bool
    /// The strip padding the geometry was laid out with (app.js
    /// revealFocusedNow's `pad`, chaseStripEnd's STRIP_PAD_PX).
    public let stripPad: Double

    /// Where every column goes, given each column's full flag (`layout.fullFlags`,
    /// `snapshot.fullFlags`). This is the CSS flex algorithm for the rule
    /// above: each column's base size is `min(widths.min, inner)` (a full
    /// one: `inner`), with no shrink; when they and their gaps leave free
    /// space, it is shared equally (flex-grow 1) with each column capped at
    /// `widths.max` (a full one at `inner`), and whatever is still left over
    /// centres the columns; when they overflow, they keep their base size
    /// and start at the left padding (`safe center`).
    public init(fullFlags: [Bool], viewport: Double, cellPx: Double, settings: WidthSettings = WidthSettings(), metrics m: StripMetrics = StripMetrics()) {
        let widths = ColumnWidths(stripWidth: viewport, cellPx: cellPx, settings: settings, metrics: m)
        let n = fullFlags.count
        let inner = max(0, viewport - 2 * m.stripPadPx)
        let gaps = n > 0 ? Double(n - 1) * m.colGapPx : 0

        // Base sizes (= hypothetical sizes: min ≤ max, so the cap never bites).
        var boxWidth = fullFlags.map { $0 ? inner : min(widths.min, inner) }
        var used = gaps
        for w in boxWidth { used += w }

        if inner - used > 0 {
            // Grow: resolve flexible lengths with max-width violations frozen
            // (CSS Flexbox §9.7, every flex-grow 1, every min-width 0).
            let base = boxWidth
            var frozen = [Bool](repeating: false, count: n)
            while true {
                var unfrozen = 0
                var space = inner - gaps
                for k in 0..<n {
                    if frozen[k] {
                        space -= boxWidth[k]
                    } else {
                        space -= base[k]
                        unfrozen += 1
                    }
                }
                if unfrozen == 0 { break }
                let share = space / Double(unfrozen)
                var violation: Double = 0
                for k in 0..<n where !frozen[k] {
                    let cap = fullFlags[k] ? inner : widths.max
                    let target = base[k] + share
                    boxWidth[k] = min(target, cap)
                    violation += boxWidth[k] - target
                }
                if violation >= 0 { break } // no column hit its cap: done
                for k in 0..<n where !frozen[k] {
                    let cap = fullFlags[k] ? inner : widths.max
                    if base[k] + share > cap { frozen[k] = true }
                }
            }
        }

        var total = gaps
        for w in boxWidth { total += w }
        let leftover = inner - total
        var x = m.stripPadPx + max(0, leftover / 2)
        var boxes: [ColumnBox] = []
        boxes.reserveCapacity(n)
        for w in boxWidth {
            boxes.append(ColumnBox(x: x, width: w))
            x += w + m.colGapPx
        }
        let contentEnd = boxes.last.map { $0.right + m.stripPadPx } ?? 0
        let scrollWidth = max(viewport, contentEnd)
        self.widths = widths
        self.viewport = viewport
        self.columns = boxes
        self.scrollWidth = scrollWidth
        self.maxScroll = max(0, scrollWidth.rounded() - viewport)
        self.overflows = leftover < 0
        self.stripPad = m.stripPadPx
    }

    public init(layout: Layout, viewport: Double, cellPx: Double, settings: WidthSettings = WidthSettings(), metrics: StripMetrics = StripMetrics()) {
        self.init(fullFlags: layout.fullFlags, viewport: viewport, cellPx: cellPx, settings: settings, metrics: metrics)
    }

    public init(snapshot: LayoutSnapshot, viewport: Double, cellPx: Double, settings: WidthSettings = WidthSettings(), metrics: StripMetrics = StripMetrics()) {
        self.init(fullFlags: snapshot.fullFlags, viewport: viewport, cellPx: cellPx, settings: settings, metrics: metrics)
    }

    /// app.js `scrollStripTo`'s clamp: round, then keep within 0…maxScroll.
    public func clampScroll(_ target: Double) -> Double {
        max(0, min(target.rounded(), maxScroll))
    }

    /// app.js `revealFocusedNow`: the scroll offset that shows column `col`
    /// in full (with the strip padding either side) moving the minimum
    /// distance from `current` (the in-flight scroll target if the strip is
    /// already animating, else the scroll offset), never re-centring a
    /// column already on screen. Clamped like `scrollStripTo`.
    public func revealTarget(column col: Int, current: Double) -> Double {
        guard col >= 0, col < columns.count else { return clampScroll(current) }
        let box = columns[col]
        let left = box.x - stripPad
        let right = box.right + stripPad
        var target = current
        if left < target {
            target = left
        } else if right > target + viewport {
            target = right - viewport
        }
        return clampScroll(target)
    }

    /// app.js `chaseStripEnd`: after a structural change, a strip scrolled
    /// past its new end eases back to it. Returns the new target, or nil
    /// when `scroll` is within range.
    public func endChaseTarget(scroll: Double) -> Double? {
        guard let last = columns.last else { return nil }
        let maxEnd = max(0, last.right + stripPad - viewport)
        return scroll > maxEnd ? clampScroll(maxEnd) : nil
    }
}

/// app.js SCROLL_TAU_MS: the strip's scroll chase time constant.
public let scrollTauMs: Double = 60

public struct ChaseStep: Sendable, Equatable {
    /// The new (fractional) scroll position; the strip shows it rounded.
    public let pos: Double
    /// Arrived: `pos` is the target and the chase is over.
    public let done: Bool

    /// One frame of app.js `chaseStep`: an exponential approach to `target`
    /// (each frame covers 1 − e^(−dt/τ) of what is left, at least 1 px),
    /// `dt` capped at 100 ms so a stalled frame does not teleport; within
    /// 0.5 px it lands on the target and is done. A new target mid-flight
    /// just goes into the next call.
    public init(pos: Double, target: Double, dtMs: Double) {
        let dt = min(dtMs, 100)
        let diff = target - pos
        if abs(diff) < 0.5 {
            self.pos = target
            self.done = true
            return
        }
        let k = 1 - exp(-dt / scrollTauMs)
        let sign: Double = diff > 0 ? 1 : -1
        self.pos = pos + sign * max(abs(diff) * k, min(1, abs(diff)))
        self.done = false
    }
}

// MARK: Stacks

public struct Span: Sendable, Equatable {
    public let y: Double
    public let height: Double
    public var bottom: Double { y + height }
}

public struct StackGeometry: Sendable, Equatable {
    /// One per pane, top to bottom.
    public let panes: [Span]
    /// One per divider: divider i sits between panes i and i+1.
    public let dividers: [Span]

    /// Heights within a column: the column fills the strip's height minus
    /// its padding; dividers take `stackGap` each; every pane has its
    /// border, and the panes share what is left by their weights,
    /// normalised (app.js paneFlex: `flex: w/sum 1 0`). A column too short
    /// for that leaves each pane at its border (no shrink below it; the
    /// overflow is clipped). `stripHeight` is the strip's height less any
    /// horizontal scrollbar that takes room (Chromium's classic scrollbar
    /// takes 15 px when the strip overflows; an overlay scrollbar takes none).
    public init(sizes: [Double], stripHeight: Double, metrics m: StripMetrics = StripMetrics()) {
        let n = sizes.count
        let dividerCount = max(n - 1, 0)
        var sum = sizes.reduce(0, +)
        if sum == 0 { sum = 1 }
        let colHeight = max(0, stripHeight - 2 * m.stripPadPx)
        let fixed = Double(dividerCount) * m.stackGap + Double(n) * m.paneBorderPx
        let free = max(0, colHeight - fixed)
        var panes: [Span] = []
        var dividers: [Span] = []
        panes.reserveCapacity(n)
        dividers.reserveCapacity(dividerCount)
        var y = m.stripPadPx
        for (i, w) in sizes.enumerated() {
            let span = Span(y: y, height: m.paneBorderPx + free * (w / sum))
            panes.append(span)
            y = span.bottom
            if i + 1 < n {
                dividers.append(Span(y: y + m.dividerMarginPx, height: m.dividerPx))
                y += m.stackGap
            }
        }
        self.panes = panes
        self.dividers = dividers
    }

    /// `spanPx` for `Layout.dragDivider`: from the top of pane i to the
    /// bottom of pane i+1. Nil for an out-of-range divider.
    public func dividerSpan(_ i: Int) -> Double? {
        guard i >= 0, i + 1 < panes.count else { return nil }
        return panes[i + 1].bottom - panes[i].y
    }

    /// `offsetPx` for `Layout.dragDivider` from a pointer y in strip space.
    public func dividerOffset(_ i: Int, pointerY: Double) -> Double? {
        guard i >= 0, i + 1 < panes.count else { return nil }
        return pointerY - panes[i].y
    }
}
