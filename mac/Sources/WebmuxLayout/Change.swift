// What a command changed, in the terms app.js's layout animation uses
// (`snapshotStrip`, `matchColumns`, `animateStrip`'s `entryRect` and its
// leaving panes), but in slots rather than pixels: the view takes a
// `LayoutSnapshot` before a command and another after, and `diff` tells it,
// for every pane and divider of the new layout, where it was (an old slot,
// whose old box the view measured or can compute from the old snapshot
// with the width rule) or, if it is new, which old box it opens out of;
// and for every pane that went away, how it should close.
// Port of gtk/ghostty/src/webmux/layout/change.zig.

import Foundation

/// A place in a snapshot: column index, and row (pane index) within it. For
/// a divider, `row` is the divider's index (divider i sits under pane i).
public struct Slot: Sendable, Equatable, Hashable {
    public let col: Int
    public let row: Int
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// An immutable copy of a layout's structure (no file-browser state).
public struct LayoutSnapshot: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let ids: [String]
        public let sizes: [Double]
        public let active: String
        public let full: Bool
        public init(ids: [String], sizes: [Double], active: String, full: Bool) {
            self.ids = ids
            self.sizes = sizes
            self.active = active
            self.full = full
        }
    }

    public let columns: [Column]
    public let focused: String?

    public init(_ layout: Layout) {
        columns = layout.columns.map { Column(ids: $0.ids, sizes: $0.sizes, active: $0.active, full: $0.full) }
        focused = layout.focused
    }

    public init(columns: [Column], focused: String?) {
        self.columns = columns
        self.focused = focused
    }

    public func find(_ id: String) -> Slot? {
        for (ci, c) in columns.enumerated() {
            if let i = c.ids.firstIndex(of: id) { return Slot(col: ci, row: i) }
        }
        return nil
    }

    /// The columns' full flags, in order (input to `StripGeometry`).
    public var fullFlags: [Bool] { columns.map(\.full) }
}

/// A pane of the old layout that a new element opens out of.
public struct Neighbour: Sendable, Equatable {
    public let id: String
    public let old: Slot
    public init(id: String, old: Slot) {
        self.id = id
        self.old = old
    }
}

/// Where an element of the new layout starts its move (app.js animateStrip
/// `from`, or `entryRect` for one that has no old box).
public enum Origin: Sendable, Equatable {
    /// It was on screen: it travels from its old box. For a pane, the slot
    /// is its old slot; for a divider, the matched old column and the
    /// divider's index in it.
    case moved(Slot)
    /// New, opening out of the bottom edge of this old pane (the one above
    /// it now): zero height at that pane's old bottom plus the stack gap
    /// (8 px for a pane; 1 px, the divider's margin, for a divider), with
    /// that pane's old left and width.
    case below(Neighbour)
    /// New, opening out of the top edge of this old pane (the one below it
    /// now): zero height at its old top minus the gap.
    case above(Neighbour)
    /// New, a column of its own (or its divider) opening zero-width just
    /// right of this old column's old box (+ the column gap), at its final
    /// top and height.
    case afterColumn(Int)
    /// …just left of this old column's old box (− the column gap).
    case beforeColumn(Int)
    /// New with nothing old around it (the very first pane): grows from
    /// zero width at its final box.
    case inPlace

    public var isFresh: Bool {
        if case .moved = self { return false }
        return true
    }
}

public struct PaneChange: Sendable, Equatable {
    public let id: String
    public let origin: Origin
}

public struct DividerChange: Sendable, Equatable {
    public let origin: Origin
}

public struct ColumnChange: Sendable, Equatable {
    /// The old column this one continues (app.js matchColumns: greedy by
    /// shared panes, each old column used at most once), or nil.
    public let from: Int?
    /// Parallel to the new column's panes.
    public let panes: [PaneChange]
    /// Parallel to the new column's dividers (panes − 1).
    public let dividers: [DividerChange]
}

/// A pane that went away (app.js removeTile's `leaving`): it stays on
/// screen at its old box while a clip closes in on it.
public struct Leaving: Sendable, Equatable {
    public let id: String
    public let old: Slot
    /// It had its column to itself: wiped from the right as the columns
    /// beyond slide in (clip from its old right edge to its left edge).
    public let alone: Bool
    /// Stacked: it is squeezed to the line where its neighbours meet. The
    /// old neighbour above it, if that pane is still in the layout: the
    /// line is half a stack gap below that pane's new bottom…
    public let above: String?
    /// …else the old neighbour below, if still there: half a gap above its
    /// new top; else the middle of the old box. Clamped to the old box.
    public let below: String?
}

public struct LayoutChange: Sendable, Equatable {
    /// Parallel to the new layout's columns.
    public let columns: [ColumnChange]
    public let leaving: [Leaving]
    /// The focused pane after the change: drawn over the others where boxes
    /// overlap in flight (app.js z-index 3).
    public let focused: String?
    /// False when nothing structural happened (same columns, panes, order,
    /// weights and full flags): no layout animation to run.
    public let structural: Bool

    public func pane(_ id: String) -> PaneChange? {
        for c in columns {
            if let p = c.panes.first(where: { $0.id == id }) { return p }
        }
        return nil
    }

    public func leavingPane(_ id: String) -> Leaving? {
        leaving.first { $0.id == id }
    }

