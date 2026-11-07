import XCTest
@testable import WebmuxFiles

final class FilesPaneStateTests: XCTestCase {
    func testRoundTrip() {
        let s = FilesPaneState(dir: "/home/u/src", cursor: "a b.txt")
        XCTAssertEqual(s.json, "{\"type\":\"files\",\"dir\":\"/home/u/src\",\"cursor\":\"a b.txt\"}")
        XCTAssertEqual(FilesPaneState(json: s.json), s)
        let d = FilesPaneState()
        XCTAssertEqual(d.json, "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}")
        XCTAssertEqual(FilesPaneState(json: d.json), d)
    }

    func testEscapes() {
        let s = FilesPaneState(dir: "/x/\"q\"", cursor: "tab\there")
        XCTAssertEqual(FilesPaneState(json: s.json), s)
        // The document must parse as JSON with the three keys.
        let obj = try? JSONSerialization.jsonObject(with: Data(s.json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "files")
        XCTAssertEqual(obj?["dir"] as? String, "/x/\"q\"")
    }

    func testUntrustedInput() {
        XCTAssertEqual(FilesPaneState(json: nil), FilesPaneState())
        XCTAssertEqual(FilesPaneState(json: "not json"), FilesPaneState())
        XCTAssertEqual(FilesPaneState(json: "[1,2]"), FilesPaneState())
        // deviation 28: a dir that is not ~, ~/… or absolute falls back to ~
        XCTAssertEqual(FilesPaneState(json: "{\"dir\":\"relative/x\",\"cursor\":\"a\"}"), FilesPaneState(dir: "~", cursor: "a"))
        XCTAssertEqual(FilesPaneState(json: "{\"dir\":\"~/x\"}").dir, "~/x")
        XCTAssertEqual(FilesPaneState(json: "{\"dir\":\"~x\"}").dir, "~")
        XCTAssertEqual(FilesPaneState(json: "{\"dir\":\"\"}").dir, "~")
        XCTAssertEqual(FilesPaneState(json: "{\"dir\":5}").dir, "~")
        // cursor: a plain name only
        XCTAssertNil(FilesPaneState(json: "{\"cursor\":\"a/b\"}").cursor)
        XCTAssertNil(FilesPaneState(json: "{\"cursor\":\"..\"}").cursor)
        XCTAssertNil(FilesPaneState(json: "{\"cursor\":\"\"}").cursor)
        XCTAssertNil(FilesPaneState(json: "{\"cursor\":null}").cursor)
        XCTAssertEqual(FilesPaneState(json: "{\"cursor\":\".hidden\"}").cursor, ".hidden")
    }
}
