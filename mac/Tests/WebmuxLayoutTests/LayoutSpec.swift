// Test helpers: layouts written as compact strings (port of testing.zig).
//
// Spec: columns separated by `|`, panes within a column by `,`. A column
// starting with `!` is full. A pane is its id, optionally `:weight`, then
// `^` if it is its column's active pane (default: the focused pane if it
// is in that column, else the first) and `*` if it is focused (default:
// the first column's active pane).
// Example: `a,b^*|!c|files-x:2,d^`.
//
// `render` writes the canonical form: every column's active pane marked
// `^`, the focused pane `*`, no weights.

import XCTest
@testable import WebmuxLayout

enum LayoutSpec {
    static func build(_ spec: String, file: StaticString = #filePath, line: UInt = #line) throws -> Layout {
        var l = Layout()
        var focused: String? = nil
        if spec.isEmpty { return l }
        for colSpecRaw in spec.split(separator: "|", omittingEmptySubsequences: false) {
            var colSpec = Substring(colSpecRaw)
            var full = false
            if colSpec.hasPrefix("!") {
                full = true
                colSpec = colSpec.dropFirst()
            }
            var ids: [String] = []
            var sizes: [Double] = []
            var active: Int? = nil
            var focusRow: Int? = nil
            for tokRaw in colSpec.split(separator: ",", omittingEmptySubsequences: false) {
                var tok = Substring(tokRaw)
                var isFocus = false
                while let last = tok.last, last == "^" || last == "*" {
                    if last == "^" { active = ids.count } else { isFocus = true }
                    tok = tok.dropLast()
                }
                var w: Double = 1
                if let c = tok.firstIndex(of: ":") {
                    guard let parsed = Double(tok[tok.index(after: c)...]) else {
                        XCTFail("bad weight in \(tokRaw)", file: file, line: line)
                        throw LayoutError.invalidId
                    }
                    w = parsed
                    tok = tok[..<c]
                }
                if isFocus {
                    focused = String(tok)
                    focusRow = ids.count
                }
                ids.append(String(tok))
                sizes.append(w)
            }
            try l.appendColumn(ids: ids, sizes: sizes, active: active ?? focusRow ?? 0, full: full)
        }
        if let f = focused { l.focused = f }
        l.normalizeFocus()
        try l.check()
        return l
    }

    static func render(_ l: Layout) -> String {
        var out = ""
        for (ci, col) in l.columns.enumerated() {
            if ci > 0 { out.append("|") }
            if col.full { out.append("!") }
            for (i, p) in col.panes.enumerated() {
                if i > 0 { out.append(",") }
                out.append(p.id)
                if col.active == p.id { out.append("^") }
                if l.focused == p.id { out.append("*") }
            }
        }
        return out
    }
}

func expectLayout(_ l: Layout, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNoThrow(try l.check(), file: file, line: line)
    XCTAssertEqual(LayoutSpec.render(l), expected, file: file, line: line)
}

func expectSizes(_ l: Layout, _ col: Int, _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
    guard col < l.columns.count else {
        XCTFail("no column \(col)", file: file, line: line)
        return
    }
    let got = l.columns[col].sizes
    XCTAssertEqual(got.count, expected.count, file: file, line: line)
    for (e, g) in zip(expected, got) {
        XCTAssertEqual(e, g, accuracy: 1e-9, file: file, line: line)
    }
}

/// The same layout as the spec: structure, active, focus and weights.
func expectSame(_ l: Layout, spec: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let want = try LayoutSpec.build(spec, file: file, line: line)
    expectLayout(l, LayoutSpec.render(want), file: file, line: line)
    for (ci, col) in want.columns.enumerated() { expectSizes(l, ci, col.sizes, file: file, line: line) }
}

/// The fork's test data (the Zig suite's differential traces from app.js).
/// This Swift target has no resources of its own (Package.swift is not ours
/// to edit), so the files are read from the checkout.
enum Testdata {
    static let directory: URL = {
        // mac/Tests/WebmuxLayoutTests/LayoutSpec.swift → repo root (through
        // any symlink a scratch package may have put in the way).
        var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("gtk/ghostty/src/webmux/layout/testdata", isDirectory: true)
    }()

    static func lines(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let url = directory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else {
            XCTFail("missing test data \(url.path) (is the gtk/ghostty submodule checked out?)", file: file, line: line)
            throw LayoutError.invalidId
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// A small deterministic PRNG (SplitMix64) for the random walks.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
