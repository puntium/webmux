// The workspace model: a horizontal strip of columns, each a vertical stack
// of panes (a terminal session or a file browser), in the style of niri /
// PaperWM. Port of gtk/ghostty/src/webmux/layout/Layout.zig, itself a port
// of the layout half of electron/ui/app.js (layout helpers, session
// actions, pane commands); every command keeps that code's exact
// semantics, including its edge cases. No AppKit, no pixels beyond the
// divider drag (whose arithmetic is in pixels in app.js too).
//
// Everything here is a value type: a `Layout` is a plain copy of its
// columns and panes, so the view can keep the one before a command and
// diff it against the one after (see LayoutChange). Panes are named by id;
// the Zig's `*Pane` / `*Column` pointers become ids and indices.
//
// Invariants (checked by `check()`, which the tests run after every
// command): no empty column; `sizes` parallel to `panes`, every weight
// finite and > 0; each column's `active` is one of its panes; ids are
// unique; `focused` is a pane of the layout, and nil only when the layout
// is empty.

import Foundation

/// A pane is a terminal session (id from the server) or a file browser
/// (client-only id with the `files-` prefix; app.js `isFilesId`).
public enum PaneKind: String, Sendable, Equatable {
    case terminal
    case files

    /// The kind an id denotes: `files-…` is a file browser, anything else a
    /// terminal session id. Compared bytewise, as app.js and the Zig do.
    public static func of(_ id: String) -> PaneKind {
        id.utf8.starts(with: Pane.filesPrefix.utf8) ? .files : .terminal
    }
}

public struct Pane: Sendable, Equatable {
    /// Panes whose id starts with this are file browsers.
    public static let filesPrefix = "files-"

    /// Terminal: the server's session id. Files: `files-<random>`.
    public let id: String
    public let kind: PaneKind
    /// Files panes only: the browser's own state, an opaque JSON object as
    /// text (app.js keeps `{type, dir, cursor}` here). Nil: none saved yet.
    public internal(set) var state: String?

    init(id: String, state: String? = nil) {
        self.id = id
        self.kind = PaneKind.of(id)
        self.state = state
    }

    public var sessionId: String? { kind == .terminal ? id : nil }
}

public struct Column: Sendable, Equatable {
    public internal(set) var panes: [Pane]
    /// Flex weights of the stack, parallel to `panes`; only their ratios
    /// matter (`StackGeometry` normalises).
    public internal(set) var sizes: [Double]
    /// The pane that takes focus when the column is entered from the side.
    public internal(set) var active: String
    /// ⌘F: the column spans the whole window instead of the width rule.
    public internal(set) var full: Bool

    /// app.js `newColumn`: `{ panes: [id], sizes: [1], active: id }`.
    init(pane: Pane) {
        panes = [pane]
        sizes = [1]
        active = pane.id
        full = false
    }

    public var count: Int { panes.count }
    public var ids: [String] { panes.map(\.id) }

    public func indexOf(_ id: String) -> Int? {
        panes.firstIndex { $0.id == id }
    }

    public var activeIndex: Int? { indexOf(active) }
    public var activePane: Pane? { activeIndex.map { panes[$0] } }
}

public struct Position: Sendable, Equatable, Hashable {
    public let col: Int
    public let row: Int
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

public enum HorizontalDirection: Sendable, Equatable, CaseIterable {
    case left, right
    var delta: Int { self == .left ? -1 : 1 }
}

public enum VerticalDirection: Sendable, Equatable, CaseIterable {
    case up, down
    var delta: Int { self == .up ? -1 : 1 }
}

public enum Direction: Sendable, Equatable, CaseIterable {
    case left, right, up, down
}

public enum LayoutError: Error, Sendable, Equatable {
    /// The id is already in the layout.
    case duplicateId
    /// A terminal id with the files prefix, a files id without it, an
    /// empty id, or (for `appendColumn`) inconsistent arguments.
    case invalidId
    /// A files state that is not a JSON object (or nests too deep).
    case invalidState
}

/// What `check()` finds wrong; the tests run it after every command.
public enum LayoutInvariantError: Error, Sendable, Equatable {
    case emptyColumn, sizesMismatch, badWeight, activeNotInColumn, kindMismatch, duplicateId, focusDangling, noFocus
}

public struct Layout: Sendable, Equatable {
    public internal(set) var columns: [Column] = []
    /// The focused pane's id; nil only when the layout is empty (after
    /// `normalizeFocus`).
    public internal(set) var focused: String? = nil

