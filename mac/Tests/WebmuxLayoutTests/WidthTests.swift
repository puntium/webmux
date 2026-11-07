// Width rule and geometry tests (port of test_width.zig).
//
// Where the numbers come from:
// - `ColumnWidths` cases: app.js `columnWidths` run under node with these
//   inputs (the function verbatim, with PANE_CHROME_PX / STRIP_PAD_PX /
//   COL_GAP_PX).
// - `StripGeometry` / `StackGeometry` cases: headless Chrome laying out
//   index.html's `#layout` / `.column` / `.pane` / `.divider` rules with
//   `--col-min` / `--col-max` set from that same `columnWidths`, measured
//   with getBoundingClientRect and scrollWidth. Chrome lays out in 1/64 px
//   units, hence the 0.02 px tolerance on fractional widths. Where the
//   strip overflowed, Chrome's classic horizontal scrollbar took 15 px of
//   height, so those stack cases pass the strip height minus 15.

import XCTest
@testable import WebmuxLayout

final class WidthTests: XCTestCase {
    private let m = StripMetrics()
    private let tol = 0.02

    private func settings(_ min: Int, _ max: Int) -> WidthSettings { WidthSettings(minCols: min, maxCols: max) }

    private func geometry(_ viewport: Double, _ cell: Double, _ s: WidthSettings, _ cols: [Bool]) -> StripGeometry {
        StripGeometry(fullFlags: cols, viewport: viewport, cellPx: cell, settings: s, metrics: m)
    }

    private func expectBoxes(_ g: StripGeometry, _ xs: [Double], _ ws: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(g.columns.count, xs.count, file: file, line: line)
        for (b, (x, w)) in zip(g.columns, zip(xs, ws)) {
            XCTAssertEqual(b.x, x, accuracy: tol, file: file, line: line)
            XCTAssertEqual(b.width, w, accuracy: tol, file: file, line: line)
        }
    }

    private let one = [false]
    private let two = [false, false]
    private let three = [false, false, false]
    private let five = [Bool](repeating: false, count: 5)
    private let six = [Bool](repeating: false, count: 6)

    func testColumnWidthsAppJsValues() {
        struct Case { let w: Double; let cell: Double; let min: Int; let max: Int; let fit: Int; let cmin: Double; let cmax: Double }
        let cases = [
            Case(w: 1920, cell: 7.8, min: 90, max: 200, fit: 2, cmin: 951, cmax: 1584),
            Case(w: 3840, cell: 8, min: 90, max: 200, fit: 5, cmin: 760, cmax: 1624),
            Case(w: 500, cell: 8, min: 90, max: 200, fit: 1, cmin: 744, cmax: 1624),
            Case(w: 2560, cell: 7.8125, min: 90, max: 200, fit: 3, cmin: 845, cmax: 1587),
            Case(w: 1920, cell: 8, min: 100, max: 100, fit: 2, cmin: 824, cmax: 824),
            Case(w: 1920, cell: 7.1, min: 90, max: 200, fit: 2, cmin: 951, cmax: 1444),
            Case(w: 1920, cell: 8.4, min: 90, max: 200, fit: 2, cmin: 951, cmax: 1704),
            Case(w: 2560, cell: 9.6, min: 80, max: 120, fit: 3, cmin: 845, cmax: 1176),
            Case(w: 1366, cell: 7.7, min: 90, max: 200, fit: 1, cmin: 1354, cmax: 1564),
            Case(w: 1000, cell: 8, min: 40, max: 40, fit: 2, cmin: 344, cmax: 344),
            Case(w: 3840, cell: 7.2, min: 40, max: 400, fit: 12, cmin: 313, cmax: 2904),
            // Narrower than one minimum column, down to nothing.
            Case(w: 100, cell: 8, min: 90, max: 200, fit: 1, cmin: 744, cmax: 1624),
            Case(w: 0, cell: 8, min: 90, max: 200, fit: 1, cmin: 744, cmax: 1624),
            // The step from one column to two: 2·744 + gap + 2·pad = 1506.
            Case(w: 1505, cell: 8, min: 90, max: 200, fit: 1, cmin: 1493, cmax: 1624),
            Case(w: 1506, cell: 8, min: 90, max: 200, fit: 2, cmin: 744, cmax: 1624),
        ]
        for c in cases {
            let got = ColumnWidths(stripWidth: c.w, cellPx: c.cell, settings: settings(c.min, c.max), metrics: m)
            XCTAssertEqual(got.fit, c.fit, "case \(c)")
            XCTAssertEqual(got.min, c.cmin, "case \(c)")
            XCTAssertEqual(got.max, c.cmax, "case \(c)")
        }
    }

