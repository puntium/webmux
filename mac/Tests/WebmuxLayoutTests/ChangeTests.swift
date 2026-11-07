// Change-description tests (port of test_change.zig): each expected origin
// is what app.js animateStrip computes for the same command (`from` = the
// old box by pane id; else entryRect: pane above → pane below → column
// matched to the left → to the right → in place; dividers by index in the
// matched old column), and each leaving pane what removeTile passes as
// `leaving`.

import XCTest
@testable import WebmuxLayout

final class ChangeTests: XCTestCase {
    private func run(_ l: inout Layout, _ body: (inout Layout) throws -> Void) rethrows -> LayoutChange {
        try l.recording(body)
    }

    private func command(_ name: String) -> (inout Layout) -> Void {
        { l in
            guard let c = LayoutCommand(name: name) else { return XCTFail("no command \(name)") }
            _ = l.run(c)
        }
    }

    private func expectMoved(_ o: Origin?, _ col: Int, _ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(o, .moved(Slot(col: col, row: row)), file: file, line: line)
    }

    private func expectBelow(_ o: Origin?, _ id: String, _ col: Int, _ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(o, .below(Neighbour(id: id, old: Slot(col: col, row: row))), file: file, line: line)
    }

    private func expectAbove(_ o: Origin?, _ id: String, _ col: Int, _ row: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(o, .above(Neighbour(id: id, old: Slot(col: col, row: row))), file: file, line: line)
    }

    func testSnapshotIsACopyIndependentOfTheLayout() throws {
        var l = try LayoutSpec.build("a,b:2^|!c*")
        let s = l.snapshot()
        l = Layout()
        XCTAssertEqual(s.columns.count, 2)
        XCTAssertEqual(s.columns[0].ids[1], "b")
        XCTAssertEqual(s.columns[0].active, "b")
        XCTAssertEqual(s.columns[0].sizes[1], 2)
        XCTAssertTrue(s.columns[1].full)
        XCTAssertEqual(s.focused, "c")
        XCTAssertEqual(s.find("c"), Slot(col: 1, row: 0))
        XCTAssertNil(s.find("zz"))
        XCTAssertEqual(s.fullFlags, [false, true])
    }

    func testNewColumnOpensOutOfRightEdgeOfColumnToItsLeft() throws {
        var l = try LayoutSpec.build("a|b*|c")
        let c = try run(&l) { try $0.newTerminal("x") }
        XCTAssertTrue(c.structural)
        XCTAssertEqual(c.columns.count, 4)
        XCTAssertEqual(c.columns[0].from, 0)
        XCTAssertEqual(c.columns[1].from, 1)
        XCTAssertNil(c.columns[2].from)
        XCTAssertEqual(c.columns[3].from, 2)
        expectMoved(c.columns[0].panes[0].origin, 0, 0)
        expectMoved(c.columns[3].panes[0].origin, 2, 0)
        XCTAssertEqual(c.columns[2].panes[0].id, "x")
        XCTAssertEqual(c.columns[2].panes[0].origin, .afterColumn(1))
        XCTAssertTrue(c.columns[2].panes[0].origin.isFresh)
        XCTAssertFalse(c.columns[0].panes[0].origin.isFresh)
        XCTAssertEqual(c.leaving.count, 0)
        XCTAssertEqual(c.focused, "x")
    }

    func testVeryFirstPaneGrowsInPlace() throws {
        var l = Layout()
        let c = try run(&l) { try $0.newTerminal("a") }
        XCTAssertEqual(c.columns[0].panes[0].origin, .inPlace)
        XCTAssertNil(c.columns[0].from)
    }

    func testNewFirstColumnOpensOutOfLeftEdgeOfTheOneAfterIt() throws {
        var l = try LayoutSpec.build("a*")
        let c = try run(&l) { l in
            try l.newTerminal("x")
            l.moveColumn(.left)
        }
        XCTAssertEqual(c.columns[0].panes[0].origin, .beforeColumn(0))
        expectMoved(c.columns[1].panes[0].origin, 0, 0)
    }

    func testStackedBelowFocusedPaneOutOfItsBottomEdgeDividers() throws {
        var l = try LayoutSpec.build("a,b*|c")
        let c = try run(&l) { try $0.newTerminalBelow("x") }
        let col = c.columns[0]
        XCTAssertEqual(col.from, 0)
        expectMoved(col.panes[0].origin, 0, 0)
        expectMoved(col.panes[1].origin, 0, 1)
        expectBelow(col.panes[2].origin, "b", 0, 1)
        XCTAssertEqual(col.dividers.count, 2)
        expectMoved(col.dividers[0].origin, 0, 0) // the old a|b divider
        expectBelow(col.dividers[1].origin, "b", 0, 1) // new: under b
    }

