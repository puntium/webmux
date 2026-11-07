// The strip's animation arithmetic, pure (no AppKit): port of
// gtk/ghostty/src/apprt/webmux/workspace/anim.zig, itself the layout-animation
// half of electron/ui/app.js (`moveEase`, `stripRect`'s mid-flight box,
// `animateStrip`'s `entryRect` and exit cuts). `WorkspaceView` measures boxes
// and feeds them here; everything it animates is a position, a clip and an
// opacity computed from these.
//
// Boxes are in strip space: x from the strip's left edge, unscrolled; y from
// its top edge, downwards (the workspace views are flipped).
import Foundation
import WebmuxLayout

public enum StripAnimation {
    /// app.js MOVE_MS: a structural move of up to `moveRefPx`.
    public static let moveMs: Double = 200
    /// The longest a move takes, however far it goes (deviation 69).
    public static let moveMaxMs: Double = 320
    /// Travel (points) up to which a move takes `moveMs`.
    public static let moveRefPx: Double = 600
    /// app.js: the timeout that ends an animation whose end event never came
    /// fires this long after the move should have ended (L-39).
    public static let settleSlackMs: Double = 50
    /// CSS `transition: opacity 0.12s` on the unfocused fade (L-24).
    public static let fadeMs: Double = 120
    /// app.js STACK_GAP_PX: divider + its margins, pane to pane in a stack.
    public static let stackGap: Double = 8
    /// app.js COL_GAP_PX.
    public static let colGap: Double = 6
    /// `.pane` / `.divider` border radius.
    public static let paneRadius: Double = 8
    public static let dividerRadius: Double = 3
    /// Deviation 69: the ms a move takes for a given travel. app.js moves
    /// everything in 200 ms, which on a wide display is hundreds of pixels
    /// per frame; the time grows with the square root of the distance.
    public static func moveDuration(travel: Double) -> Double {
        guard travel > moveRefPx else { return moveMs }
        return min(moveMaxMs, moveMs * (travel / moveRefPx).squareRoot())
    }

    /// y of a CSS cubic-bezier(x1, y1, x2, y2) at time fraction x (bisection
    /// on the curve's x; app.js moveEase).
    public static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func coord(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if coord(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return coord((lo + hi) / 2, y1, y2)
    }

    /// app.js MOVE_EASE, cubic-bezier(0.4, 0, 0.2, 1).
    public static func moveEase(_ x: Double) -> Double { bezier(x, 0.4, 0, 0.2, 1) }

    /// CSS `ease`, for the fade.
    public static func cssEase(_ x: Double) -> Double { bezier(x, 0.25, 0.1, 0.25, 1) }
}

/// A rectangle in strip space.
public struct Box: Equatable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var w: Double = 0
    public var h: Double = 0

    public init(x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height)
    }

    public var right: Double { x + w }
    public var bottom: Double { y + h }
    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px < right && py >= y && py < bottom
    }

    public static func lerp(_ a: Box, _ b: Box, _ p: Double) -> Box {
        Box(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, w: a.w + (b.w - a.w) * p, h: a.h + (b.h - a.h) * p)
    }

    /// Snap to whole points by rounding each edge (so neighbours that touch
    /// in fractional space still touch).
    public var snapped: Box {
        let x0 = x.rounded(), y0 = y.rounded()
        return Box(x: x0, y: y0, w: max(0, (x + w).rounded() - x0), h: max(0, (y + h).rounded() - y0))
    }
}

/// One element's move: from its old box to its final one.
public struct Flight: Equatable, Sendable {
    public var from: Box
    public var to: Box
    /// It had no old box (a new pane): it also fades in.
    public var fresh: Bool = false

    public init(from: Box, to: Box, fresh: Bool = false) {
        self.from = from
        self.to = to
        self.fresh = fresh
    }

    public func at(_ p: Double) -> Box { Box.lerp(from, to, p) }
    /// Revealed by a clip from its old size up.
    public var grows: Bool { from.w < to.w || from.h < to.h }
    /// A ghost of its shell under it covers the part of the old box it no longer has.
    public var shrinks: Bool { from.w > to.w || from.h > to.h }
    /// How far its farthest edge goes.
    public var travel: Double {
        max(max(abs(to.x - from.x), abs(to.right - from.right)), max(abs(to.y - from.y), abs(to.bottom - from.bottom)))
    }
    /// The ghost's box: at the final top-left, the larger of both sizes.
    public var ghostBox: Box { Box(x: to.x, y: to.y, w: max(from.w, to.w), h: max(from.h, to.h)) }
}

extension StripAnimation {
    /// What a new element opens out of (app.js entryRect), from the change's
    /// origin. `oldPane` gives an old pane's box by its old slot, `oldColumn`
    /// an old column's box. A pane opens a stack gap below the pane above
    /// it, a divider its 1 pt margin.
    public static func entryBox(origin: Origin, isPane: Bool, to: Box, oldPane: (Slot) -> Box?, oldColumn: (Int) -> Box?) -> Box {
        let gap: Double = isPane ? stackGap : 1
        switch origin {
        case .moved:
            return to
        case .below(let n):
            if let a = oldPane(n.old) { return Box(x: a.x, y: a.bottom + gap, w: a.w, h: 0) }
        case .above(let n):
            if let b = oldPane(n.old) { return Box(x: b.x, y: b.y - gap, w: b.w, h: 0) }
        case .afterColumn(let o):
            if let c = oldColumn(o) { return Box(x: c.right + colGap, y: to.y, w: 0, h: to.h) }
        case .beforeColumn(let o):
            if let c = oldColumn(o) { return Box(x: c.x - colGap, y: to.y, w: 0, h: to.h) }
        case .inPlace:
            break
        }
        return Box(x: to.x, y: to.y, w: 0, h: to.h)
    }

    /// The clip a leaving pane closes to, as insets from its old box.
    public struct Cut: Equatable, Sendable {
        public var top: Double = 0
        public var right: Double = 0
        public var bottom: Double = 0
        public var left: Double = 0

        public func scaled(_ p: Double) -> Cut {
            Cut(top: top * p, right: right * p, bottom: bottom * p, left: left * p)
        }
    }

    /// A pane alone in its column is wiped from the right; a stacked one is
    /// squeezed to the line where its neighbours meet: half a gap below the
    /// final bottom of the pane above, else half a gap above the final top of
    /// the pane below, else its own middle, clamped to its old box (L-34).
    public static func exitCut(from: Box, alone: Bool, aboveNew: Box?, belowNew: Box?) -> Cut {
        if alone { return Cut(right: from.w) }
        var meet: Double
        if let a = aboveNew {
            meet = a.bottom + stackGap / 2
        } else if let b = belowNew {
            meet = b.y - stackGap / 2
        } else {
            meet = from.y + from.h / 2
        }
        meet = min(max(meet, from.y), from.bottom)
        return Cut(top: meet - from.y, bottom: from.bottom - meet)
    }

    /// The visible part of a leaving pane at eased progress p, in strip space.
    public static func exitClip(from: Box, cut: Cut, p: Double) -> Box {
        let c = cut.scaled(p)
        return Box(x: from.x + c.left, y: from.y + c.top, w: max(0, from.w - c.left - c.right), h: max(0, from.h - c.top - c.bottom))
    }
}