    func testColumnWidthsDegenerateInputsNeverTrap() {
        for w in [Double.infinity, -.infinity, .nan] {
            let got = ColumnWidths(stripWidth: w, cellPx: 8, settings: WidthSettings(), metrics: m)
            XCTAssertEqual(got.fit, 1)
        }
        let zeroCell = ColumnWidths(stripWidth: 1920, cellPx: 0, settings: WidthSettings(), metrics: m)
        XCTAssertEqual(zeroCell.min, 24)
        XCTAssertEqual(zeroCell.fit, 63) // floor(1914 / 30)
    }

    func testSettingsSanitizedClampedMaxNeverBelowMin() {
        XCTAssertEqual(settings(30, 20).sanitized, settings(40, 40))
        XCTAssertEqual(settings(500, 450).sanitized, settings(400, 400))
        XCTAssertEqual(settings(100, 90).sanitized, settings(100, 100))
        XCTAssertEqual(WidthSettings().sanitized, settings(90, 200))
    }

    func testStripGeometry1920TwoFit() {
        let s = settings(90, 200)
        // One column grows to the maximum and sits centred.
        var g = geometry(1920, 7.8, s, one)
        expectBoxes(g, [168], [1584])
        XCTAssertEqual(g.scrollWidth, 1920)
        XCTAssertEqual(g.maxScroll, 0)
        XCTAssertFalse(g.overflows)

        g = geometry(1920, 7.8, s, two)
        expectBoxes(g, [6, 963], [951, 951])
        XCTAssertEqual(g.maxScroll, 0)

        // More than fit: minimum width, start-aligned, scrolls.
        g = geometry(1920, 7.8, s, three)
        expectBoxes(g, [6, 963, 1920], [951, 951, 951])
        XCTAssertEqual(g.scrollWidth, 2877)
        XCTAssertEqual(g.maxScroll, 957)
        XCTAssertTrue(g.overflows)

        g = geometry(1920, 7.8, s, [true])
        expectBoxes(g, [6], [1908])
        XCTAssertEqual(g.scrollWidth, 1920)

        g = geometry(1920, 7.8, s, [true, false])
        expectBoxes(g, [6, 1920], [1908, 951])
        XCTAssertEqual(g.scrollWidth, 2877)

        g = geometry(1920, 7.8, s, [false, true, false])
        expectBoxes(g, [6, 963, 2877], [951, 1908, 951])
        XCTAssertEqual(g.scrollWidth, 3834)
        XCTAssertEqual(g.maxScroll, 1914)
    }

    func testStripGeometry3840FiveFit() {
        let s = settings(90, 200)
        var g = geometry(3840, 8, s, one)
        expectBoxes(g, [1108], [1624])
        // Two grow to the maximum; the rest centres them.
        g = geometry(3840, 8, s, two)
        expectBoxes(g, [293, 1923], [1624, 1624])
        // Three share the strip below the maximum: no centring offset.
        g = geometry(3840, 8, s, three)
        expectBoxes(g, [6, 1284, 2562], [1272, 1272, 1272])
        // Five: the floor in columnWidths leaves 4 px, shared by flex-grow.
        g = geometry(3840, 8, s, five)
        expectBoxes(g, [6, 772.8, 1539.6, 2306.4, 3073.2], [760.8, 760.8, 760.8, 760.8, 760.8])
        XCTAssertEqual(g.maxScroll, 0)
        g = geometry(3840, 8, s, six)
        expectBoxes(g, [6, 772, 1538, 2304, 3070, 3836], [760, 760, 760, 760, 760, 760])
        XCTAssertEqual(g.scrollWidth, 4602)
        XCTAssertEqual(g.maxScroll, 762)
    }