    func testStackedMidStackPaneAboveWinsNewLowerDividerOpensOverPaneBelow() throws {
        var l = try LayoutSpec.build("a*,b")
        let c = try run(&l) { try $0.newTerminalBelow("x") }
        let col = c.columns[0]
        expectBelow(col.panes[1].origin, "a", 0, 0)
        expectMoved(col.panes[2].origin, 0, 1)
        expectMoved(col.dividers[0].origin, 0, 0)
        // Divider 1 sits between x (new) and b: x has no old box, so b's top.
        expectAbove(col.dividers[1].origin, "b", 0, 1)
    }

    func testNewPaneAtTopOfStackOpensOutOfTopOfPaneBelow() throws {
        // movePane after newTerminalBelow puts the fresh pane first.
        var l = try LayoutSpec.build("a*")
        let c = try run(&l) { l in
            try l.newTerminalBelow("x")
            l.movePane(.up)
        }
        expectAbove(c.columns[0].panes[0].origin, "a", 0, 0)
        expectAbove(c.columns[0].dividers[0].origin, "a", 0, 0)
    }

    func testClosingStackedPaneSqueezedBetweenNeighbours() throws {
        var l = try LayoutSpec.build("x|a,b*,c")
        let c = run(&l) { XCTAssertTrue($0.remove("b")) }
        XCTAssertEqual(c.leaving.count, 1)
        let x = c.leaving[0]
        XCTAssertEqual(x.id, "b")
        XCTAssertEqual(x.old, Slot(col: 1, row: 1))
        XCTAssertFalse(x.alone)
        XCTAssertEqual(x.above, "a")
        XCTAssertEqual(x.below, "c")
        // The surviving divider is the one that separated a from b.
        expectMoved(c.columns[1].dividers[0].origin, 1, 0)
        XCTAssertEqual(c.focused, "c")
        XCTAssertNotNil(c.leavingPane("b"))
        XCTAssertNil(c.pane("b"))
        XCTAssertEqual(c.pane("c")?.origin, .moved(Slot(col: 1, row: 2)))
    }

    func testClosingTopOrBottomPaneOfStackOneNeighbour() throws {
        var l = try LayoutSpec.build("a*,b")
        let c = run(&l) { XCTAssertTrue($0.remove("a")) }
        XCTAssertNil(c.leaving[0].above)
        XCTAssertEqual(c.leaving[0].below, "b")
        var m = try LayoutSpec.build("a,b*")
        let d = run(&m) { XCTAssertTrue($0.remove("b")) }
        XCTAssertEqual(d.leaving[0].above, "a")
        XCTAssertNil(d.leaving[0].below)
    }

    func testClosingLoneColumnWipedColumnsBeyondSlideIn() throws {
        var l = try LayoutSpec.build("a|b*|c")
        let c = run(&l) { XCTAssertTrue($0.remove("b")) }
        XCTAssertTrue(c.leaving[0].alone)
        XCTAssertEqual(c.leaving[0].old, Slot(col: 1, row: 0))
        XCTAssertEqual(c.columns[0].from, 0)
        XCTAssertEqual(c.columns[1].from, 2)
        expectMoved(c.columns[1].panes[0].origin, 2, 0)
    }

    func testLeavingNeighboursCountOnlyIfStillThere() throws {
        var l = try LayoutSpec.build("a,b,c*")
        let c = run(&l) { l in
            l.remove("a")
            l.remove("b")
        }
        XCTAssertEqual(c.leaving.count, 2)
        XCTAssertNil(c.leaving[0].above)
        XCTAssertNil(c.leaving[0].below) // b is gone too
        XCTAssertNil(c.leaving[1].above)
        XCTAssertEqual(c.leaving[1].below, "c")
    }

    func testMergeIntoNextColumnTheColumnThatHeldTheOthersKeepsIdentity() throws {
        var l = try LayoutSpec.build("a,b|c*")
        let c = run(&l, command("consume-expel-left"))
        XCTAssertEqual(c.columns.count, 1)
        XCTAssertEqual(c.columns[0].from, 0)
        expectMoved(c.columns[0].panes[2].origin, 1, 0)
        expectMoved(c.columns[0].dividers[0].origin, 0, 0)
        // A divider the old column did not have: under b, which was there.
        expectBelow(c.columns[0].dividers[1].origin, "b", 0, 1)
        XCTAssertEqual(c.leaving.count, 0)
    }