    public init() {}

    // MARK: Queries

    public var isEmpty: Bool { columns.isEmpty }

    public var paneCount: Int { columns.reduce(0) { $0 + $1.count } }

    /// Every pane id, column by column, top to bottom (app.js `allIds`).
    public var allIds: [String] { columns.flatMap(\.ids) }

    public func find(_ id: String) -> Pane? {
        guard let pos = position(of: id) else { return nil }
        return columns[pos.col].panes[pos.row]
    }

    public func position(of id: String) -> Position? {
        for (ci, col) in columns.enumerated() {
            if let i = col.indexOf(id) { return Position(col: ci, row: i) }
        }
        return nil
    }

    public func pane(at pos: Position) -> Pane? {
        guard pos.col >= 0, pos.col < columns.count else { return nil }
        let col = columns[pos.col]
        guard pos.row >= 0, pos.row < col.count else { return nil }
        return col.panes[pos.row]
    }

    public func columnIndex(of id: String) -> Int? { position(of: id)?.col }

    public var focusedPane: Pane? { focused.flatMap(find) }

    public var focusedPosition: Position? { focused.flatMap(position(of:)) }

    /// The column the focused pane is in.
    public var focusedColumn: Int? { focusedPosition?.col }

    /// The columns' full flags, in order (input to `StripGeometry`).
    public var fullFlags: [Bool] { columns.map(\.full) }

    // MARK: Id validation

    /// Validates a new pane's id against the layout and the kind it should be.
    private func checkNewId(_ id: String, kind: PaneKind) throws {
        if id.isEmpty || PaneKind.of(id) != kind { throw LayoutError.invalidId }
        if kind == .files && id.utf8.count == Pane.filesPrefix.utf8.count { throw LayoutError.invalidId }
        if find(id) != nil { throw LayoutError.duplicateId }
    }

    /// A files state must be a JSON object (what app.js stores). Nesting is
    /// capped so that re-serialising it can never overflow a stack.
    public static let maxStateDepth = 64

    /// Whether `text` is a JSON object at most `maxStateDepth` deep.
    public static func isValidState(_ text: String) -> Bool {
        guard let v = JSONParser.parse(text) else { return false }
        if case .object = v {} else { return false }
        return v.depth(from: 0) <= maxStateDepth
    }

    // MARK: Layout helpers (app.js insertIntoColumn / removeFromColumn / focusAfterRemoval)

    /// The new pane gets the column's average weight, i.e. an equal share of
    /// a column that was evenly split and a middling one of a resized one.
    /// It becomes the column's active pane.
    private mutating func insertIntoColumn(_ ci: Int, _ pane: Pane, at index: Int) {
        let sizes = columns[ci].sizes
        let avg = sizes.isEmpty ? 1 : sizes.reduce(0, +) / Double(sizes.count)
        columns[ci].panes.insert(pane, at: index)
        columns[ci].sizes.insert(avg, at: index)
        columns[ci].active = pane.id
    }

    /// Removes the pane from its column; an emptied column disappears with
    /// it. If the pane was the column's active one, the pane now at its
    /// index (else the new last) becomes active.
    private mutating func removeFromColumn(_ id: String) {
        guard let pos = position(of: id) else { return }
        columns[pos.col].panes.remove(at: pos.row)
        columns[pos.col].sizes.remove(at: pos.row)
        if columns[pos.col].panes.isEmpty {
            columns.remove(at: pos.col)
        } else if columns[pos.col].active == id {
            let panes = columns[pos.col].panes
            columns[pos.col].active = panes[min(pos.row, panes.count - 1)].id
        }
    }

