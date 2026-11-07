import XCTest
import GhosttyKit
@testable import WebmuxTerminal

/// `WebmuxEvent(c:)` copies the C event (strings are borrowed and only valid
/// during the callback).
final class WebmuxEventTests: XCTestCase {
    private func withEvent<T>(
        tag: ghostty_webmux_event_tag_e,
        text: String? = nil,
        aux: String? = nil,
        _ configure: (inout ghostty_webmux_event_s) -> Void = { _ in },
        _ body: (ghostty_webmux_event_s) -> T
    ) -> T {
        var e = ghostty_webmux_event_s()
        e.tag = tag
        e.pid = -1
        configure(&e)
        return (text ?? "").withCString { t in
            (aux ?? "").withCString { a in
                if let text { e.text = t; e.text_len = text.utf8.count }
                if let aux { e.aux = a; e.aux_len = aux.utf8.count }
                return body(e)
            }
        }
    }

    func testLinkEvents() {
        XCTAssertEqual(withEvent(tag: GHOSTTY_WEBMUX_EVENT_LINK_UP) { WebmuxEvent(c: $0) }, .linkUp)
        XCTAssertEqual(withEvent(tag: GHOSTTY_WEBMUX_EVENT_LINK_DOWN) { WebmuxEvent(c: $0) }, .linkDown)
    }

    func testSnapshot() {
        let ev = withEvent(tag: GHOSTTY_WEBMUX_EVENT_SNAPSHOT, { e in
            e.cols = 120; e.rows = 40; e.remote_cols = 80; e.remote_rows = 24; e.bytes = 4096; e.pid = 1234
        }) { WebmuxEvent(c: $0) }
        XCTAssertEqual(ev, .snapshot(cols: 120, rows: 40, remoteCols: 80, remoteRows: 24, bytes: 4096, pid: 1234))
    }

    func testTitleCopiesTheString() {
        // The text is only valid inside the closure; the event must own a copy.
        let ev: WebmuxEvent? = withEvent(tag: GHOSTTY_WEBMUX_EVENT_TITLE, text: "héllo — ✓") { WebmuxEvent(c: $0) }
        XCTAssertEqual(ev, .title("héllo — ✓"))
        XCTAssertEqual(withEvent(tag: GHOSTTY_WEBMUX_EVENT_TITLE) { WebmuxEvent(c: $0) }, .title(""))
    }

    func testSessionTitleAndErrors() {
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_SESSION_TITLE, text: "vim", aux: "s-1") { WebmuxEvent(c: $0) },
            .sessionTitle(session: "s-1", title: "vim"))
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_EXIT, { $0.code = 130 }) { WebmuxEvent(c: $0) },
            .exit(code: 130))
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_SESSION_ERROR, text: "no such session") { WebmuxEvent(c: $0) },
            .sessionError(message: "no such session"))
    }

    func testPasteResultAndOpenURL() {
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_PASTE_RESULT, text: "path", aux: "/tmp/x.png") { WebmuxEvent(c: $0) },
            .pasteResult(mode: "path", path: "/tmp/x.png"))
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_PASTE_RESULT, text: "claude") { WebmuxEvent(c: $0) },
            .pasteResult(mode: "claude", path: nil))
        XCTAssertEqual(
            withEvent(tag: GHOSTTY_WEBMUX_EVENT_OPEN_URL, text: "https://ex.invalid/a", aux: "u7") { WebmuxEvent(c: $0) },
            .openURL(url: "https://ex.invalid/a", id: "u7"))
    }

    func testSocketEvent() {
        let ev = withEvent(tag: GHOSTTY_WEBMUX_EVENT_SOCKET, text: "going away", { e in
            e.socket_kind = GHOSTTY_WEBMUX_SOCKET_DROPPED
            e.attempt = 3; e.ms = 1500; e.code = 1001; e.clean = false; e.retry_in_ms = 2000; e.bytes = 77
        }) { WebmuxEvent(c: $0) }
        XCTAssertEqual(ev, .socket(.init(
            kind: .dropped, attempt: 3, ms: 1500, code: 1001, reason: "going away",
            clean: false, retryInMs: 2000, bytes: 77)))
    }

    func testUnknownTagIsDropped() {
        let ev = withEvent(tag: ghostty_webmux_event_tag_e(rawValue: 999)) { WebmuxEvent(c: $0) }
        XCTAssertNil(ev)
    }
}