    func testStripGeometryWindowNarrowerThanOneMinimumColumn() {
        let s = settings(90, 200)
        var g = geometry(500, 8, s, one)
        expectBoxes(g, [6], [488])
        XCTAssertFalse(g.overflows)
        g = geometry(500, 8, s, two)
        expectBoxes(g, [6, 500], [488, 488])
        XCTAssertEqual(g.scrollWidth, 994)
        // Degenerate viewport: nothing negative.
        g = geometry(4, 8, s, two)
        for b in g.columns { XCTAssertGreaterThanOrEqual(b.width, 0) }
    }

    func testStripGeometry2560FractionalShare() {
        let s = settings(90, 200)
        var g = geometry(2560, 7.8125, s, one)
        expectBoxes(g, [486.5], [1587])
        g = geometry(2560, 7.8125, s, two)
        expectBoxes(g, [6, 1283], [1271, 1271])
        g = geometry(2560, 7.8125, s, three)
        expectBoxes(g, [6, 857.333, 1708.667], [845.333, 845.333, 845.333])
    }

    func testStripGeometryMinEqualsMaxColumnsStayAtItAndCentre() {
        let s = settings(100, 100)
        var g = geometry(1920, 8, s, two)
        expectBoxes(g, [133, 963], [824, 824])
        g = geometry(1920, 8, s, one)
        expectBoxes(g, [548], [824])
    }

    func testStripGeometryEmptyStripAndALayoutsOwnColumns() throws {
        let g = geometry(1920, 8, WidthSettings(), [])
        XCTAssertEqual(g.columns.count, 0)
        XCTAssertEqual(g.maxScroll, 0)
        XCTAssertNil(g.endChaseTarget(scroll: 50))

        let l = try LayoutSpec.build("a|!b*|c")
        let h = StripGeometry(layout: l, viewport: 1920, cellPx: 7.8)
        expectBoxes(h, [6, 963, 2877], [951, 1908, 951])
        let k = StripGeometry(snapshot: l.snapshot(), viewport: 1920, cellPx: 7.8)
        XCTAssertEqual(h, k)
    }

    func testStripGeometryOtherMetrics() {
        let mm = StripMetrics(paneChromePx: 16, stripPadPx: 4, colGapPx: 8)
        // min = ceil(90·8)+16 = 736, max = 1616, inner = 1912;
        // fit = floor(1920/744) = 2; share = floor((1912−8)/2) = 952.
        let g = StripGeometry(fullFlags: two, viewport: 1920, cellPx: 8, settings: WidthSettings(), metrics: mm)
        XCTAssertEqual(g.widths.fit, 2)
        XCTAssertEqual(g.widths.min, 952)
        XCTAssertEqual(g.widths.max, 1616)
        expectBoxes(g, [4, 964], [952, 952])
        XCTAssertEqual(mm.stackGap, 8)
    }

    // MARK: Scroll targets (app.js revealFocusedNow / scrollStripTo / chaseStripEnd)

