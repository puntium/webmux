import XCTest
@testable import WebmuxTerminal

/// Pane-local lifecycle semantics (PARITY T-32, T-35, T-37, T-39, T-40, S-12), the
/// fade arithmetic (L-24) and the scrollbar geometry (T-10), all pure.
final class PaneSemanticsTests: XCTestCase {
    func testLinkUpDownAndDegraded() {
        var s = SessionLifecycle()
        XCTAssertFalse(s.isLinkUp)
        XCTAssertFalse(s.isDegraded, "not degraded before the first attach")
        s.apply(.linkUp)
        XCTAssertTrue(s.isLinkUp)
        XCTAssertFalse(s.isDegraded)
        s.apply(.linkDown)
        XCTAssertFalse(s.isLinkUp)
        XCTAssertTrue(s.isDegraded, "S-12: a dropped socket that is retrying")
        s.apply(.linkUp)
        XCTAssertFalse(s.isDegraded, "cleared when any socket opens again")
        s.apply(.snapshot(cols: 80, rows: 24, remoteCols: 80, remoteRows: 24, bytes: 1, pid: -1))
        XCTAssertEqual(s.snapshots, 1)
    }

    func testExitIsFinal() {
        var s = SessionLifecycle()
        s.apply(.linkUp)
        s.apply(.exit(code: 130))
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.exitCode, 130)
        XCTAssertFalse(s.isLinkUp)
        XCTAssertFalse(s.isDegraded, "an exited pane is not a degraded host")
        // T-37: do not reconnect; late link events change nothing.
        s.apply(.linkDown)
        XCTAssertFalse(s.isDegraded)
        s.apply(.linkUp)
        XCTAssertFalse(s.isLinkUp)
        XCTAssertTrue(WebmuxEvent.exit(code: 0).isFinal)
    }

    func testSessionErrorIsFinal() {
        var s = SessionLifecycle()
        s.apply(.linkUp)
        s.apply(.sessionError(message: "no such session"))
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.sessionError, "no such session")
        XCTAssertNil(s.exitCode)
        XCTAssertTrue(WebmuxEvent.sessionError(message: "x").isFinal)
        XCTAssertFalse(WebmuxEvent.linkDown.isFinal)
    }

    func testTitleIsIdempotent() {
        var s = SessionLifecycle()
        s.apply(.title("vim"))
        s.apply(.title("vim"))
        XCTAssertEqual(s.sessionTitle, "vim")
        s.apply(.title(""))
        XCTAssertEqual(s.sessionTitle, "", "empty: the label falls back to the session id (T-41)")
        s.apply(.sessionTitle(session: "other", title: "x"))
        XCTAssertEqual(s.sessionTitle, "", "another session's title is not ours")
    }

    func testFadeArithmetic() {
        typealias F = TerminalPaneView.UnfocusedFade
        XCTAssertEqual(F.opacity(0), 1)
        XCTAssertEqual(F.overlayAlpha(0), 0)
        XCTAssertEqual(F.opacity(0.4), 0.85, accuracy: 0.0001, "the default 40 gives 0.85")
        XCTAssertEqual(F.overlayAlpha(0.4), 0.28, accuracy: 0.0001, "and 0.28")
        XCTAssertEqual(F.opacity(1), 0.625, accuracy: 0.0001)
        XCTAssertEqual(F.overlayAlpha(1), 0.7, accuracy: 0.0001)
    }

    func testStickyBand() {
        XCTAssertEqual(TerminalPaneView.stickyBand(rows: 10), 3)
        XCTAssertEqual(TerminalPaneView.stickyBand(rows: 52), 8)
        XCTAssertEqual(TerminalPaneView.stickyBand(rows: 24), 4)
    }

    func testScrollbarGeometry() {
        typealias G = TerminalScrollbar.Geometry
        typealias S = TerminalScrollbar.State
        XCTAssertFalse(S(total: 24, offset: 0, len: 24).scrollable, "no scrollback: hidden")
        XCTAssertFalse(S(total: 0, offset: 0, len: 0).scrollable)
        let state = S(total: 240, offset: 216, len: 24)  // at the bottom
        let g = G(height: 406, state: state)
        XCTAssertEqual(g.trackTop, 3)
        XCTAssertEqual(g.trackHeight, 400)
        XCTAssertEqual(g.thumbHeight, 40, accuracy: 0.001, "len/total of the track")
        XCTAssertEqual(g.thumbTop + g.thumbHeight, 403, accuracy: 0.001, "bottom of the track")
        let top = G(height: 406, state: S(total: 240, offset: 0, len: 24))
        XCTAssertEqual(top.thumbTop, 3, accuracy: 0.001)
        // Dragging the thumb back to the top is row 0, to the bottom the last page.
        XCTAssertEqual(g.row(forThumbTop: 3, state: state), 0)
        XCTAssertEqual(g.row(forThumbTop: 363, state: state), 216)
        XCTAssertEqual(g.row(forThumbTop: 183, state: state), 108)
        // A tiny proportion still gives a grabbable thumb.
        let tiny = G(height: 100, state: S(total: 10_000, offset: 0, len: 24))
        XCTAssertEqual(tiny.thumbHeight, 20)
    }
}
