// The layout on disk, and startup reconciliation with the server. Port of
// gtk/ghostty/src/webmux/layout/persist.zig.
//
// File: `~/Library/Application Support/<bundle id>/layout/<host-slug>.json`
// (the app decides the path; `relativePath(hostSlug:)` validates the slug),
// one document holding what the Electron client keeps in two localStorage
// keys, `webmux-layout` (`{columns, focused}`) and `webmux-widgets` (the
// file browsers' state by pane id):
//
//     {"version":1,
//      "columns":[{"panes":["s1","files-x"],"sizes":[1,0.5],"active":"s1","full":false}],
//      "focused":"s1",
//      "widgets":{"files-x":{"type":"files","dir":"~","cursor":null}}}
//
// The file is untrusted. `parse` never fails: anything malformed is
// dropped the way app.js `loadLayout` / `sanitizeColumns` drop it, and a
// document it cannot use at all is an empty layout.

import Foundation

public enum LayoutPersistence {
    public static let version = 1

    /// Deviation 35: layout saves are debounced this long. The caller owns
    /// the timer; this module only encodes.
    public static let saveDebounce: TimeInterval = 0.25

    // MARK: Serialise

    public static func serialize(_ layout: Layout) -> String {
        var out = "{\"version\":\(version),\"columns\":["
        for (ci, col) in layout.columns.enumerated() {
            if ci > 0 { out.append(",") }
            out.append("{\"panes\":[")
            for (i, p) in col.panes.enumerated() {
                if i > 0 { out.append(",") }
                JSONWriter.writeString(p.id, into: &out)
            }
            out.append("],\"sizes\":[")
            out.append(col.sizes.map(JSONWriter.number).joined(separator: ","))
            out.append("],\"active\":")
            JSONWriter.writeString(col.active, into: &out)
            out.append(",\"full\":\(col.full ? "true" : "false")}")
        }
        out.append("],\"focused\":")
        if let f = layout.focused { JSONWriter.writeString(f, into: &out) } else { out.append("null") }
        out.append(",\"widgets\":{")
        var first = true
        for col in layout.columns {
            for p in col.panes {
                guard let state = p.state else { continue }
                if !first { out.append(",") }
                first = false
                JSONWriter.writeString(p.id, into: &out)
                out.append(":")
                out.append(state) // validated as a JSON object when it was set
            }
        }
        out.append("}}")
        return out
    }

    /// The document as UTF-8 bytes, ready for the file.
    public static func encode(_ layout: Layout) -> Data {
        Data(serialize(layout).utf8)
    }

    // MARK: Parse

    /// Build a layout from a saved document. Mirrors app.js loadLayout +
    /// sanitizeColumns:
    /// - unparseable JSON, a root that is not an object, no `columns`
    ///   array, or another `version` → an empty layout;
    /// - a column that is not an object with a `panes` array is skipped;
    /// - a pane id that is not a string (app.js also accepts numbers;
    ///   server ids are strings, so a number never reconciles there
    ///   either), is empty, or repeats an id seen earlier in the document,
    ///   is skipped (with its weight);
    /// - a weight that is not a finite number > 0 (or is missing) becomes 1;
    /// - a column left with no panes is skipped;
    /// - `active` must name one of the column's panes, else the first;
    /// - `full` is true only if it is exactly `true`;
    /// - `focused` is kept if it names a pane, else focus falls back to the
    ///   first column's active pane (app.js render);
    /// - a widget state is kept only for a files pane of the layout, only
    ///   if it is a JSON object, and only up to `Layout.maxStateDepth` deep.
    /// At startup use `load` (parse + reconcile) instead: the saved focus
    /// can name a session that only reconciliation brings into the layout.
    public static func parse(_ text: String) -> Layout {
        var saved = parseSaved(text)
        if let f = saved.focused, saved.layout.find(f) != nil { saved.layout.focused = f }
        saved.layout.normalizeFocus()
        return saved.layout
    }

    public static func parse(_ data: Data) -> Layout {
        guard let text = String(data: data, encoding: .utf8) else { return Layout() }
        return parse(text)
    }

    /// A parsed document before reconciliation: the layout (focus unset)
    /// and the saved `focused` id, which may name no pane of it (app.js
    /// loadLayout: "focused may name a pane that no longer exists").
    public struct Saved: Sendable, Equatable {
        public var layout: Layout
        public var focused: String?
    }

