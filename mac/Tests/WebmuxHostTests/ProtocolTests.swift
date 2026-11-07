import XCTest
@testable import WebmuxHost

final class ProtocolTests: XCTestCase {
    func testJSONStringLiteralEscapesAndInvalidUTF8() throws {
        let cases: [([UInt8], String)] = [
            (Array("abc".utf8), "\"abc\""),
            ([0x1b] + Array("[A\r".utf8), "\"\\u001b[A\\r\""),
            (Array("q\"\\".utf8), "\"q\\\"\\\\\""),
            (Array("é€😀".utf8), "\"é€😀\""),
            ([0x61, 0xff, 0x62], "\"a\u{FFFD}b\""),
            // Truncated 3-byte sequence then ASCII: one U+FFFD (maximal subpart).
            ([0xe2, 0x82, 0x78], "\"\u{FFFD}x\""),
            // Surrogate (ED A0 80): ED is a valid lead but A0 is out of its range.
            ([0xed, 0xa0, 0x80], "\"\u{FFFD}\u{FFFD}\u{FFFD}\""),
            ([0xc3], "\"\u{FFFD}\""),
            ([0x7f], "\"\u{7f}\""),
        ]
        for (input, expected) in cases {
            let got = jsonStringLiteral(Data(input))
            XCTAssertEqual(got, expected)
            // Always valid JSON that decodes to a string.
            let decoded = try JSONDecoder().decode(String.self, from: Data(got.utf8))
            XCTAssertEqual(decoded, String(expected.dropFirst().dropLast()).replacingOccurrences(of: "\\u001b", with: "\u{1b}")
                .replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\"))
        }
    }

    func testClientFramesEncodeAsTheHostExpects() {
        let cases: [(ClientFrame, String)] = [
            (.input("ls\r"), "{\"type\":\"input\",\"data\":\"ls\\r\"}"),
            (.resize(cols: 120, rows: 40), "{\"type\":\"resize\",\"cols\":120,\"rows\":40}"),
            (.pasteImage(mime: "image/png", data: "AAA="), "{\"type\":\"paste-image\",\"mime\":\"image/png\",\"data\":\"AAA=\"}"),
            (.clipboardSync(mime: "image/png", data: "AAA="), "{\"type\":\"clipboard-sync\",\"mime\":\"image/png\",\"data\":\"AAA=\"}"),
        ]
        for (frame, expected) in cases {
            XCTAssertEqual(frame.wire, expected)
            XCTAssertEqual(frame.wireData, Data(expected.utf8))
        }
    }

    func testClientFramesAreEncodableToo() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try enc.encode(ClientFrame.input(Data([0x61, 0xff]))), as: UTF8.self), "{\"data\":\"a\u{FFFD}\",\"type\":\"input\"}")
        XCTAssertEqual(String(decoding: try enc.encode(ClientFrame.resize(cols: 1, rows: 2)), as: UTF8.self), "{\"cols\":1,\"rows\":2,\"type\":\"resize\"}")
    }

    func testServerFramesParseByteExactHostOutput() throws {
        let snap = try ServerFrame(json: "{\"type\":\"snapshot\",\"data\":\"\\u001b[?25h$ \",\"cols\":100,\"rows\":30,\"title\":\"t\",\"pid\":4242}")
        XCTAssertEqual(snap, .snapshot(Snapshot(data: "\u{1b}[?25h$ ", cols: 100, rows: 30, title: "t", pid: 4242)))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"output\",\"data\":\"hi\\r\\n\"}"), .output("hi\r\n"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"title\",\"title\":\"vim\"}"), .title("vim"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"session-title\",\"session\":\"abc\",\"title\":\"x\"}"), .sessionTitle(session: "abc", title: "x"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"exit\",\"exitCode\":7}"), .exit(code: 7))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"error\",\"message\":\"no such session\"}"), .error(message: "no such session"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"error\",\"error\":\"e\",\"message\":\"m\"}"), .error(message: "e"))
        XCTAssertEqual(try ServerFrame(json: "{\"mode\":\"path\",\"path\":\"/tmp/p.png\",\"type\":\"paste-result\"}"), .pasteResult(mode: "path", path: "/tmp/p.png"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"paste-result\",\"mode\":\"claude\"}"), .pasteResult(mode: "claude", path: nil))
        XCTAssertEqual(try ServerFrame(json: "{\"id\":\"open-1-0\",\"type\":\"open-url\",\"url\":\"https://x.y/\"}"), .openURL(url: "https://x.y/", id: "open-1-0"))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"wat\"}"), .unknown(type: "wat"))
        // Lenient numbers: floats truncate, strings parse, out-of-range dims are 0.
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"snapshot\",\"cols\":80.9,\"rows\":70000,\"pid\":\"12\"}"),
                       .snapshot(Snapshot(data: "", cols: 80, rows: 0, title: "", pid: 12)))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"exit\"}"), .exit(code: 0))
        XCTAssertEqual(try ServerFrame(json: "{\"type\":\"snapshot\",\"pid\":null}"), .snapshot(Snapshot(data: "", cols: 0, rows: 0, title: "", pid: nil)))

        for bad in ["[1]", "{\"data\":1}", "{\"type\":1}", "nope", ""] {
            XCTAssertThrowsError(try ServerFrame(json: bad), bad) { e in
                XCTAssertEqual(e as? HostError, .protocolViolation(.invalidFrame))
            }
        }
    }

    func testServerFrameRoundTripsThroughCodable() throws {
        let frames: [ServerFrame] = [
            .snapshot(Snapshot(data: "x", cols: 1, rows: 2, title: "t", pid: 3)), .output("o"), .title("t"),
            .sessionTitle(session: "s", title: "t"), .exit(code: 1), .error(message: "m"),
            .pasteResult(mode: "path", path: "/p"), .openURL(url: "u", id: "i"), .unknown(type: "z"),
        ]
        for f in frames {
            let data = try JSONEncoder().encode(f)
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), f)
        }
    }
}