    func testMergeOfTwoLoneColumnsTieGoesToFirstOldColumn() throws {
        var l = try LayoutSpec.build("a|b*")
        let c = run(&l, command("consume-expel-left"))
        XCTAssertEqual(c.columns[0].from, 0)
        expectBelow(c.columns[0].dividers[0].origin, "a", 0, 0)
    }

    func testExpelSurvivorsKeepTheColumnPaneMovesToNewOne() throws {
        var l = try LayoutSpec.build("a,b*,c")
        let c = run(&l, command("consume-expel-right"))
        XCTAssertEqual(c.columns[0].from, 0)
        XCTAssertNil(c.columns[1].from)
        expectMoved(c.columns[1].panes[0].origin, 0, 1)
        expectMoved(c.columns[0].dividers[0].origin, 0, 0)
    }

    func testMatchColumnsGreedyByOverlapEachOldColumnOnce() throws {
        let a = try LayoutSpec.build("a,b,c|d*")
        let b = try LayoutSpec.build("a|b,c,d*")
        let match = LayoutChange.matchColumns(from: a.snapshot(), to: b.snapshot())
        // pairs: (n0,o0,1) (n1,o0,2) (n1,o1,1) → n1 takes o0 first; n0 gets none.
        XCTAssertEqual(match, [nil, 0])
    }

    func testFocusOnlyAndNoOpCommandsAreNotStructural() throws {
        var l = try LayoutSpec.build("a,b*|c")
        let c = run(&l, command("focus-right"))
        XCTAssertFalse(c.structural)
        XCTAssertEqual(c.focused, "c")
        let d = run(&l, command("move-column-right"))
        XCTAssertFalse(d.structural) // nothing past the end
        let e = run(&l, command("toggle-full"))
        XCTAssertTrue(e.structural)
        let f = run(&l, command("move-column-left"))
        XCTAssertTrue(f.structural)
        expectMoved(f.columns[0].panes[0].origin, 1, 0)
        XCTAssertEqual(f.columns[0].from, 1)
    }

    func testDividerDragIsStructuralWithEverythingInPlace() throws {
        var l = try LayoutSpec.build("a,b*")
        let c = run(&l) { XCTAssertTrue($0.dragDivider(column: 0, divider: 0, offsetPx: 100, spanPx: 400)) }
        XCTAssertTrue(c.structural)
        expectMoved(c.columns[0].panes[1].origin, 0, 1)
    }

    func testNewTwoPaneColumnWithNothingOldOpensBesideNeighbour() throws {
        var l = try LayoutSpec.build("a*")
        let c = try run(&l) { l in
            try l.newTerminal("x")
            try l.newTerminalBelow("y")
        }
        XCTAssertEqual(c.columns[1].panes[0].origin, .afterColumn(0))
        // y: the pane above (x) is new too, so the column rule applies.
        XCTAssertEqual(c.columns[1].panes[1].origin, .afterColumn(0))
        XCTAssertEqual(c.columns[1].dividers[0].origin, .afterColumn(0))
    }

    func testToggleFullOfStackedPaneMovesToNewColumnRightOfStack() throws {
        var l = try LayoutSpec.build("a,b*|c")
        let c = run(&l, command("toggle-full"))
        XCTAssertEqual(c.columns.count, 3)
        expectMoved(c.columns[1].panes[0].origin, 0, 1)
        XCTAssertEqual(c.columns[0].from, 0)
        XCTAssertNil(c.columns[1].from)
        XCTAssertEqual(c.columns[2].from, 1)
    }

    func testDiffOfIdenticalSnapshotsAndOfEmptyOnes() throws {
        let l = try LayoutSpec.build("a,b*|c")
        let c = LayoutChange.diff(from: l.snapshot(), to: l.snapshot())
        XCTAssertFalse(c.structural)
        XCTAssertEqual(c.leaving.count, 0)
        XCTAssertEqual(c.columns.count, 2)
        let e = LayoutChange.diff(from: Layout().snapshot(), to: Layout().snapshot())
        XCTAssertFalse(e.structural)
        XCTAssertEqual(e.columns.count, 0)
        XCTAssertNil(e.focused)
        // Everything closed at once: every pane leaves, nothing arrives.
        let gone = LayoutChange.diff(from: l.snapshot(), to: Layout().snapshot())
        XCTAssertTrue(gone.structural)
        XCTAssertEqual(gone.leaving.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(gone.leaving.map(\.alone), [false, false, true])
    }
}
