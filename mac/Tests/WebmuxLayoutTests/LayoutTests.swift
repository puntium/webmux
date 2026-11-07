// Command tests: every command, its ordinary case and each edge app.js
// handles (port of test_layout.zig). Expected layouts are derived by hand
// from app.js (cited per test); `LayoutSpec` documents the spec strings.

import XCTest
@testable import WebmuxLayout

final class LayoutTests: XCTestCase {
    // MARK: Spec helper sanity

    func testSpecRoundTripDefaultActiveAndFocus() throws {
        let l = try LayoutSpec.build("a,b|!c,d^|e")
        expectLayout(l, "a^*,b|!c,d^|e^")
        let m = try LayoutSpec.build("a,b^*|c:2,d:0.5")
        expectLayout(m, "a,b^*|c^,d")
        expectSizes(m, 1, [2, 0.5])
    }

    func testKindOfFilesPrefix() throws {
        XCTAssertEqual(PaneKind.of("files-abc"), .files)
        XCTAssertEqual(PaneKind.of("files"), .terminal)
        XCTAssertEqual(PaneKind.of("s1"), .terminal)
        let l = try LayoutSpec.build("s1|files-x")
        XCTAssertEqual(l.find("s1")?.sessionId, "s1")
        XCTAssertNil(l.find("files-x")?.sessionId)
        XCTAssertEqual(l.find("files-x")?.kind, .files)
    }

    // MARK: newTerminal / newFiles (app.js openInNewColumn)

    func testNewTerminalEmptyLayoutGetsFirstColumn() throws {
        var l = Layout()
        try l.newTerminal("s1")
        expectLayout(l, "s1^*")
        expectSizes(l, 0, [1])
        XCTAssertFalse(l.columns[0].full)
    }

    func testNewTerminalOpensRightOfFocusedColumnNotAtEnd() throws {
        var l = try LayoutSpec.build("a|b*|c")
        try l.newTerminal("x")
        expectLayout(l, "a^|b^|x^*|c^")
    }

    func testNewTerminalFocusedLastColumnAppends() throws {
        var l = try LayoutSpec.build("a|b*")
        try l.newTerminal("x")
        expectLayout(l, "a^|b^|x^*")
    }

    func testNewTerminalFromStackedPaneRightOfWholeColumn() throws {
        var l = try LayoutSpec.build("a,b^*|c")
        try l.newTerminal("x")
        expectLayout(l, "a,b^|x^*|c^")
    }

    func testNewTerminalNextToFullColumnWhichStaysFull() throws {
        var l = try LayoutSpec.build("!a*|b")
        try l.newTerminal("x")
        expectLayout(l, "!a^|x^*|b^")
    }