    /// app.js matchColumns: every (new, old) pair sharing panes, sorted by
    /// overlap descending (stable: ties keep new-then-old order), taken
    /// greedily with each new and each old column used once. One entry per
    /// new column: the old column it continues, or nil.
    public static func matchColumns(from before: LayoutSnapshot, to after: LayoutSnapshot) -> [Int?] {
        struct Pair { let n: Int; let o: Int; let overlap: Int }
        var pairs: [Pair] = []
        for (n, nc) in after.columns.enumerated() {
            for (o, oc) in before.columns.enumerated() {
                let overlap = nc.ids.reduce(0) { $0 + (oc.ids.contains($1) ? 1 : 0) }
                if overlap > 0 { pairs.append(Pair(n: n, o: o, overlap: overlap)) }
            }
        }
        // Generated in (n, o) order; the tie-break keeps that order exactly
        // like a stable sort by overlap alone.
        pairs.sort { a, b in
            if a.overlap != b.overlap { return a.overlap > b.overlap }
            if a.n != b.n { return a.n < b.n }
            return a.o < b.o
        }
        var match = [Int?](repeating: nil, count: after.columns.count)
        var used = [Bool](repeating: false, count: before.columns.count)
        for p in pairs {
            if match[p.n] != nil || used[p.o] { continue }
            match[p.n] = p.o
            used[p.o] = true
        }
        return match
    }

    public static func diff(from before: LayoutSnapshot, to after: LayoutSnapshot) -> LayoutChange {
        let match = matchColumns(from: before, to: after)
        var cols: [ColumnChange] = []
        cols.reserveCapacity(after.columns.count)
        for (n, nc) in after.columns.enumerated() {
            var panes: [PaneChange] = []
            for (i, id) in nc.ids.enumerated() {
                let origin: Origin
                if let old = before.find(id) {
                    origin = .moved(old)
                } else {
                    origin = entry(before: before, after: after, match: match, n: n, i: i, kind: .pane)
                }
                panes.append(PaneChange(id: id, origin: origin))
            }
            var dividers: [DividerChange] = []
            for d in 0..<max(nc.ids.count - 1, 0) {
                if let oldCol = match[n], d + 1 < before.columns[oldCol].ids.count {
                    dividers.append(DividerChange(origin: .moved(Slot(col: oldCol, row: d))))
                } else {
                    dividers.append(DividerChange(origin: entry(before: before, after: after, match: match, n: n, i: d, kind: .divider)))
                }
            }
            cols.append(ColumnChange(from: match[n], panes: panes, dividers: dividers))
        }

        var leaving: [Leaving] = []
        for (o, oc) in before.columns.enumerated() {
            for (i, id) in oc.ids.enumerated() {
                if after.find(id) != nil { continue }
                let above = i > 0 && after.find(oc.ids[i - 1]) != nil ? oc.ids[i - 1] : nil
                let below = i + 1 < oc.ids.count && after.find(oc.ids[i + 1]) != nil ? oc.ids[i + 1] : nil
                leaving.append(Leaving(id: id, old: Slot(col: o, row: i), alone: oc.ids.count == 1, above: above, below: below))
            }
        }

        return LayoutChange(
            columns: cols,
            leaving: leaving,
            focused: after.focused,
            structural: !sameStructure(before, after)
        )
    }

    private enum ElementKind { case pane, divider }

    /// app.js animateStrip `entryRect`. For a pane at row i of new column n:
    /// the pane above it (row i−1) if it had an old box, else the pane
    /// below (row i+1); for divider i, the pane above it is row i and below
    /// is i+1. Then the old column matched to new column n−1, else to n+1,
    /// else in place.
    private static func entry(before: LayoutSnapshot, after: LayoutSnapshot, match: [Int?], n: Int, i: Int, kind: ElementKind) -> Origin {
        let ids = after.columns[n].ids
        let aboveRow: Int?
        switch kind {
        case .pane: aboveRow = i > 0 ? i - 1 : nil
        case .divider: aboveRow = i
        }
        let belowRow = i + 1
        if let r = aboveRow, let old = before.find(ids[r]) {
            return .below(Neighbour(id: ids[r], old: old))
        }
        if belowRow < ids.count, let old = before.find(ids[belowRow]) {
            return .above(Neighbour(id: ids[belowRow], old: old))
        }
        if n > 0, let o = match[n - 1] { return .afterColumn(o) }
        if n + 1 < match.count, let o = match[n + 1] { return .beforeColumn(o) }
        return .inPlace
    }

    private static func sameStructure(_ a: LayoutSnapshot, _ b: LayoutSnapshot) -> Bool {
        if a.columns.count != b.columns.count { return false }
        for (x, y) in zip(a.columns, b.columns) {
            if x.full != y.full || x.ids != y.ids { return false }
            if x.sizes.count != y.sizes.count { return false }
            for (p, q) in zip(x.sizes, y.sizes) where p != q { return false }
        }
        return true
    }
}

extension Layout {
    public func snapshot() -> LayoutSnapshot { LayoutSnapshot(self) }

    /// Run `body` on the layout between two snapshots and describe what it
    /// changed: `let change = layout.recording { $0.run(.toggleFull) }`.
    public mutating func recording(_ body: (inout Layout) throws -> Void) rethrows -> LayoutChange {
        let before = snapshot()
        try body(&self)
        return LayoutChange.diff(from: before, to: snapshot())
    }
}
