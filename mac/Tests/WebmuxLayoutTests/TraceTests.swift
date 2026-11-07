// Differential test against app.js itself (port of test_trace.zig). The
// fork's `testdata/gen-trace.js` loads the real layout functions out of
// `electron/ui/app.js` (extracted from the source text by name, DOM and
// network stubbed), runs random command sequences on them and writes, per
// step, the command and the resulting layout in `LayoutSpec` syntax. This
// replays every step on the Swift model and requires the same layout after
// each: columns, panes, order, weights, full flags, active panes and focus.

import XCTest
@testable import WebmuxLayout

final class TraceTests: XCTestCase {
    private struct Step: Decodable {
        let cmd: String
        let id: String?
        let col: Int?
        let row: Int?
        let w: Double?
        let after: String
    }

    func testAppJsDifferentialTrace() throws {
        let lines = try Testdata.lines("app_js_trace.jsonl")
        let decoder = JSONDecoder()
        var l = Layout()
        var n = 0
        var resets = 0
        for line in lines {
            n += 1
            let s = try decoder.decode(Step.self, from: Data(line.utf8))
            if s.cmd == "reset" { // a new run, from an empty layout
                l = Layout()
                resets += 1
                continue
            }
            do {
                try apply(&l, s)
                try expectSame(l, spec: s.after)
            } catch {
                XCTFail("step \(n): \(line): \(error)")
                return
            }
        }
        XCTAssertGreaterThanOrEqual(n, 1000)
        XCTAssertEqual(resets, 16)
    }

    private enum TraceError: Error { case unknownCommand(String), missingArgument, failed }

    private func apply(_ l: inout Layout, _ s: Step) throws {
        switch s.cmd {
        case "new-terminal":
            try l.newTerminal(try s.id ?? { throw TraceError.missingArgument }())
        case "new-terminal-below":
            try l.newTerminalBelow(try s.id ?? { throw TraceError.missingArgument }())
        case "new-files":
            try l.newFiles(try s.id ?? { throw TraceError.missingArgument }(), state: nil)
        case "close-pane":
            if let f = l.focused { if !l.remove(f) { throw TraceError.failed } }
        case "remove":
            if !l.remove(try s.id ?? { throw TraceError.missingArgument }()) { throw TraceError.failed }
        case "click":
            l.setFocus(try s.id ?? { throw TraceError.missingArgument }())
        case "set-weight":
            guard let col = s.col, let row = s.row, let w = s.w else { throw TraceError.missingArgument }
            l.columns[col].sizes[row] = w
        default:
            guard let c = LayoutCommand(name: s.cmd) else { throw TraceError.unknownCommand(s.cmd) }
            l.run(c)
        }
    }
}