    /// The pane that should take focus once `id` goes away: the next one
    /// down its stack, else the one above, else the column to the right's
    /// active pane, else the left one's.
    private func focusAfterRemoval(_ id: String) -> String? {
        guard let pos = position(of: id) else { return nil }
        let col = columns[pos.col]
        if pos.row + 1 < col.count { return col.panes[pos.row + 1].id }
        if pos.row > 0 { return col.panes[pos.row - 1].id }
        if pos.col + 1 < columns.count { return columns[pos.col + 1].active }
        if pos.col > 0 { return columns[pos.col - 1].active }
        return nil
    }

    // MARK: Session actions

    /// ⌘↩: a new terminal (the server already created session `id`) as its
    /// own column immediately right of the focused one, or at the end of
    /// the strip when nothing is focused; it takes focus.
    public mutating func newTerminal(_ id: String) throws {
        try checkNewId(id, kind: .terminal)
        openInNewColumn(Pane(id: id))
    }

    /// ⌘⇧↩: a new file browser, placed like `newTerminal`. `state` is its
    /// initial state (a JSON object; app.js starts at
    /// `{"type":"files","dir":"~","cursor":null}`) or nil.
    public mutating func newFiles(_ id: String, state: String? = nil) throws {
        try checkNewId(id, kind: .files)
        if let s = state, !Layout.isValidState(s) { throw LayoutError.invalidState }
        openInNewColumn(Pane(id: id, state: state))
    }

    private mutating func openInNewColumn(_ pane: Pane) {
        let at = focusedColumn.map { $0 + 1 } ?? columns.count
        columns.insert(Column(pane: pane), at: at)
        focused = pane.id
    }

    /// ⌥⌘↩: a new terminal stacked directly below the focused pane, with the
    /// column's average weight; it takes focus and becomes the column's
    /// active pane. With nothing focused this is `newTerminal`.
    public mutating func newTerminalBelow(_ id: String) throws {
        guard let pos = focusedPosition else { return try newTerminal(id) }
        try checkNewId(id, kind: .terminal)
        let pane = Pane(id: id)
        insertIntoColumn(pos.col, pane, at: pos.row + 1)
        focused = pane.id
    }

    /// Close a pane (⌘W / ✕ on the focused one; a session that exited or is
    /// gone on the host for any other): it leaves the layout. If it was
    /// focused, focus goes to the next pane down its stack, else the one
    /// above, else the right neighbour column's active pane, else the left
    /// one's. Returns false if no pane has this id.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        guard find(id) != nil else { return false }
        if focused == id { focused = focusAfterRemoval(id) }
        removeFromColumn(id)
        return true
    }

    /// Replace a files pane's opaque state (the browser saves as it navigates).
    public mutating func setPaneState(_ id: String, _ state: String?) throws {
        guard let pos = position(of: id), columns[pos.col].panes[pos.row].kind == .files else {
            throw LayoutError.invalidId
        }
        if let s = state, !Layout.isValidState(s) { throw LayoutError.invalidState }
        columns[pos.col].panes[pos.row].state = state
    }

    // MARK: Focus

    /// Focus bookkeeping for a click (app.js `setFocus`): the pane becomes
    /// focused and its column's active pane. Returns whether either changed
    /// (app.js saves the layout only then; it reveals the column either way).
    @discardableResult
    public mutating func setFocus(_ id: String) -> Bool {
        focusPane(id)
    }

    private mutating func focusPane(_ id: String) -> Bool {
        guard let ci = columnIndex(of: id) else { return false }
        if focused == id && columns[ci].active == id { return false }
        focused = id
        columns[ci].active = id
        return true
    }

    /// ⌘←/→: the neighbouring column's active pane; ⌘↑/↓: the neighbour in
    /// the stack. Nothing past either end. Returns true when focus moved
    /// (the view then puts keyboard focus in the pane and reveals it).
    @discardableResult
    public mutating func focus(_ dir: Direction) -> Bool {
        switch dir {
        case .left, .right:
            // app.js: columns[columnIndexOf(focusedId) + dir], where a
            // missing focus is index -1 (so → with no focus picks column 0).
            let ci = focusedColumn ?? -1
            let t = ci + (dir == .left ? -1 : 1)
            if t < 0 || t >= columns.count { return false }
            _ = focusPane(columns[t].active)
            return true
        case .up, .down:
            guard let pos = focusedPosition else { return false }
            let col = columns[pos.col]
            let t = pos.row + (dir == .up ? -1 : 1)
            if t < 0 || t >= col.count { return false }
            _ = focusPane(col.panes[t].id)
            return true
        }
    }