    func testNewTerminalRejectsDuplicateFilesPrefixedAndEmptyIds() throws {
        var l = try LayoutSpec.build("a|b*")
        XCTAssertThrowsError(try l.newTerminal("a")) { XCTAssertEqual($0 as? LayoutError, .duplicateId) }
        XCTAssertThrowsError(try l.newTerminal("files-1")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        XCTAssertThrowsError(try l.newTerminal("")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        expectLayout(l, "a^|b^*")
    }

    func testNewFilesPlacedLikeTerminalKeepsState() throws {
        var l = try LayoutSpec.build("a*|b")
        try l.newFiles("files-1", state: "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}")
        expectLayout(l, "a^|files-1^*|b^")
        let p = l.find("files-1")
        XCTAssertEqual(p?.kind, .files)
        XCTAssertEqual(p?.state, "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}")
        try l.newFiles("files-2", state: nil)
        XCTAssertNil(l.find("files-2")?.state)
    }

    func testNewFilesRejectsNonFilesIdBarePrefixAndNonObjectStates() throws {
        var l = try LayoutSpec.build("a*")
        XCTAssertThrowsError(try l.newFiles("s2")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        XCTAssertThrowsError(try l.newFiles("files-")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        XCTAssertThrowsError(try l.newFiles("files-1", state: "[1]")) { XCTAssertEqual($0 as? LayoutError, .invalidState) }
        XCTAssertThrowsError(try l.newFiles("files-1", state: "{\"a\":")) { XCTAssertEqual($0 as? LayoutError, .invalidState) }
        XCTAssertThrowsError(try l.newFiles("files-1", state: "\"x\"")) { XCTAssertEqual($0 as? LayoutError, .invalidState) }
        expectLayout(l, "a^*")
    }

    func testSetPaneStateFilesPanesOnlyObjectsOnly() throws {
        var l = try LayoutSpec.build("a*|files-1")
        try l.setPaneState("files-1", "{\"dir\":\"/tmp\"}")
        XCTAssertEqual(l.find("files-1")?.state, "{\"dir\":\"/tmp\"}")
        try l.setPaneState("files-1", "{\"dir\":\"/\"}")
        XCTAssertEqual(l.find("files-1")?.state, "{\"dir\":\"/\"}")
        XCTAssertThrowsError(try l.setPaneState("files-1", "nope")) { XCTAssertEqual($0 as? LayoutError, .invalidState) }
        XCTAssertEqual(l.find("files-1")?.state, "{\"dir\":\"/\"}")
        XCTAssertThrowsError(try l.setPaneState("a", "{}")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        XCTAssertThrowsError(try l.setPaneState("zz", "{}")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        try l.setPaneState("files-1", nil)
        XCTAssertNil(l.find("files-1")?.state)
    }

    func testStatesNestedDeeperThanCapAreRejected() throws {
        var l = try LayoutSpec.build("a*")
        let deepArray = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        XCTAssertThrowsError(try l.newFiles("files-1", state: "{\"a\":\(deepArray)}")) {
            XCTAssertEqual($0 as? LayoutError, .invalidState)
        }
        XCTAssertTrue(Layout.isValidState("{\"a\":[[[]]]}"))
        // Exactly at the cap: `{` is level 1, 63 arrays below it make 64.
        let atCap = "{\"a\":" + String(repeating: "[", count: 63) + String(repeating: "]", count: 63) + "}"
        XCTAssertTrue(Layout.isValidState(atCap))
        let overCap = "{\"a\":" + String(repeating: "[", count: 64) + String(repeating: "]", count: 64) + "}"
        XCTAssertFalse(Layout.isValidState(overCap))
    }

    // MARK: newTerminalBelow (app.js newSessionBelow + insertIntoColumn)

    func testNewTerminalBelowEmptyLayoutIsNewTerminal() throws {
        var l = Layout()
        try l.newTerminalBelow("s1")
        expectLayout(l, "s1^*")
    }

    func testNewTerminalBelowLonePaneBecomesStackOfTwoEqualPanes() throws {
        var l = try LayoutSpec.build("a*|b")
        try l.newTerminalBelow("x")
        expectLayout(l, "a,x^*|b^")
        expectSizes(l, 0, [1, 1])
    }

    func testNewTerminalBelowDirectlyBelowFocusedMidStackAverageWeight() throws {
        var l = try LayoutSpec.build("a:1,b:2^*,c:3|d")
        try l.newTerminalBelow("x")
        expectLayout(l, "a,b,x^*,c|d^")
        expectSizes(l, 0, [1, 2, 2, 3]) // (1+2+3)/3
    }

    func testNewTerminalBelowAtBottomOfStack() throws {
        var l = try LayoutSpec.build("a,b:0.5^*")
        try l.newTerminalBelow("x")
        expectLayout(l, "a,b,x^*")
        expectSizes(l, 0, [1, 0.5, 0.75])
    }

    func testNewTerminalBelowFullColumnStaysFull() throws {
        var l = try LayoutSpec.build("!a*")
        try l.newTerminalBelow("x")
        expectLayout(l, "!a,x^*")
    }

    func testNewTerminalBelowRejectsBadIds() throws {
        var l = try LayoutSpec.build("a*")
        XCTAssertThrowsError(try l.newTerminalBelow("a")) { XCTAssertEqual($0 as? LayoutError, .duplicateId) }
        XCTAssertThrowsError(try l.newTerminalBelow("files-z")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        expectLayout(l, "a^*")
    }

    // MARK: remove (app.js removeTile → removeSessionFromLayout)

    func testRemoveFocusedMidStackFocusGoesDown() throws {
        var l = try LayoutSpec.build("a,b^*,c|d")
        XCTAssertTrue(l.remove("b"))
        expectLayout(l, "a,c^*|d^")
    }

    func testRemoveFocusedAtBottomOfStackFocusGoesUp() throws {
        var l = try LayoutSpec.build("a,b,c^*|d")
        XCTAssertTrue(l.remove("c"))
        expectLayout(l, "a,b^*|d^")
    }

    func testRemoveFocusedAloneRightNeighboursActivePane() throws {
        var l = try LayoutSpec.build("x|a*|b,c^|d")
        XCTAssertTrue(l.remove("a"))
        expectLayout(l, "x^|b,c^*|d^")
    }

    func testRemoveFocusedAloneInLastColumnLeftNeighboursActivePane() throws {
        var l = try LayoutSpec.build("x|b,c^|a*")
        XCTAssertTrue(l.remove("a"))
        expectLayout(l, "x^|b,c^*")
    }

    func testRemoveOnlyPaneEmptiesLayout() throws {
        var l = try LayoutSpec.build("a*")
        XCTAssertTrue(l.remove("a"))
        expectLayout(l, "")
        XCTAssertTrue(l.isEmpty)
        XCTAssertNil(l.focused)
    }

    func testRemoveUnfocusedPaneLeavesFocusAloneColumnRepicksActive() throws {
        // Active was c (index 1): the pane now at index 1 (d) becomes active.
        var l = try LayoutSpec.build("a*|b,c^,d")
        XCTAssertTrue(l.remove("c"))
        expectLayout(l, "a^*|b,d^")
        // Active at the bottom: the new last becomes active.
        var m = try LayoutSpec.build("a*|b,c,d^")
        XCTAssertTrue(m.remove("d"))
        expectLayout(m, "a^*|b,c^")
        // Not the active one: active stays.
        var k = try LayoutSpec.build("a*|b^,c")
        XCTAssertTrue(k.remove("c"))
        expectLayout(k, "a^*|b^")
    }

    func testRemoveUnfocusedLoneColumnDisappears() throws {
        var l = try LayoutSpec.build("a|b|c*")
        XCTAssertTrue(l.remove("b"))
        expectLayout(l, "a^|c^*")
    }

    func testRemoveUnknownId() throws {
        var l = try LayoutSpec.build("a*")
        XCTAssertFalse(l.remove("nope"))
        expectLayout(l, "a^*")
    }

    func testRemoveWeightsOfSurvivorsKept() throws {
        var l = try LayoutSpec.build("a:1,b:2*,c:3")
        XCTAssertTrue(l.remove("b"))
        expectSizes(l, 0, [1, 3])
    }

    // MARK: toggleFull (app.js toggleFull)

    func testToggleFullLonePaneFlipsColumn() throws {
        var l = try LayoutSpec.build("a|b*|c")
        XCTAssertTrue(l.toggleFull())
        expectLayout(l, "a^|!b^*|c^")
        XCTAssertTrue(l.toggleFull())
        expectLayout(l, "a^|b^*|c^")
    }

    func testToggleFullStackedPaneSplitsOutRightAndGoesFull() throws {
        var l = try LayoutSpec.build("a,b^*,c|d")
        XCTAssertTrue(l.toggleFull())
        expectLayout(l, "a,c^|!b^*|d^")
        expectSizes(l, 1, [1])
        // Pressed again it is alone: it just leaves full (it does not rejoin).
        XCTAssertTrue(l.toggleFull())
        expectLayout(l, "a,c^|b^*|d^")
    }

    func testToggleFullStackedPaneOfFullColumnBothFull() throws {
        var l = try LayoutSpec.build("!a*,b")
        XCTAssertTrue(l.toggleFull())
        expectLayout(l, "!b^|!a^*")
    }

    func testToggleFullEmptyLayout() {
        var l = Layout()
        XCTAssertFalse(l.toggleFull())
    }

    // MARK: focus (app.js focusColumn / focusInColumn / setFocus)

    func testFocusLeftRightNeighbourColumnsRememberedActivePane() throws {
        var l = try LayoutSpec.build("a,b^|c*|d,e,f^")
        XCTAssertTrue(l.focus(.left))
        expectLayout(l, "a,b^*|c^|d,e,f^")
        XCTAssertTrue(l.focus(.right))
        XCTAssertTrue(l.focus(.right))
        expectLayout(l, "a,b^|c^|d,e,f^*")
    }

    func testFocusNothingPastEitherEnd() throws {
        var l = try LayoutSpec.build("a*|b")
        XCTAssertFalse(l.focus(.left))
        XCTAssertFalse(l.focus(.up))
        XCTAssertFalse(l.focus(.down))
        expectLayout(l, "a^*|b^")
        var one = try LayoutSpec.build("a*")
        for d in Direction.allCases { XCTAssertFalse(one.focus(d)) }
        var stack = try LayoutSpec.build("a,b*")
        XCTAssertFalse(stack.focus(.right))
        XCTAssertFalse(stack.focus(.down))
        XCTAssertFalse(stack.focus(.left))
    }

    func testFocusUpDownWithinStackAndColumnRemembers() throws {
        var l = try LayoutSpec.build("a*,b,c|d")
        XCTAssertTrue(l.focus(.down))
        XCTAssertTrue(l.focus(.down))
        expectLayout(l, "a,b,c^*|d^")
        XCTAssertFalse(l.focus(.down))
        XCTAssertTrue(l.focus(.up))
        expectLayout(l, "a,b^*,c|d^")
        XCTAssertTrue(l.focus(.right))
        expectLayout(l, "a,b^,c|d^*")
        XCTAssertTrue(l.focus(.left)) // back to b, not a
        expectLayout(l, "a,b^*,c|d^")
    }

    func testFocusEmptyLayout() {
        var l = Layout()
        for d in Direction.allCases { XCTAssertFalse(l.focus(d)) }
    }

    func testFocusRightFromDanglingFocusPicksColumnZero() throws {
        var l = try LayoutSpec.build("a|b")
        l.focused = nil
        XCTAssertFalse(l.focus(.left))
        XCTAssertTrue(l.focus(.right))
        expectLayout(l, "a^*|b^")
    }

    func testSetFocusClickFocusesAndActivatesReportsChange() throws {
        var l = try LayoutSpec.build("a*|b^,c")
        XCTAssertTrue(l.setFocus("c"))
        expectLayout(l, "a^|b,c^*")
        XCTAssertFalse(l.setFocus("c"))
        XCTAssertFalse(l.setFocus("nope"))
        // Focused but not its column's active (a restored layout can do that).
        l.columns[1].active = "b"
        XCTAssertTrue(l.setFocus("c"))
        expectLayout(l, "a^|b,c^*")
    }

    // MARK: moveColumn (app.js moveColumn)

    func testMoveColumnSwapsWithNeighbourStackAndFullFlagTravel() throws {
        var l = try LayoutSpec.build("a|!b*,c|d")
        XCTAssertTrue(l.moveColumn(.right))
        expectLayout(l, "a^|d^|!b^*,c")
        XCTAssertFalse(l.moveColumn(.right))
        XCTAssertTrue(l.moveColumn(.left))
        XCTAssertTrue(l.moveColumn(.left))
        expectLayout(l, "!b^*,c|a^|d^")
        XCTAssertFalse(l.moveColumn(.left))
    }

    func testMoveColumnSingleColumnEmptyLayout() throws {
        var l = try LayoutSpec.build("a*,b")
        XCTAssertFalse(l.moveColumn(.left))
        XCTAssertFalse(l.moveColumn(.right))
        var e = Layout()
        XCTAssertFalse(e.moveColumn(.right))
    }

    // MARK: movePane (app.js movePane)

    func testMovePaneSwapsWithStackNeighbourWeightsTravel() throws {
        var l = try LayoutSpec.build("a:1,b:2^*,c:3")
        XCTAssertTrue(l.movePane(.down))
        expectLayout(l, "a,c,b^*")
        expectSizes(l, 0, [1, 3, 2])
        XCTAssertFalse(l.movePane(.down))
        XCTAssertTrue(l.movePane(.up))
        XCTAssertTrue(l.movePane(.up))
        expectLayout(l, "b^*,a,c")
        expectSizes(l, 0, [2, 1, 3])
        XCTAssertFalse(l.movePane(.up))
    }

    func testMovePaneSinglePaneActiveMemoryUnaffected() throws {
        var l = try LayoutSpec.build("a*|b")
        XCTAssertFalse(l.movePane(.up))
        XCTAssertFalse(l.movePane(.down))
        var m = try LayoutSpec.build("a^,b*|c")
        // Focused b is not active (restored layout); moving keeps active = a.
        XCTAssertTrue(m.movePane(.up))
        expectLayout(m, "b*,a^|c^")
    }

    // MARK: consumeOrExpel (app.js consumeOrExpel / expel)

    func testConsumeOrExpelStackedPaneExpelledRightIntoOwnColumn() throws {
        var l = try LayoutSpec.build("x|a:1,b:2^*,c:3|y")
        XCTAssertTrue(l.consumeOrExpel(.right))
        expectLayout(l, "x^|a,c^|b^*|y^")
        expectSizes(l, 1, [1, 3])
        expectSizes(l, 2, [1])
    }

    func testConsumeOrExpelExpelledLeftGoesBeforeOldColumn() throws {
        var l = try LayoutSpec.build("x|a,b^*,c|y")
        XCTAssertTrue(l.consumeOrExpel(.left))
        expectLayout(l, "x^|b^*|a,c^|y^")
    }

    func testConsumeOrExpelExpelFromFirstAndLastColumns() throws {
        var l = try LayoutSpec.build("a*,b")
        XCTAssertTrue(l.consumeOrExpel(.left))
        expectLayout(l, "a^*|b^")
        var m = try LayoutSpec.build("a,b*")
        XCTAssertTrue(m.consumeOrExpel(.right))
        expectLayout(m, "a^|b^*")
    }

    func testConsumeOrExpelLonePaneMergesAtBottomOfNeighbourAverageWeight() throws {
        var l = try LayoutSpec.build("a:1,b:3^|c*|d")
        XCTAssertTrue(l.consumeOrExpel(.left))
        expectLayout(l, "a,b,c^*|d^")
        expectSizes(l, 0, [1, 3, 2])
        var m = try LayoutSpec.build("a|c*|d,e^")
        XCTAssertTrue(m.consumeOrExpel(.right))
        expectLayout(m, "a^|d,e,c^*")
    }

    func testConsumeOrExpelLonePaneWithNoColumnOnThatSideStaysPut() throws {
        var l = try LayoutSpec.build("a*|b")
        XCTAssertFalse(l.consumeOrExpel(.left))
        expectLayout(l, "a^*|b^")
        var one = try LayoutSpec.build("a*")
        XCTAssertFalse(one.consumeOrExpel(.left))
        XCTAssertFalse(one.consumeOrExpel(.right))
        expectLayout(one, "a^*")
    }

    func testConsumeOrExpelTwoTapsCarryStackedPaneIntoNextColumn() throws {
        var l = try LayoutSpec.build("a,b^*|c")
        XCTAssertTrue(l.consumeOrExpel(.right))
        expectLayout(l, "a^|b^*|c^")
        XCTAssertTrue(l.consumeOrExpel(.right))
        expectLayout(l, "a^|c,b^*")
    }

    func testConsumeOrExpelFullFlagsMergedPanesColumnGoesTargetKeepsOwn() throws {
        var l = try LayoutSpec.build("!a*|!b")
        XCTAssertTrue(l.consumeOrExpel(.right))
        expectLayout(l, "!b,a^*")
        var m = try LayoutSpec.build("a*|!b")
        XCTAssertTrue(m.consumeOrExpel(.right))
        expectLayout(m, "!b,a^*")
    }

    func testConsumeOrExpelExpellingFromFullColumnOldStaysFullNewIsNot() throws {
        var l = try LayoutSpec.build("!a,b*")
        XCTAssertTrue(l.consumeOrExpel(.right))
        expectLayout(l, "!a^|b^*")
    }

    func testConsumeOrExpelEmptyLayout() {
        var l = Layout()
        XCTAssertFalse(l.consumeOrExpel(.right))
    }

    // MARK: dragDivider (app.js makeDivider)

    func testDividerRatioPointerShareOfSpanClamped() {
        // span 600: min = 110/600; pointer at 300 → 0.5.
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 300, spanPx: 600, minPx: 110), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 20, spanPx: 600, minPx: 110), 110.0 / 600.0, accuracy: 1e-12)
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 590, spanPx: 600, minPx: 110), 1 - 110.0 / 600.0, accuracy: 1e-12)
        XCTAssertEqual(Layout.dividerRatio(offsetPx: -50, spanPx: 600, minPx: 110), 110.0 / 600.0, accuracy: 1e-12)
        // span 200: 110/200 = 0.55 > 0.45 → clamped to 0.45…0.55.
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 0, spanPx: 200, minPx: 110), 0.45, accuracy: 1e-12)
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 200, spanPx: 200, minPx: 110), 0.55, accuracy: 1e-12)
        XCTAssertEqual(Layout.dividerRatio(offsetPx: 100, spanPx: 200, minPx: 110), 0.5, accuracy: 1e-12)
    }

    func testDragDividerReassignsPairsCombinedWeightOthersUntouched() throws {
        var l = try LayoutSpec.build("x|a:1,b:3,c:2*")
        // Divider 0 of column 1: pair weight 4, pointer at 1/4 of a 800 px span.
        XCTAssertTrue(l.dragDivider(column: 1, divider: 0, offsetPx: 200, spanPx: 800))
        expectSizes(l, 1, [1, 3, 2])
        XCTAssertTrue(l.dragDivider(column: 1, divider: 0, offsetPx: 400, spanPx: 800))
        expectSizes(l, 1, [2, 2, 2])
        // Divider 1, dragged far down: clamped at 1 - 110/600.
        XCTAssertTrue(l.dragDivider(column: 1, divider: 1, offsetPx: 10000, spanPx: 600))
        expectSizes(l, 1, [2, 4 * (1 - 110.0 / 600.0), 4 * (110.0 / 600.0)])
        expectLayout(l, "x^|a,b,c^*")
    }

    func testDragDividerOutOfRangeAndDegenerateSpansChangeNothing() throws {
        var l = try LayoutSpec.build("a*|b,c")
        XCTAssertFalse(l.dragDivider(column: 0, divider: 0, offsetPx: 10, spanPx: 100)) // single pane: no divider
        XCTAssertFalse(l.dragDivider(column: 1, divider: 1, offsetPx: 10, spanPx: 100)) // only divider 0
        XCTAssertFalse(l.dragDivider(column: 2, divider: 0, offsetPx: 10, spanPx: 100)) // no column 2
        XCTAssertFalse(l.dragDivider(column: -1, divider: 0, offsetPx: 10, spanPx: 100))
        XCTAssertFalse(l.dragDivider(column: 1, divider: -1, offsetPx: 10, spanPx: 100))
        XCTAssertFalse(l.dragDivider(column: 1, divider: 0, offsetPx: 10, spanPx: 0))
        XCTAssertFalse(l.dragDivider(column: 1, divider: 0, offsetPx: 10, spanPx: -5))
        XCTAssertFalse(l.dragDivider(column: 1, divider: 0, offsetPx: .nan, spanPx: 100))
        XCTAssertFalse(l.dragDivider(column: 1, divider: 0, offsetPx: 10, spanPx: .infinity))
        expectSizes(l, 1, [1, 1])
    }

    // MARK: Commands by name

    func testCommandNamesRoundTrip() {
        let names = [
            "new-terminal", "new-files", "new-terminal-below", "close-pane",
            "toggle-full", "focus-left", "focus-right", "focus-up",
            "focus-down", "move-column-left", "move-column-right", "move-pane-up",
            "move-pane-down", "consume-expel-left", "consume-expel-right",
        ]
        XCTAssertEqual(names.count, LayoutCommand.allCases.count)
        for n in names {
            guard let c = LayoutCommand(name: n) else { return XCTFail("no command \(n)") }
            XCTAssertEqual(c.name, n)
        }
        XCTAssertNil(LayoutCommand(name: "focus_left"))
        XCTAssertTrue(LayoutCommand.closePane.needsShell)
        XCTAssertFalse(LayoutCommand.toggleFull.needsShell)
    }

    func testRunDispatchesPureCommandsRefusesShellOnes() throws {
        var l = try LayoutSpec.build("a,b*|c")
        XCTAssertFalse(l.run(.newTerminal))
        XCTAssertFalse(l.run(.closePane))
        expectLayout(l, "a,b^*|c^")
        XCTAssertTrue(l.run(.focusUp))
        XCTAssertTrue(l.run(.movePaneDown))
        expectLayout(l, "b,a^*|c^")
        XCTAssertTrue(l.run(.consumeExpelRight))
        expectLayout(l, "b^|a^*|c^")
        XCTAssertTrue(l.run(.moveColumnRight))
        expectLayout(l, "b^|c^|a^*")
        XCTAssertTrue(l.run(.focusLeft))
        XCTAssertTrue(l.run(.toggleFull))
        expectLayout(l, "b^|!c^*|a^")
        XCTAssertTrue(l.run(.consumeExpelLeft))
        expectLayout(l, "b,c^*|a^")
        XCTAssertTrue(l.run(.focusRight))
        XCTAssertTrue(l.run(.moveColumnLeft))
        XCTAssertFalse(l.run(.focusDown))
        expectLayout(l, "a^*|b,c^")
    }

    // MARK: Queries

    func testQueries() throws {
        let l = try LayoutSpec.build("a,b^*|c")
        XCTAssertEqual(l.paneCount, 3)
        XCTAssertEqual(l.allIds, ["a", "b", "c"])
        XCTAssertEqual(l.position(of: "b"), Position(col: 0, row: 1))
        XCTAssertNil(l.position(of: "zz"))
        XCTAssertEqual(l.pane(at: Position(col: 1, row: 0))?.id, "c")
        XCTAssertNil(l.pane(at: Position(col: 1, row: 1)))
        XCTAssertNil(l.pane(at: Position(col: 5, row: 0)))
        XCTAssertEqual(l.focusedPane?.id, "b")
        XCTAssertEqual(l.focusedPosition, Position(col: 0, row: 1))
        XCTAssertEqual(l.focusedColumn, 0)
        XCTAssertEqual(l.columnIndex(of: "c"), 1)
        XCTAssertEqual(l.columns[0].activePane?.id, "b")
        XCTAssertEqual(l.columns[0].activeIndex, 1)
        XCTAssertEqual(l.fullFlags, [false, false])
    }

    func testAppendColumnRejectsInconsistentArguments() throws {
        var l = try LayoutSpec.build("a*")
        XCTAssertThrowsError(try l.appendColumn(ids: [], sizes: [], active: 0, full: false))
        XCTAssertThrowsError(try l.appendColumn(ids: ["b"], sizes: [1, 2], active: 0, full: false))
        XCTAssertThrowsError(try l.appendColumn(ids: ["b"], sizes: [1], active: 1, full: false))
        XCTAssertThrowsError(try l.appendColumn(ids: ["b", "b"], sizes: [1, 1], active: 0, full: false)) {
            XCTAssertEqual($0 as? LayoutError, .duplicateId)
        }
        XCTAssertThrowsError(try l.appendColumn(ids: ["a"], sizes: [1], active: 0, full: false)) {
            XCTAssertEqual($0 as? LayoutError, .duplicateId)
        }
        XCTAssertThrowsError(try l.appendColumn(ids: [""], sizes: [1], active: 0, full: false)) {
            XCTAssertEqual($0 as? LayoutError, .invalidId)
        }
        expectLayout(l, "a^*")
        XCTAssertThrowsError(try l.appendNewColumn("")) { XCTAssertEqual($0 as? LayoutError, .invalidId) }
        XCTAssertThrowsError(try l.appendNewColumn("a")) { XCTAssertEqual($0 as? LayoutError, .duplicateId) }
        try l.appendNewColumn("b")
        expectLayout(l, "a^*|b^")
        l.drop("zz")
        l.drop("a")
        XCTAssertNil(l.focused)
        l.normalizeFocus()
        expectLayout(l, "b^*")
    }

    func testCheckFindsBrokenInvariants() throws {
        var l = try LayoutSpec.build("a,b*|c")
        l.columns[0].active = "zz"
        XCTAssertThrowsError(try l.check()) { XCTAssertEqual($0 as? LayoutInvariantError, .activeNotInColumn) }
        l = try LayoutSpec.build("a,b*|c")
        l.columns[0].sizes[0] = .nan
        XCTAssertThrowsError(try l.check()) { XCTAssertEqual($0 as? LayoutInvariantError, .badWeight) }
        l = try LayoutSpec.build("a,b*|c")
        l.focused = "zz"
        XCTAssertThrowsError(try l.check()) { XCTAssertEqual($0 as? LayoutInvariantError, .focusDangling) }
        l.focused = nil
        XCTAssertThrowsError(try l.check()) { XCTAssertEqual($0 as? LayoutInvariantError, .noFocus) }
    }

    // MARK: A long random walk: invariants hold after every command.

    func testRandomCommandSequencesKeepInvariants() throws {
        var rng = SplitMix64(seed: 0x5eed)
        var l = Layout()
        var next = 0
        let cmds: [LayoutCommand] = [
            .toggleFull, .focusLeft, .focusRight, .focusUp, .focusDown, .moveColumnLeft, .moveColumnRight,
            .movePaneUp, .movePaneDown, .consumeExpelLeft, .consumeExpelRight,
        ]
        for _ in 0..<5000 {
            switch Int.random(in: 0..<20, using: &rng) {
            case 0, 1:
                try l.newTerminal("s\(next)")
                next += 1
            case 2, 3:
                try l.newTerminalBelow("s\(next)")
                next += 1
            case 4:
                try l.newFiles("files-\(next)", state: "{}")
                next += 1
            case 5, 6:
                if let f = l.focused { XCTAssertTrue(l.remove(f)) }
            case 7:
                if l.paneCount > 0 {
                    let ci = Int.random(in: 0..<l.columns.count, using: &rng)
                    let col = l.columns[ci]
                    let p = col.panes[Int.random(in: 0..<col.count, using: &rng)]
                    XCTAssertTrue(l.remove(p.id))
                }
            case 8:
                if !l.columns.isEmpty {
                    let ci = Int.random(in: 0..<l.columns.count, using: &rng)
                    let col = l.columns[ci]
                    _ = l.dragDivider(
                        column: ci, divider: Int.random(in: 0..<col.count, using: &rng),
                        offsetPx: Double.random(in: 0..<1, using: &rng) * 900 - 100,
                        spanPx: Double.random(in: 0..<1, using: &rng) * 800
                    )
                }
            default:
                _ = l.run(cmds[Int.random(in: 0..<cmds.count, using: &rng)])
            }
            try l.check()
        }
    }
}
