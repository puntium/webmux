// Persistence and reconciliation tests (port of test_persist.zig).
//
// The fork's `testdata/app_js_reconcile.jsonl` holds `[stored, live,
// expected]` triples: the stored document (malformed in many ways), the
// server's live session ids, and the layout app.js ends up with after
// `loadLayout` + `attachExisting`, computed by running those functions
// from app.js itself (`testdata/gen-reconcile.js`).

import XCTest
@testable import WebmuxLayout

final class PersistenceTests: XCTestCase {
    private typealias P = LayoutPersistence

    func testParseAndReconcileMatchAppJs() throws {
        let lines = try Testdata.lines("app_js_reconcile.jsonl")
        var n = 0
        for line in lines {
            n += 1
            guard let v = JSONParser.parse(line), case .array(let items) = v, items.count == 3,
                  case .string(let stored) = items[0], case .array(let liveValues) = items[1],
                  case .string(let expected) = items[2]
            else { return XCTFail("bad case \(n): \(line)") }
            let live: [String] = liveValues.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
            let l = P.load(stored, live: live)
            do {
                try expectSame(l, spec: expected)
            } catch {
                XCTFail("case \(n): \(line): \(error)")
            }
        }
        XCTAssertGreaterThanOrEqual(n, 20)
    }

    // MARK: Round trip

    func testSerializeParseRoundTripsEverything() throws {
        var l = try LayoutSpec.build("s1:0.3,files-a:1.7^|!s2*|s3,s4^,files-b")
        try l.setPaneState("files-a", "{\"type\":\"files\",\"dir\":\"~/src\",\"cursor\":\"a \\\"b\\\"\"}")
        try l.setPaneState("files-b", "{\"dir\":\"/\",\"nested\":{\"x\":[1,2.5,null,true]}}")
        let text = P.serialize(l)

        let back = P.parse(text)
        expectLayout(back, "s1,files-a^|!s2^*|s3,s4^,files-b")
        expectSizes(back, 0, [0.3, 1.7])
        XCTAssertEqual(back.find("files-a")?.state, l.find("files-a")?.state)
        XCTAssertEqual(back.find("files-b")?.state, l.find("files-b")?.state)
        XCTAssertEqual(P.serialize(back), text)
        XCTAssertEqual(back, l)

        // Data variants.
        XCTAssertEqual(P.encode(l), Data(text.utf8))
        XCTAssertEqual(P.parse(P.encode(l)), l)
        XCTAssertEqual(P.load(P.encode(l), live: ["s1", "s2", "s3", "s4"]), l)
    }

    func testSerializeTheDocumentedShape() throws {
        var l = try LayoutSpec.build("s1,files-a^*|!s2")
        try l.setPaneState("files-a", "{\"dir\":\"~\"}")
        XCTAssertEqual(
            P.serialize(l),
            "{\"version\":1,\"columns\":[" +
                "{\"panes\":[\"s1\",\"files-a\"],\"sizes\":[1,1],\"active\":\"files-a\",\"full\":false}," +
                "{\"panes\":[\"s2\"],\"sizes\":[1],\"active\":\"s2\",\"full\":true}]," +
                "\"focused\":\"files-a\",\"widgets\":{\"files-a\":{\"dir\":\"~\"}}}"
        )
    }

    func testSerializeEmptyLayoutAndIdsThatNeedEscaping() throws {
        XCTAssertEqual(P.serialize(Layout()), "{\"version\":1,\"columns\":[],\"focused\":null,\"widgets\":{}}")

        var l = Layout()
        let weird = "we\"ird\\id\n\u{e9}\u{1}/\u{1F600}"
        try l.newTerminal(weird)
        let t2 = P.serialize(l)
        XCTAssertTrue(t2.contains("\\u0001"))
        let back = P.parse(t2)
        XCTAssertNotNil(back.find(weird))
        XCTAssertEqual(back.focused, weird)
    }

    func testWeightsSurviveTheRoundTripBitForBit() throws {
        var l = try LayoutSpec.build("a,b,c,d,e*")
        let ws: [Double] = [0.1 + 0.2, 1.0 / 3.0, 123456.789e-3, 1e-7, 2.5e20]
        l.columns[0].sizes = ws
        let text = P.serialize(l)
        let back = P.parse(text)
        for (w, b) in zip(ws, back.columns[0].sizes) { XCTAssertEqual(w, b) }
        // Integral weights print as integers (the Electron client reads either).
        XCTAssertTrue(P.serialize(try LayoutSpec.build("a:2*")).contains("\"sizes\":[2]"))
    }

    // MARK: Rejection of malformed input