    // MARK: Structural pane commands. Each returns whether the layout
    // changed; the focused pane keeps focus throughout.

    /// ⌥⌘←/→: the whole column (stack and full flag included) swaps places
    /// with its neighbour on that side.
    @discardableResult
    public mutating func moveColumn(_ dir: HorizontalDirection) -> Bool {
        guard let ci = focusedColumn else { return false }
        let t = ci + dir.delta
        if t < 0 || t >= columns.count { return false }
        columns.swapAt(ci, t)
        return true
    }

    /// ⌥⌘↑/↓: the pane swaps places (and weights) with its stack neighbour.
    @discardableResult
    public mutating func movePane(_ dir: VerticalDirection) -> Bool {
        guard let pos = focusedPosition else { return false }
        let j = pos.row + dir.delta
        if j < 0 || j >= columns[pos.col].count { return false }
        columns[pos.col].panes.swapAt(pos.row, j)
        columns[pos.col].sizes.swapAt(pos.row, j)
        return true
    }

    /// ⌘[ / ⌘]: niri's consume-or-expel. A pane sharing a column splits out
    /// into a new column of its own on that side; a pane alone in its
    /// column merges into the neighbouring column on that side, at the
    /// bottom, with that column's average weight (its own column, and that
    /// column's full flag, go away); a lone pane with no column on that
    /// side stays put.
    @discardableResult
    public mutating func consumeOrExpel(_ dir: HorizontalDirection) -> Bool {
        guard let f = focusedPane, let ci = columnIndex(of: f.id) else { return false }
        if columns[ci].count > 1 {
            expel(f, from: ci, dir)
            return true
        }
        let t = ci + dir.delta
        if t < 0 || t >= columns.count { return false }
        removeFromColumn(f.id) // its column goes: it was alone
        let target = t > ci ? t - 1 : t
        insertIntoColumn(target, f, at: columns[target].count)
        return true
    }

    /// The (stacked) pane leaves its column for a new column of its own on
    /// that side. The column it left keeps its full flag.
    private mutating func expel(_ pane: Pane, from ci: Int, _ dir: HorizontalDirection) {
        removeFromColumn(pane.id) // its column survives: it had other panes
        columns.insert(Column(pane: pane), at: dir == .right ? ci + 1 : ci)
    }

    /// ⌘F: toggle the focused pane between the width rule and the whole
    /// window. A stacked pane first splits out into a new column right of
    /// its stack, and that column goes full (the stack keeps its own flag);
    /// a lone pane just flips its column's flag.
    @discardableResult
    public mutating func toggleFull() -> Bool {
        guard let f = focusedPane, let ci = columnIndex(of: f.id) else { return false }
        if columns[ci].count > 1 {
            removeFromColumn(f.id)
            var col = Column(pane: f)
            col.full = true
            columns.insert(col, at: ci + 1)
        } else {
            columns[ci].full.toggle()
        }
        return true
    }

    // MARK: Divider drag

    /// Stacked panes never get shorter than this while a divider is dragged
    /// (app.js MIN_PANE_PX), unless the pair is too short for it.
    public static let minPanePx: Double = 110

    /// app.js makeDivider: the pointer's offset below the top of pane `i`
    /// (`offsetPx`, pointer y − top of pane i) over the span from that top
    /// to the bottom of pane i+1 (`spanPx`, divider included) is the share
    /// of the pair's combined weight pane i gets, clamped so neither side
    /// is shorter than `minPx` (at most 45 % of the span each way).
    public static func dividerRatio(offsetPx: Double, spanPx: Double, minPx: Double) -> Double {
        let m = min(minPx / spanPx, 0.45)
        return min(1 - m, max(m, offsetPx / spanPx))
    }

