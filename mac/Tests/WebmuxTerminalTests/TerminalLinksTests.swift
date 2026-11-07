import XCTest
@testable import WebmuxTerminal

/// Link classification and detection (PARITY T-24, T-25, C-11).
final class TerminalLinksTests: XCTestCase {
    func testKindClassification() {
        XCTAssertEqual(LinkKind(url: "https://example.com/a"), .http)
        XCTAssertEqual(LinkKind(url: "HTTP://x"), .http)
        XCTAssertEqual(LinkKind(url: "mailto:a@b.c"), .mailto)
        XCTAssertEqual(LinkKind(url: "file:///etc/hosts"), .other)
        XCTAssertEqual(LinkKind(url: "ssh://host"), .other)
        XCTAssertTrue(LinkKind.http.isClickable)
        XCTAssertFalse(LinkKind.mailto.isClickable)
        XCTAssertFalse(LinkKind.relay.isClickable)
    }

    func testURLsInARow() {
        let row = "see https://ex.invalid/a?b=c, then http://x.y/z. done"
        let urls = TerminalLinks.urls(in: row).map(\.url)
        XCTAssertEqual(urls, ["https://ex.invalid/a?b=c", "http://x.y/z"])
    }

    func testURLStopsAtEmptyCellsAndPunctuation() {
        // A URL that ends its row, as the text dump may render it (NUL or spaces).
        XCTAssertEqual(TerminalLinks.urls(in: "https://ex.invalid/m\u{0}\u{0}\u{0}").map(\.url), ["https://ex.invalid/m"])
        XCTAssertEqual(TerminalLinks.urls(in: "https://ex.invalid/m.   ").map(\.url), ["https://ex.invalid/m"])
        XCTAssertEqual(TerminalLinks.urls(in: "(https://ex.invalid/p)").map(\.url), ["https://ex.invalid/p"])
        XCTAssertEqual(TerminalLinks.urls(in: "mailto:a@b.c ftp://x").count, 0, "http(s) only")
    }

    func testURLAtColumn() {
        let row = "x https://ex.invalid/abc y"
        XCTAssertEqual(TerminalLinks.url(in: row, atColumn: 2)?.url, "https://ex.invalid/abc")
        XCTAssertEqual(TerminalLinks.url(in: row, atColumn: 23)?.url, "https://ex.invalid/abc")
        XCTAssertNil(TerminalLinks.url(in: row, atColumn: 0))
        XCTAssertNil(TerminalLinks.url(in: row, atColumn: 24), "the space after the URL")
        XCTAssertEqual(TerminalLinks.url(in: row, atColumn: 2)?.range, 2..<24)
    }

    func testCellFromPoint() {
        let cell = CGSize(width: 8, height: 17)
        // Padding is 4 pt; the first cell starts there.
        XCTAssertEqual(TerminalLinks.cell(x: 4, topY: 4, cellSize: cell, columns: 80, rows: 24).map { [$0.col, $0.row] }, [0, 0])
        XCTAssertEqual(TerminalLinks.cell(x: 4 + 8 * 10 + 3, topY: 4 + 17 * 5 + 16, cellSize: cell, columns: 80, rows: 24).map { [$0.col, $0.row] }, [10, 5])
        XCTAssertNil(TerminalLinks.cell(x: 1, topY: 10, cellSize: cell, columns: 80, rows: 24), "in the padding")
        XCTAssertNil(TerminalLinks.cell(x: 4 + 8 * 80, topY: 10, cellSize: cell, columns: 80, rows: 24), "past the grid")
        XCTAssertNil(TerminalLinks.cell(x: 10, topY: 10, cellSize: .zero, columns: 80, rows: 24))
    }

    @MainActor
    func testOpenURLDedupePerHost() {
        let d = OpenURLDedupe(limit: 3)
        XCTAssertTrue(d.shouldShow(id: "u1", host: "/a.sock"))
        XCTAssertFalse(d.shouldShow(id: "u1", host: "/a.sock"), "broadcast on every socket of the host: once")
        XCTAssertTrue(d.shouldShow(id: "u1", host: "/b.sock"), "another host")
        XCTAssertTrue(d.shouldShow(id: "u2", host: "/a.sock"))
        XCTAssertTrue(d.shouldShow(id: "u3", host: "/a.sock"))
        XCTAssertTrue(d.shouldShow(id: "u4", host: "/a.sock"))
        XCTAssertTrue(d.shouldShow(id: "u1", host: "/a.sock"), "evicted after the limit")
        d.reset(host: "/a.sock")
        XCTAssertTrue(d.shouldShow(id: "u4", host: "/a.sock"))
    }
}