    private func expectParse(_ text: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        expectLayout(P.parse(text), expected, file: file, line: line)
    }

    func testParseUnusableDocumentsAreAnEmptyLayout() {
        expectParse("", "")
        expectParse("{", "")
        expectParse("null", "")
        expectParse("42", "")
        expectParse("[{\"panes\":[\"a\"]}]", "")
        expectParse("{}", "")
        expectParse("{\"columns\":{}}", "")
        expectParse("{\"columns\":[{\"panes\":[\"a\"]}]} trailing", "")
        expectLayout(P.parse(Data([0xff, 0xfe])), "")
        expectLayout(P.load(Data([0xff, 0xfe]), live: ["a"]), "a^*")
        expectLayout(P.load(nil, live: ["a"]), "a^*")
        // A split-tree document from before columns (app.js migrates these;
        // this client never wrote one).
        expectParse("{\"type\":\"pane\",\"session\":\"a\"}", "")
    }

    func testParseVersion() {
        expectParse("{\"version\":1,\"columns\":[{\"panes\":[\"a\"]}]}", "a^*")
        expectParse("{\"columns\":[{\"panes\":[\"a\"]}]}", "a^*")
        expectParse("{\"version\":2,\"columns\":[{\"panes\":[\"a\"]}]}", "")
        expectParse("{\"version\":\"1\",\"columns\":[{\"panes\":[\"a\"]}]}", "")
        expectParse("{\"version\":1.0,\"columns\":[{\"panes\":[\"a\"]}]}", "")
    }

    func testParseMalformedColumnsAndPanesDroppedOneByOne() {
        expectParse(
            """
            {"columns":[1,null,"x",[],{},{"panes":"a"},{"panes":[]},{"panes":[null,1,true,{},[],""]},
              {"panes":["a",7,"b","a"],"sizes":[2,9,3,9],"active":"b"},{"panes":["b","c"]}],
             "focused":"c"}
            """, "a,b^|c^*"
        )
        let l = P.parse("{\"columns\":[{\"panes\":[\"a\",7,\"b\",\"a\"],\"sizes\":[2,9,3,9],\"active\":\"b\"}]}")
        expectSizes(l, 0, [2, 3]) // weights follow their raw index
    }

