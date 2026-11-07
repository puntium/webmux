// The workspace's arithmetic without a window: the animation helpers
// (anim.zig's tests), the geometry against window sizes (geometry.zig's
// tests, L-15), and the chord table (PARITY § 5, macOS column).
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import WebmuxWorkspace
import WebmuxLayout

final class AnimationTests: XCTestCase {
    func testMoveEaseMatchesTheCSSCurve() {
        XCTAssertEqual(StripAnimation.moveEase(0), 0)
        XCTAssertEqual(StripAnimation.moveEase(1), 1)
        // cubic-bezier(0.4,0,0.2,1) at x=0.5 is ~0.774 (Material standard).
        XCTAssertEqual(StripAnimation.moveEase(0.5), 0.7743, accuracy: 0.002)
        var prev = 0.0
        for i in 0...20 {
            let y = StripAnimation.moveEase(Double(i) / 20)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-9)
            prev = y
        }
    }

    func testMoveDurationGrowsWithDistanceWithinBounds() {
        XCTAssertEqual(StripAnimation.moveDuration(travel: 0), 200)
        XCTAssertEqual(StripAnimation.moveDuration(travel: 600), 200)
        XCTAssertEqual(StripAnimation.moveDuration(travel: 1200), 200 * 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(StripAnimation.moveDuration(travel: 60000), 320)
        XCTAssertEqual(StripAnimation.moveDuration(travel: .nan), 200)
    }

    func testFlightTravelGrowsShrinksGhost() {
        let f = Flight(from: Box(x: 0, y: 0, w: 100, h: 50), to: Box(x: 10, y: 0, w: 300, h: 50))
        XCTAssertEqual(f.travel, 210)
        let g = Flight(from: Box(x: 0, y: 0, w: 100, h: 50), to: Box(x: 10, y: 0, w: 50, h: 100))
        XCTAssertTrue(g.grows && g.shrinks)
        XCTAssertEqual(g.ghostBox, Box(x: 10, y: 0, w: 100, h: 100))
        XCTAssertEqual(g.at(0.5), Box(x: 5, y: 0, w: 75, h: 75))
    }

    func testEntryBoxes() {
        let oldPane: (Slot) -> Box? = { $0.col == 0 ? Box(x: 6, y: 6, w: 300, h: 400) : nil }
        let oldColumn: (Int) -> Box? = { $0 == 0 ? Box(x: 6, y: 6, w: 300, h: 800) : nil }
        let to = Box(x: 312, y: 6, w: 300, h: 800)
        let n = Neighbour(id: "a", old: Slot(col: 0, row: 0))
        XCTAssertEqual(StripAnimation.entryBox(origin: .below(n), isPane: true, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 6, y: 414, w: 300, h: 0))
        XCTAssertEqual(StripAnimation.entryBox(origin: .below(n), isPane: false, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 6, y: 407, w: 300, h: 0))
        XCTAssertEqual(StripAnimation.entryBox(origin: .above(n), isPane: true, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 6, y: -2, w: 300, h: 0))
        XCTAssertEqual(StripAnimation.entryBox(origin: .afterColumn(0), isPane: true, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 312, y: 6, w: 0, h: 800))
        XCTAssertEqual(StripAnimation.entryBox(origin: .beforeColumn(0), isPane: true, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 0, y: 6, w: 0, h: 800))
        XCTAssertEqual(StripAnimation.entryBox(origin: .inPlace, isPane: true, to: to, oldPane: oldPane, oldColumn: oldColumn), Box(x: 312, y: 6, w: 0, h: 800))
    }

    func testExitCuts() {
        let from = Box(x: 6, y: 200, w: 300, h: 100)
        let alone = StripAnimation.exitCut(from: from, alone: true, aboveNew: nil, belowNew: nil)
        XCTAssertEqual(alone.right, 300)
        XCTAssertEqual(StripAnimation.exitClip(from: from, cut: alone, p: 1), Box(x: 6, y: 200, w: 0, h: 100))
        let st = StripAnimation.exitCut(from: from, alone: false, aboveNew: Box(x: 6, y: 6, w: 300, h: 244), belowNew: nil)
        XCTAssertEqual(st.top, 54)
        XCTAssertEqual(st.bottom, 46)
        let mid = StripAnimation.exitCut(from: from, alone: false, aboveNew: nil, belowNew: nil)
        XCTAssertEqual(mid.top, 50)
        let cl = StripAnimation.exitCut(from: from, alone: false, aboveNew: Box(x: 6, y: 6, w: 300, h: 900), belowNew: nil)
        XCTAssertEqual(cl.top, 100)
        XCTAssertEqual(cl.bottom, 0)
    }

    func testSnappedKeepsTouchingEdgesTouching() {
        let a = Box(x: 6.4, y: 0, w: 100.3, h: 10)
        let b = Box(x: a.right, y: 0, w: 50.6, h: 10)
        XCTAssertEqual(a.snapped.right, b.snapped.x)
    }
}

final class GeometryTests: XCTestCase {
    private func layout(_ build: (inout Layout) throws -> Void) throws -> Layout {
        var l = Layout()
        try build(&l)
        return l
    }