    public static func parseSaved(_ text: String) -> Saved {
        var layout = Layout()
        let empty = Saved(layout: layout, focused: nil)
        guard let root = JSONParser.parse(text), root.isObject else { return empty }
        if let v = root.member("version") {
            guard case .number(let n, let isInteger) = v, isInteger, n == Double(version) else { return empty }
        }
        guard case .array(let columns)? = root.member("columns") else { return empty }

        var seen = Set<String>()
        for col in columns {
            guard col.isObject, case .array(let panes)? = col.member("panes") else { continue }
            var rawSizes: [JSONValue]? = nil
            if case .array(let s)? = col.member("sizes") { rawSizes = s }
            var ids: [String] = []
            var sizes: [Double] = []
            for (i, id) in panes.enumerated() {
                // app.js keeps "" (a terminal id no session has, dropped at
                // reconciliation); it is dropped here already.
                guard case .string(let s) = id, !s.isEmpty else { continue }
                if !seen.insert(s).inserted { continue }
                ids.append(s)
                if let rs = rawSizes, i < rs.count {
                    sizes.append(weight(rs[i]))
                } else {
                    sizes.append(1)
                }
            }
            if ids.isEmpty { continue }
            var active = 0
            if case .string(let act)? = col.member("active"), let k = ids.firstIndex(of: act) { active = k }
            var full = false
            if case .bool(let f)? = col.member("full") { full = f }
            // Ids are deduplicated and non-empty above, so this cannot throw;
            // a column that somehow fails is skipped, as app.js would skip it.
            try? layout.appendColumn(ids: ids, sizes: sizes, active: active, full: full)
        }

        var savedFocus: String? = nil
        if case .string(let f)? = root.member("focused") { savedFocus = f }

        if case .object(let widgets)? = root.member("widgets") {
            for entry in widgets {
                guard let pos = layout.position(of: entry.key), layout.columns[pos.col].panes[pos.row].kind == .files else { continue }
                let v = entry.value
                guard v.isObject, v.depth(from: 0) <= Layout.maxStateDepth else { continue }
                layout.columns[pos.col].panes[pos.row].state = JSONWriter.write(v)
            }
        }
        return Saved(layout: layout, focused: savedFocus)
    }

    /// app.js: `Number(w)`, kept if finite and > 0, else 1. JSON numbers
    /// only: app.js would also accept numeric strings and booleans
    /// (`Number("2")`), which this client never writes (deviation 5).
    private static func weight(_ v: JSONValue) -> Double {
        guard case .number(let w, _) = v else { return 1 }
        return w.isFinite && w > 0 ? w : 1
    }

    // MARK: Startup reconciliation (app.js attachExisting)

    /// Reconcile a saved layout with the server's live session ids (in the
    /// server's order):
    /// - every terminal pane whose session is not live is dropped (in
    ///   layout order, each as app.js removeFromColumn: an emptied column
    ///   goes, a column whose active pane went activates the pane now at
    ///   its index); files panes are client-side and always stay;
    /// - every live session the layout does not hold (opened from another
    ///   client) is appended as a column of its own on the right, in order;
    /// - focus goes to the pane `savedFocus` names if the layout now has it
    ///   (also when it is a live session the saved columns lacked, which
    ///   the previous step just appended), else to the first column's
    ///   active pane.
    /// Afterwards an empty layout means "open a first terminal" (app.js
    /// newSession). File-browser state is already limited to the layout's
    /// panes (pruneWidgetStates). Ids in `live` that repeat, are empty, or
    /// carry the files prefix are ignored (the server never sends them).
    public static func reconcile(_ layout: inout Layout, live: [String], savedFocus: String?) {
        // allIds() is taken before any removal; removing never reorders the
        // rest, so walking a copy keeps app.js's order.
        let liveSet = Set(live)
        var stale: [String] = []
        for col in layout.columns {
            for p in col.panes where p.kind == .terminal && !liveSet.contains(p.id) {
                stale.append(p.id)
            }
        }
        for id in stale { layout.drop(id) }

        var added = Set<String>()
        for id in live {
            if id.isEmpty || PaneKind.of(id) == .files { continue }
            if !added.insert(id).inserted { continue }
            if layout.find(id) != nil { continue }
            try? layout.appendNewColumn(id) // checked above: non-empty, not present
        }

        layout.focused = savedFocus.flatMap { layout.find($0) != nil ? $0 : nil }
        layout.normalizeFocus()
    }

    /// Startup: parse the saved document and reconcile it with the live
    /// session ids (app.js loadLayout + attachExisting). An empty or
    /// missing file is just the live sessions in order.
    public static func load(_ text: String, live: [String]) -> Layout {
        var saved = parseSaved(text)
        reconcile(&saved.layout, live: live, savedFocus: saved.focused)
        return saved.layout
    }

    public static func load(_ data: Data?, live: [String]) -> Layout {
        guard let data = data, let text = String(data: data, encoding: .utf8) else {
            return load("", live: live)
        }
        return load(text, live: live)
    }

    // MARK: Where the file lives

    /// `layout/<host-slug>.json`, relative to the app's Application Support
    /// directory; nil unless the slug is a single plain path component
    /// (non-empty, not `.` or `..`, no `/` or NUL).
    public static func relativePath(hostSlug: String) -> String? {
        if hostSlug.isEmpty || hostSlug == "." || hostSlug == ".." { return nil }
        if hostSlug.utf8.contains(UInt8(ascii: "/")) || hostSlug.utf8.contains(0) { return nil }
        return "layout/\(hostSlug).json"
    }
}