    func testParseWeightsThatAreNotFinitePositiveNumbersBecomeOne() {
        let l = P.parse(
            """
            {"columns":[{"panes":["a","b","c","d","e","f","g","h"],
              "sizes":[-1,0,null,"2",true,1e400,0.25,[]]}]}
            """
        )
        expectSizes(l, 0, [1, 1, 1, 1, 1, 1, 0.25, 1])
        let m = P.parse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"sizes\":{\"0\":5}}]}")
        expectSizes(m, 0, [1, 1])
    }

    func testParseActiveAndFull() {
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"zz\"}]}", "a^*,b")
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":1}]}", "a^*,b")
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"}]}", "a,b^*")
        expectParse(
            "{\"columns\":[{\"panes\":[\"a\"],\"full\":true},{\"panes\":[\"b\"],\"full\":\"true\"},{\"panes\":[\"c\"],\"full\":1}]}",
            "!a^*|b^|c^"
        )
    }

    func testParseFocusFallsBackToFirstColumnsActivePane() {
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":\"nope\"}", "a,b^*|c^")
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":3}", "a,b^*|c^")
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"},{\"panes\":[\"c\"]}],\"focused\":\"c\"}", "a,b^|c^*")
        // Focused but not its column's active pane: kept as saved (app.js too).
        expectParse("{\"columns\":[{\"panes\":[\"a\",\"b\"],\"active\":\"b\"}],\"focused\":\"a\"}", "a*,b^")
    }

    func testParseDuplicateKeysKeepTheLast() {
        expectParse("{\"columns\":[{\"panes\":[\"a\"]}],\"columns\":[{\"panes\":[\"b\"]}]}", "b^*")
    }

    func testParseWidgetStatesKeptOnlyForFilesPanesOnlyObjectsBoundedDepth() {
        let deep = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        let l = P.parse(
            """
            {"columns":[{"panes":["s1","files-a","files-b","files-c","files-d"]}],
             "widgets":{"files-a":{"dir":"~"},"files-b":[1],"files-c":"x","s1":{"dir":"/"},
               "files-gone":{"dir":"/"},
               "files-d":{"a":\(deep)}}}
            """
        )
        XCTAssertEqual(l.find("files-a")?.state, "{\"dir\":\"~\"}")
        XCTAssertNil(l.find("files-b")?.state)
        XCTAssertNil(l.find("files-c")?.state)
        XCTAssertNil(l.find("files-d")?.state)
        XCTAssertNil(l.find("s1")?.state)
        XCTAssertFalse(P.serialize(l).contains("files-gone"))

        expectParse("{\"columns\":[{\"panes\":[\"files-a\"]}],\"widgets\":[1]}", "files-a^*")

        // A state is re-serialised canonically: order kept, last duplicate wins, whitespace dropped.
        let m = P.parse("{\"columns\":[{\"panes\":[\"files-a\"]}],\"widgets\":{\"files-a\":{ \"b\" : 1 , \"a\":[true, null], \"b\": 2.5 }}}")
        XCTAssertEqual(m.find("files-a")?.state, "{\"b\":2.5,\"a\":[true,null]}")
    }

    func testParseHostileNestingDoesNotCrash() {
        let depth = 20000
        let doc = "{\"columns\":[{\"panes\":[\"a\"]}],\"x\":" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        expectParse(doc, "a^*")
        // …also in a widget state, which is then simply too deep.
        let w = "{\"columns\":[{\"panes\":[\"files-a\"]}],\"widgets\":{\"files-a\":{\"x\":" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}}}"
        let l = P.parse(w)
        expectLayout(l, "files-a^*")
        XCTAssertNil(l.find("files-a")?.state)
        // Unbalanced deep nesting is a syntax error: empty layout.
        expectParse("{\"columns\":[{\"panes\":[\"a\"]}],\"x\":" + String(repeating: "[", count: depth) + "}", "")
    }

    // MARK: Reconciliation edges beyond the app.js cases

    func testReconcileIgnoresRepeatedEmptyAndFilesPrefixedLiveIds() {
        let l = P.load("{\"columns\":[{\"panes\":[\"s1\"]}]}", live: ["s2", "s1", "s2", "", "files-x", "s3"])
        expectLayout(l, "s1^*|s2^|s3^")
    }

    func testReconcileNothingLiveAndNoFilesPanesLeavesEmptyLayout() {
        let l = P.load("{\"columns\":[{\"panes\":[\"s1\",\"s2\"]},{\"panes\":[\"s3\"]}],\"focused\":\"s3\"}", live: [])
        XCTAssertTrue(l.isEmpty)
        XCTAssertNil(l.focused)
    }

    func testReconcileFocusedFilesPaneSurvivesWithNoSessions() {
        let l = P.load("{\"columns\":[{\"panes\":[\"s1\"]},{\"panes\":[\"files-a\"]}],\"focused\":\"files-a\",\"widgets\":{\"files-a\":{\"d\":1}}}", live: [])
        expectLayout(l, "files-a^*")
        XCTAssertEqual(l.find("files-a")?.state, "{\"d\":1}")
    }

    func testReconcileFreshStartIsJustTheLiveSessionsInOrder() {
        expectLayout(P.load("", live: ["b", "a", "c"]), "b^*|a^|c^")
    }

    func testReconcileSavedFocusMayNameALiveSessionOnlyReconciliationAdds() {
        // app.js checks the saved focus after appending.
        expectLayout(P.load("{\"columns\":[{\"panes\":[\"s2\"]}],\"focused\":\"s1\"}", live: ["s1", "s2"]), "s2^|s1^*")
        // parse alone (no reconciliation) cannot know it: first column's active.
        expectLayout(P.parse("{\"columns\":[{\"panes\":[\"s2\"]}],\"focused\":\"s1\"}"), "s2^*")
        let saved = P.parseSaved("{\"columns\":[{\"panes\":[\"s2\"]}],\"focused\":\"s1\"}")
        XCTAssertEqual(saved.focused, "s1")
        XCTAssertNil(saved.layout.focused)
    }

    func testReconcileExistingLayoutFocusPointingIntoItFocusedPaneDropped() throws {
        var l = try LayoutSpec.build("a|b*,c")
        P.reconcile(&l, live: ["a", "c", "d"], savedFocus: l.focused)
        expectLayout(l, "a^*|c^|d^")
    }

    func testReconcileActiveRepickedWhenTheActivePaneGoes() throws {
        var l = try LayoutSpec.build("a,b^,c|d*")
        P.reconcile(&l, live: ["a", "c", "d"], savedFocus: "d")
        expectLayout(l, "a,c^|d^*")
    }

    // MARK: Paths and policy

    func testRelativePathValidatesTheSlug() {
        XCTAssertEqual(P.relativePath(hostSlug: "box-default"), "layout/box-default.json")
        for bad in ["", ".", "..", "a/b", "a\u{0}"] {
            XCTAssertNil(P.relativePath(hostSlug: bad), bad)
        }
        XCTAssertEqual(P.saveDebounce, 0.25)
        XCTAssertEqual(P.version, 1)
    }
}