    /// Drag divider `i` of column `colIndex` (between panes i and i+1).
    /// `StackGeometry.dividerSpan` gives `spanPx`. Returns false (and
    /// changes nothing) for an out-of-range divider or a degenerate span;
    /// app.js would write NaN weights there, which this model never holds.
    @discardableResult
    public mutating func dragDivider(column colIndex: Int, divider i: Int, offsetPx: Double, spanPx: Double, minPx: Double = Layout.minPanePx) -> Bool {
        guard colIndex >= 0, colIndex < columns.count, i >= 0, i + 1 < columns[colIndex].count else { return false }
        guard spanPx > 0, spanPx.isFinite, offsetPx.isFinite else { return false }
        let sizes = columns[colIndex].sizes
        let sum = sizes[i] + sizes[i + 1]
        let ratio = Layout.dividerRatio(offsetPx: offsetPx, spanPx: spanPx, minPx: minPx)
        let a = sum * ratio
        let b = sum * (1 - ratio)
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return false }
        columns[colIndex].sizes[i] = a
        columns[colIndex].sizes[i + 1] = b
        return true
    }

    // MARK: Building from parts (persistence, tests)

    /// Append a column holding these panes (ids must be new and unique; the
    /// kinds follow from the ids) with these weights (each finite and > 0).
    /// `active` is an index into `ids`. Does not touch focus. For
    /// persistence and tests; commands are the normal way to change a
    /// layout. Throws `invalidId` for inconsistent arguments (no ids,
    /// mismatched lengths, `active` out of range) where the Zig asserts.
    public mutating func appendColumn(ids: [String], sizes: [Double], active: Int, full: Bool) throws {
        guard !ids.isEmpty, ids.count == sizes.count, active >= 0, active < ids.count else { throw LayoutError.invalidId }
        for (k, id) in ids.enumerated() {
            if id.isEmpty { throw LayoutError.invalidId }
            if find(id) != nil { throw LayoutError.duplicateId }
            if ids[..<k].contains(id) { throw LayoutError.duplicateId }
        }
        var col = Column(pane: Pane(id: ids[0]))
        col.sizes[0] = sizes[0]
        for (id, w) in zip(ids.dropFirst(), sizes.dropFirst()) {
            col.panes.append(Pane(id: id))
            col.sizes.append(w)
        }
        col.active = ids[active]
        col.full = full
        columns.append(col)
    }

    /// Like `newTerminal`/`newFiles` placement-wise but always at the end
    /// and without focusing (reconciliation: a session opened elsewhere).
    public mutating func appendNewColumn(_ id: String) throws {
        if id.isEmpty { throw LayoutError.invalidId }
        if find(id) != nil { throw LayoutError.duplicateId }
        columns.append(Column(pane: Pane(id: id)))
    }

    /// Drop a pane without the focus fall-through of `remove`
    /// (reconciliation). Focus is cleared if it was this pane.
    public mutating func drop(_ id: String) {
        guard find(id) != nil else { return }
        if focused == id { focused = nil }
        removeFromColumn(id)
    }

    /// What app.js render() does before drawing: a focus that names no pane
    /// falls back to the first column's active pane.
    public mutating func normalizeFocus() {
        if let f = focused, position(of: f) != nil { return }
        focused = columns.first?.active
    }

    // MARK: Invariants

    public func check() throws {
        var count = 0
        var seen = Set<String>()
        for col in columns {
            if col.count == 0 { throw LayoutInvariantError.emptyColumn }
            if col.sizes.count != col.count { throw LayoutInvariantError.sizesMismatch }
            for w in col.sizes where !(w > 0) || !w.isFinite { throw LayoutInvariantError.badWeight }
            if col.indexOf(col.active) == nil { throw LayoutInvariantError.activeNotInColumn }
            for p in col.panes {
                if p.kind != PaneKind.of(p.id) { throw LayoutInvariantError.kindMismatch }
                if !seen.insert(p.id).inserted { throw LayoutInvariantError.duplicateId }
                count += 1
            }
        }
        if let f = focused {
            if position(of: f) == nil { throw LayoutInvariantError.focusDangling }
        } else if count > 0 {
            throw LayoutInvariantError.noFocus
        }
    }
}