    func testRevealTargetMinimumMovementNeverRecentringVisibleColumn() {
        // Six 760 px columns in 3840 px: x = 6 + 766·i, max scroll 762.
        let g = geometry(3840, 8, WidthSettings(), six)
        // Last column from the start: its right edge + pad (4602) to the right edge.
        XCTAssertEqual(g.revealTarget(column: 5, current: 0), 762)
        // First column from the end: its left edge − pad (0).
        XCTAssertEqual(g.revealTarget(column: 0, current: 762), 0)
        // Already fully visible: stays.
        XCTAssertEqual(g.revealTarget(column: 2, current: 762), 762)
        XCTAssertEqual(g.revealTarget(column: 4, current: 0), 0)
        // Partly visible on the right: just enough.
        XCTAssertEqual(g.revealTarget(column: 5, current: 100), 762)
        // Partly visible on the left: just enough. Four 951 px columns in
        // 1920 px (x = 6 + 957·i, max scroll 1914): column 1 from 1000 → 957.
        let h = geometry(1920, 7.8, WidthSettings(), [Bool](repeating: false, count: 4))
        XCTAssertEqual(h.maxScroll, 1914)
        XCTAssertEqual(h.revealTarget(column: 1, current: 1000), 957)
        XCTAssertEqual(h.revealTarget(column: 2, current: 1000), 1000) // 1914…2877 within 1000…2920
        // Fractional current: scrollStripTo rounds.
        XCTAssertEqual(g.revealTarget(column: 2, current: 300.4), 300)
        // Out-of-range column: just the clamp.
        XCTAssertEqual(g.revealTarget(column: 9, current: 5000), 762)
        XCTAssertEqual(g.revealTarget(column: -1, current: 5000), 762)
    }

    func testRevealTarget1920ThreeColumnsAndAFullOne() {
        let g = geometry(1920, 7.8, WidthSettings(), three)
        XCTAssertEqual(g.revealTarget(column: 2, current: 0), 957)
        XCTAssertEqual(g.revealTarget(column: 1, current: 957), 957)
        XCTAssertEqual(g.revealTarget(column: 1, current: 0), 0)
        XCTAssertEqual(g.revealTarget(column: 0, current: 957), 0)
        let f = geometry(1920, 7.8, WidthSettings(), [false, true, false])
        // The full column fills the viewport exactly once revealed.
        XCTAssertEqual(f.revealTarget(column: 1, current: 0), 957)
        XCTAssertEqual(f.revealTarget(column: 1, current: 1914), 957)
        XCTAssertEqual(f.revealTarget(column: 2, current: 957), 1914)
    }

    func testRevealTargetColumnsThatFitNeverScroll() {
        let g = geometry(1920, 7.8, WidthSettings(), two)
        XCTAssertEqual(g.revealTarget(column: 1, current: 0), 0)
        XCTAssertEqual(g.revealTarget(column: 0, current: 500), 0) // stale offset clamps
    }

    func testEndChaseTargetStripScrolledPastNewEndEasesBack() {
        let g = geometry(1920, 7.8, WidthSettings(), two)
        XCTAssertEqual(g.endChaseTarget(scroll: 957), 0)
        let h = geometry(1920, 7.8, WidthSettings(), three)
        XCTAssertNil(h.endChaseTarget(scroll: 900))
        XCTAssertEqual(h.endChaseTarget(scroll: 1200), 957)
        let e = geometry(1920, 7.8, WidthSettings(), [])
        XCTAssertNil(e.endChaseTarget(scroll: 50))
    }

    func testChaseStepAppJsValues() {
        struct Case { let pos: Double; let target: Double; let dt: Double; let want: Double; let done: Bool }
        let cases = [
            Case(pos: 0, target: 957, dt: 16, want: 224.0065801850312, done: false),
            Case(pos: 0, target: 957, dt: 1000, want: 776.2460480844534, done: false), // dt capped at 100
            Case(pos: 957, target: 0, dt: 16, want: 732.9934198149688, done: false),
            Case(pos: 100, target: 100.4, dt: 16, want: 100.4, done: true),
            Case(pos: 100, target: 100.6, dt: 0, want: 100.6, done: false), // the 1 px floor, capped at the distance
            Case(pos: 100, target: 99, dt: 0, want: 99, done: false),
            Case(pos: 0, target: 1000, dt: 16.6667, want: 242.53529241687687, done: false),
        ]
        for c in cases {
            let r = ChaseStep(pos: c.pos, target: c.target, dtMs: c.dt)
            XCTAssertEqual(r.pos, c.want, accuracy: 1e-9, "case \(c)")
            XCTAssertEqual(r.done, c.done, "case \(c)")
        }
        // 0 → 957 at 16 ms frames: done on the 26th call (node).
        var pos: Double = 0
        var frames = 0
        while true {
            let r = ChaseStep(pos: pos, target: 957, dtMs: 16)
            frames += 1
            pos = r.pos
            if r.done { break }
        }
        XCTAssertEqual(frames, 26)
        XCTAssertEqual(pos, 957)
        XCTAssertEqual(scrollTauMs, 60)
    }