    /// L-15 at 1920 × 1200 with an 8 pt cell: px(90) = 744, inner 1908 → fit
    /// 2, share 951; max px(200) = 1624.
    func testStackAndLoneColumnAtLargeWindow() throws {
        let l = try layout { l in
            try l.newTerminal("a")
            try l.newTerminalBelow("b")
            try l.newTerminal("c")
        }
        let g = WorkspaceGeometry(layout: l, width: 1920, height: 1200, cellPx: 8, settings: WidthSettings())
        XCTAssertEqual(g.panes.count, 3)
        XCTAssertEqual(g.dividers.count, 1)
        XCTAssertEqual(g.strip.widths.fit, 2)
        XCTAssertEqual(g.strip.widths.min, 951)
        XCTAssertEqual(g.strip.widths.max, 1624)
        XCTAssertEqual(g.panes[0].box.w, 951)
        XCTAssertEqual(g.panes[0].box.x, 6)
        XCTAssertEqual(g.panes[2].box.x, 963)
        // Stack: column height 1188, one gap 8 → panes 590 each.
        XCTAssertEqual(g.panes[0].box.y, 6)
        XCTAssertEqual(g.panes[0].box.h, 590)
        XCTAssertEqual(g.dividers[0].box.y, 597)
        XCTAssertEqual(g.panes[1].box.y, 604)
        XCTAssertEqual(g.panes[1].box.bottom, 1194)
        XCTAssertFalse(g.strip.overflows)
        XCTAssertEqual(g.columnBox(0), Box(x: 6, y: 6, w: 951, h: 1188))
    }

    /// L-15 in a 1000 pt window: fit 1, every column 988 wide, the strip scrolls.
    func testOverflowScrollsAndTheClampHonoursAKeeper() throws {
        let l = try layout { l in
            for id in ["a", "b", "c", "d"] { try l.newTerminal(id) }
        }
        let g = WorkspaceGeometry(layout: l, width: 1000, height: 800, cellPx: 8, settings: WidthSettings())
        XCTAssertTrue(g.strip.overflows)
        XCTAssertEqual(g.strip.scrollWidth, 988 * 4 + 18 + 12)
        XCTAssertEqual(g.clampScroll(1e9, keeper: nil), 2982)
        XCTAssertEqual(g.panes[0].box.h, 788)
        XCTAssertEqual(g.clampScroll(1e9, keeper: 5000), 4000)
        XCTAssertEqual(g.clampScroll(-5, keeper: nil), 0)
        // A full column is exactly the strip's inner width (L-11).
        var f = l
        f.toggleFull()
        let gf = WorkspaceGeometry(layout: f, width: 1000, height: 800, cellPx: 8, settings: WidthSettings())
        XCTAssertEqual(gf.panes[3].box.w, 988)
    }

    /// Zoom (K-31): a wider cell means fewer columns fit (the rule follows).
    func testZoomedCellFitsFewerColumns() throws {
        let l = try layout { l in try l.newTerminal("a") }
        let g1 = WorkspaceGeometry(layout: l, width: 2400, height: 1000, cellPx: 8, settings: WidthSettings())
        let g2 = WorkspaceGeometry(layout: l, width: 2400, height: 1000, cellPx: 8 * 1.5, settings: WidthSettings())
        XCTAssertEqual(g1.strip.widths.fit, 3)
        XCTAssertEqual(g2.strip.widths.fit, 2)
    }
}

