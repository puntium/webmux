// The module's own JSON parser and writer (no Zig counterpart: the Zig uses
// std.json). Strictness and the ordering/duplicate rules the layout file
// relies on.

import XCTest
@testable import WebmuxLayout

final class JSONTests: XCTestCase {
    func testScalarsAndContainers() {
        XCTAssertEqual(JSONParser.parse("null"), .null)
        XCTAssertEqual(JSONParser.parse(" true "), .bool(true))
        XCTAssertEqual(JSONParser.parse("false"), .bool(false))
        XCTAssertEqual(JSONParser.parse("1"), .number(1, isInteger: true))
        XCTAssertEqual(JSONParser.parse("-0.5e1"), .number(-5, isInteger: false))
        XCTAssertEqual(JSONParser.parse("1E2"), .number(100, isInteger: false))
        XCTAssertEqual(JSONParser.parse("\"a\\n\\u00e9\\ud83d\\ude00\\/\""), .string("a\n\u{e9}\u{1F600}/"))
        XCTAssertEqual(JSONParser.parse("[]"), .array([]))
        XCTAssertEqual(JSONParser.parse("{}"), .object([]))
        XCTAssertEqual(
            JSONParser.parse("{\"a\":[1,{\"b\":null}],\"c\":\"d\"}"),
            .object([
                JSONMember(key: "a", value: .array([.number(1, isInteger: true), .object([JSONMember(key: "b", value: .null)])])),
                JSONMember(key: "c", value: .string("d")),
            ])
        )
    }

    func testRejectsWhatJSONParseRejects() {
        for bad in [
            "", " ", "{", "}", "[1,]", "{\"a\":1,}", "{a:1}", "{\"a\" 1}", "[1 2]", "01", "1.", ".5", "+1", "1e",
            "tru", "nul", "\"abc", "\"a\u{01}b\"", "\"\\x\"", "\"\\u12\"", "\"\\u12g4\"", "[1] 2", "NaN", "Infinity",
            "'a'", "[", "]", "{\"a\":}", "{\"a\"}", "\u{FEFF}{}",
        ] {
            XCTAssertNil(JSONParser.parse(bad), bad)
        }
    }

    func testDuplicateKeysKeepLastValueAtFirstPosition() {
        let v = JSONParser.parse("{\"a\":1,\"b\":2,\"a\":3}")
        XCTAssertEqual(v, .object([JSONMember(key: "a", value: .number(3, isInteger: true)), JSONMember(key: "b", value: .number(2, isInteger: true))]))
        XCTAssertEqual(v?.member("a"), .number(3, isInteger: true))
        XCTAssertNil(v?.member("zz"))
    }

    func testLoneSurrogatesBecomeTheReplacementCharacter() {
        XCTAssertEqual(JSONParser.parse("\"\\ud800x\""), .string("\u{FFFD}x"))
        XCTAssertEqual(JSONParser.parse("\"\\udc00\""), .string("\u{FFFD}"))
        XCTAssertEqual(JSONParser.parse("\"\\ud800\\u0041\""), .string("\u{FFFD}A"))
    }

    func testDepthAndTooDeep() {
        XCTAssertEqual(JSONParser.parse("1")?.depth(from: 0), 0)
        XCTAssertEqual(JSONParser.parse("{}")?.depth(from: 0), 1)
        XCTAssertEqual(JSONParser.parse("{\"a\":[[]]}")?.depth(from: 0), 3)
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let v = JSONParser.parse(deep)
        XCTAssertNotNil(v)
        XCTAssertGreaterThan(v?.depth(from: 0) ?? 0, Layout.maxStateDepth)
        // Content past the build depth is still syntax-checked.
        XCTAssertNil(JSONParser.parse(String(repeating: "[", count: 200) + "x" + String(repeating: "]", count: 200)))
        XCTAssertNil(JSONParser.parse(String(repeating: "{\"k\":", count: 200) + "1" + String(repeating: "}", count: 199)))
        // Up to the build depth everything is kept.
        let kept = String(repeating: "[", count: JSONParser.buildDepth) + String(repeating: "]", count: JSONParser.buildDepth)
        var v2 = JSONParser.parse(kept)
        for _ in 0..<JSONParser.buildDepth {
            guard case .array(let items)? = v2 else { return XCTFail("built container expected") }
            v2 = items.first
        }
        XCTAssertNil(v2)
    }

    func testWriterIsCompactOrderedAndEscapes() {
        let text = "{\"b\":[1,2.5,-3,true,null,\"q\\\"\\\\\\n\\t\\u0001\u{e9}\"],\"a\":{}}"
        guard let v = JSONParser.parse(text) else { return XCTFail("parse") }
        XCTAssertEqual(JSONWriter.write(v), text)
        XCTAssertEqual(JSONWriter.number(1), "1")
        XCTAssertEqual(JSONWriter.number(-2), "-2")
        XCTAssertEqual(JSONWriter.number(0.1 + 0.2), "0.30000000000000004")
        XCTAssertEqual(JSONWriter.number(1e20), "1e+20")
        XCTAssertEqual(JSONWriter.number(.infinity), "null")
        XCTAssertEqual(JSONWriter.write(.tooDeep), "null")
        // Round trip through the writer is stable.
        XCTAssertEqual(JSONParser.parse(JSONWriter.write(v)), v)
    }
}