    func testClampScroll() {
        let g = geometry(1920, 7.8, WidthSettings(), three)
        XCTAssertEqual(g.clampScroll(-40), 0)
        XCTAssertEqual(g.clampScroll(4000), 957)
        XCTAssertEqual(g.clampScroll(12.5), 13)
    }

    // MARK: Stacks

    private func expectSpans(_ got: [Span], _ want: [(Double, Double)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.y, w.0, accuracy: tol, file: file, line: line)
            XCTAssertEqual(g.height, w.1, accuracy: tol, file: file, line: line)
        }
    }

    func testStackGeometryChromesPaneAndDividerBoxes() {
        // 600 px strip that overflowed (15 px scrollbar): column 573 px.
        var s = StackGeometry(sizes: [1, 1], stripHeight: 585, metrics: m)
        expectSpans(s.panes, [(6, 282.5), (296.5, 282.5)])
        expectSpans(s.dividers, [(289.5, 6)])

        s = StackGeometry(sizes: [1, 2, 3], stripHeight: 585, metrics: m)
        expectSpans(s.panes, [(6, 93.828), (107.828, 185.672), (301.5, 277.5)])
        expectSpans(s.dividers, [(100.828, 6), (294.5, 6)])

        // A lone survivor of a resized stack fills its column (normalised).
        s = StackGeometry(sizes: [0.3], stripHeight: 585, metrics: m)
        expectSpans(s.panes, [(6, 573)])
        XCTAssertEqual(s.dividers.count, 0)
        XCTAssertNil(s.dividerSpan(0))
        XCTAssertNil(s.dividerOffset(0, pointerY: 10))

        s = StackGeometry(sizes: [0.25, 0.5, 1, 0.25], stripHeight: 900, metrics: m)
        expectSpans(s.panes, [(6, 109), (123, 216), (347, 430), (785, 109)])
        expectSpans(s.dividers, [(116, 6), (340, 6), (778, 6)])
        // dragDivider inputs: span of divider 1 = pane 1 top → pane 2 bottom.
        XCTAssertEqual(s.dividerSpan(1) ?? -1, 777 - 123, accuracy: tol)
        XCTAssertEqual(s.dividerOffset(1, pointerY: 323) ?? -1, 200, accuracy: tol)

        // Too short for its dividers: panes keep their borders, no more.
        s = StackGeometry(sizes: [1, 1, 1], stripHeight: 30, metrics: m)
        expectSpans(s.panes, [(6, 2), (16, 2), (26, 2)])
        expectSpans(s.dividers, [(9, 6), (19, 6)])

        // Nothing to lay out.
        s = StackGeometry(sizes: [], stripHeight: 600, metrics: m)
        XCTAssertEqual(s.panes.count, 0)
        XCTAssertEqual(s.dividers.count, 0)
    }

    func testStackGeometryDrivesDragDividerLikeAppJsMakeDivider() throws {
        var l = try LayoutSpec.build("a,b*")
        let s = StackGeometry(sizes: l.columns[0].sizes, stripHeight: 600, metrics: m)
        // Column 588: panes (588 − 8 − 4)/2 + 2 = 290 each; span = 588.
        let span = try XCTUnwrap(s.dividerSpan(0))
        XCTAssertEqual(span, 588, accuracy: tol)
        // Pointer at y = 6 + 147 → ratio 0.25 of the pair's weight 2.
        let offset = try XCTUnwrap(s.dividerOffset(0, pointerY: 153))
        XCTAssertTrue(l.dragDivider(column: 0, divider: 0, offsetPx: offset, spanPx: span, minPx: Layout.minPanePx))
        expectSizes(l, 0, [0.5, 1.5])
    }
}