final class CommandTableTests: XCTestCase {
    private func key(_ chars: String, code: Int, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 1, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    func testEveryCommandHasOneEntry() {
        XCTAssertEqual(WorkspaceCommand.all.count, LayoutCommand.allCases.count)
        for c in LayoutCommand.allCases { XCTAssertNotNil(WorkspaceCommand.entry(for: c), c.name) }
        XCTAssertEqual(WorkspaceCommand.entry(for: .newTerminalBelow)?.primary.display, "⌥⌘↩")
        XCTAssertEqual(WorkspaceCommand.entry(for: .focusLeft)?.primary.display, "⌘←")
    }

    func testChordsMatchTheMacColumn() {
        let up = KeyChord.upArrow
        XCTAssertEqual(WorkspaceCommand.match(key("\r", code: kVK_Return, [.command])), .newTerminal)
        XCTAssertEqual(WorkspaceCommand.match(key("\r", code: kVK_Return, [.command, .option])), .newTerminalBelow)
        XCTAssertEqual(WorkspaceCommand.match(key("\r", code: kVK_Return, [.command, .shift])), .newFiles)
        XCTAssertEqual(WorkspaceCommand.match(key("w", code: kVK_ANSI_W, [.command])), .closePane)
        XCTAssertEqual(WorkspaceCommand.match(key("f", code: kVK_ANSI_F, [.command])), .toggleFull)
        XCTAssertEqual(WorkspaceCommand.match(key("h", code: kVK_ANSI_H, [.command])), .focusLeft)
        XCTAssertEqual(WorkspaceCommand.match(key(up, code: kVK_UpArrow, [.command, .function, .numericPad])), .focusUp)
        XCTAssertEqual(WorkspaceCommand.match(key("[", code: kVK_ANSI_LeftBracket, [.command])), .consumeExpelLeft)
        XCTAssertEqual(WorkspaceCommand.match(key("]", code: kVK_ANSI_RightBracket, [.command])), .consumeExpelRight)
        XCTAssertEqual(WorkspaceCommand.match(key("h", code: kVK_ANSI_H, [.command, .option])), .moveColumnLeft)
        XCTAssertEqual(WorkspaceCommand.match(key(up, code: kVK_UpArrow, [.command, .option, .function])), .movePaneUp)
        // K-14's ⇧⌘ variants; ⇧ turns k into K, the physical key still matches.
        XCTAssertEqual(WorkspaceCommand.match(key("K", code: kVK_ANSI_K, [.command, .shift])), .movePaneUp)
        XCTAssertEqual(WorkspaceCommand.match(key("J", code: kVK_ANSI_J, [.command, .shift])), .movePaneDown)
        // Characters alone (a synthetic event without a key code) also match.
        XCTAssertEqual(WorkspaceCommand.match(key("l", code: 0xFF, [.command])), .focusRight)
    }

    /// K-17: combinations outside the table are not chords (and not swallowed).
    func testOutsideTheTableIsNotAChord() {
        XCTAssertNil(WorkspaceCommand.match(key("w", code: kVK_ANSI_W, [.command, .option])))
        XCTAssertNil(WorkspaceCommand.match(key("[", code: kVK_ANSI_LeftBracket, [.command, .option])))
        XCTAssertNil(WorkspaceCommand.match(key("w", code: kVK_ANSI_W, [.command, .control])))
        XCTAssertNil(WorkspaceCommand.match(key("w", code: kVK_ANSI_W, [.control, .shift])))
        XCTAssertNil(WorkspaceCommand.match(key("w", code: kVK_ANSI_W, [])))
        // ⌘⇧[ / ⌘⇧] are the app's host-cycling keys (K-25/K-26), not chords.
        XCTAssertNil(WorkspaceCommand.match(key("{", code: kVK_ANSI_LeftBracket, [.command, .shift])))
    }

    func testMenuItemCarriesTheCommand() {
        let item = WorkspaceCommand.entry(for: .closePane)!.menuItem(target: nil, action: nil)
        XCTAssertEqual(item.title, "Close Pane")
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item.representedObject as? String, "close-pane")
    }
}

final class MinimapTests: XCTestCase {
    private func geometry(_ l: Layout, width: Double) -> WorkspaceGeometry {
        WorkspaceGeometry(layout: l, width: width, height: 900, cellPx: 8, settings: WidthSettings())
    }

    func testEmptyLayoutIsTheEmptyMap() {
        XCTAssertEqual(MinimapLayout(layout: Layout(), geometry: nil, scroll: 0), .empty())
    }

    func testCellsFollowColumnsAndStacksAndMarkFocus() throws {
        var l = Layout()
        try l.newTerminal("a")
        try l.newTerminalBelow("b")
        try l.newTerminal("c")
        let m = MinimapLayout(layout: l, geometry: geometry(l, width: 3000), scroll: 0)
        XCTAssertEqual(m.cells.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(m.cells.filter(\.focused).map(\.id), ["c"])
        let a = m.cells[0].rect, b = m.cells[1].rect, c = m.cells[2].rect
        XCTAssertEqual(a.minX, b.minX)
        XCTAssertLessThan(a.maxY, b.minY)
        XCTAssertGreaterThan(c.minX, a.maxX)
        XCTAssertNil(m.viewport, "everything fits: no viewport outline")
        XCTAssertLessThanOrEqual(m.size.width, MinimapLayout.defaultMaxWidth + 1)
        XCTAssertEqual(m.pane(at: CGPoint(x: c.midX, y: c.midY)), "c")
    }

    func testOverflowShowsTheViewportAndItMovesWithTheScroll() throws {
        var l = Layout()
        for id in ["a", "b", "c", "d", "e"] { try l.newTerminal(id) }
        let g = geometry(l, width: 1000)
        XCTAssertTrue(g.strip.overflows)
        let start = MinimapLayout(layout: l, geometry: g, scroll: 0)
        let end = MinimapLayout(layout: l, geometry: g, scroll: g.strip.maxScroll)
        let v0 = try XCTUnwrap(start.viewport), v1 = try XCTUnwrap(end.viewport)
        XCTAssertLessThan(v0.minX, v1.minX)
        XCTAssertLessThan(v0.maxX, start.cells.last!.rect.maxX, "the last column is off screen at scroll 0")
        XCTAssertGreaterThanOrEqual(v1.maxX, end.cells.last!.rect.maxX)
    }

    func testManyColumnsFitTheMaxWidth() throws {
        var l = Layout()
        for i in 0..<40 { try l.newTerminal("t\(i)") }
        let m = MinimapLayout(layout: l, geometry: geometry(l, width: 1400), scroll: 0)
        XCTAssertEqual(m.cells.count, 40)
        XCTAssertLessThanOrEqual(m.size.width, MinimapLayout.defaultMaxWidth + 1)
    }
}
