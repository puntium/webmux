// `WorkspaceView`: one connection's strip of columns (electron/ui/app.js
// rendering, strip scrolling, layout animation; the view half of
// gtk/ghostty/src/apprt/webmux/workspace/workspace.zig). The model is a
// `Layout` the controller owns; this view renders a copy of it and reports
// input through its delegate:
//
//   - every pane sits in a `PaneFrame` that is given its final box once
//     (`WorkspaceGeometry`: the width rule and the stacks); the strip scrolls
//     by moving one content view, never sizes;
//   - a structural change animates FLIP style, like app.js animateStrip: the
//     final frames are in place from the first frame and Core Animation moves
//     each frame's layer from where it was (position + bounds, i.e. a
//     translation and a clip) over a ghost of its shell when it shrinks; a
//     closing pane stays at its old box while a clip closes in. Nothing is
//     laid out per frame, so terminals resize (and tell the host their grid)
//     once per change, and only once the move is over (deviation 69:
//     `holdResize`);
//   - the move ends on the compositor's frame clock (the CA transaction's
//     completion), with a timer 50 ms after the end as the bound (L-39);
//   - the strip's reveal scroll is an exponential chase stepped on a
//     CADisplayLink (L-26); a horizontal wheel or swipe pans directly (L-27);
//   - the pane chords are consumed in `performKeyEquivalent` before the
//     surface sees them (T-15).
import AppKit
import QuartzCore
import os
import WebmuxLayout

@MainActor
public protocol WorkspaceViewDelegate: AnyObject {
    /// A pane chord (PARITY § 5) was pressed.
    func workspaceView(_ view: WorkspaceView, run command: LayoutCommand)
    /// The mouse went down somewhere in a pane (L-20).
    func workspaceView(_ view: WorkspaceView, didPressPane id: String)
    /// A click on a pane's title bar (not ✕): keyboard focus into it.
    func workspaceView(_ view: WorkspaceView, didClickBar id: String)
    func workspaceView(_ view: WorkspaceView, didClickClose id: String)
    /// Divider `index` of column `column` is being dragged (L-30); the
    /// delegate runs `Layout.dragDivider` and calls `setLayout`.
    func workspaceView(_ view: WorkspaceView, dragDivider column: Int, index: Int, offsetPx: Double, spanPx: Double)
    func workspaceViewDividerDragDidEnd(_ view: WorkspaceView)
    /// A closing pane's animation ended and its pane is gone.
    func workspaceView(_ view: WorkspaceView, didFinishClosing id: String)
}

/// Boxes as the eye saw them before a change (app.js snapshotStrip), taken
/// with `prepareChange()` before the model changes and handed to `commit`.
public struct ChangeCapture {
    public let before: LayoutSnapshot
    fileprivate let panes: [PaneSlot]
    fileprivate let dividers: [PaneSlot]
    fileprivate let columns: [Box]
    fileprivate let extent: Double

    fileprivate func oldPane(_ s: Slot) -> Box? { panes.first { $0.col == s.col && $0.row == s.row }?.box }
    fileprivate func oldDivider(_ s: Slot) -> Box? { dividers.first { $0.col == s.col && $0.row == s.row }?.box }
    fileprivate func oldColumn(_ i: Int) -> Box? { i < columns.count ? columns[i] : nil }
}

/// One pane of the view, for the control socket and tests.
public struct WorkspacePaneInfo: Equatable {
    public let id: String
    public let kind: PaneKind
    public let title: String
    /// Final box, strip space.
    public let box: Box
    /// On screen right now (mid-flight when animating).
    public let visual: Box
    public let focused: Bool
    public let placeholder: Bool
    public let hasFlight: Bool
}

@MainActor
public final class WorkspaceView: NSView {
    nonisolated private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "workspace")

    /// A wheel notch pans the strip by this many points (app.js wheel deltas).
    public static let wheelStepPx: Double = 53
    /// Cell-width poll (font size and scale changes have no signal).
    public static let cellPollInterval: TimeInterval = 0.5

    public weak var delegate: WorkspaceViewDelegate?

    /// The width rule's settings (E-03/E-04). Changing them refits (L-16).
    public var widthSettings = WidthSettings() {
        didSet { if widthSettings != oldValue { refit() } }
    }
    /// The terminal cell width in points, as the terminals report it.
    public private(set) var cellPx: Double = WorkspaceMetrics.defaultCellPx
    /// Zoom (K-31, deviation 24): scales the cell width the rule sees.
    public var zoom: Double = 1 {
        didSet { if zoom != oldValue { refit() } }
    }
    /// Unfocused fade strength 0…1 (E-02 / 100).
    public var fadeStrength: Double = 0.4 {
        didSet { if fadeStrength != oldValue { updateFocus() } }
    }
    /// Test knobs: force reduced motion; stretch every animation.
    public var reducedMotionOverride: Bool?
    public var timeScale: Double = 1
    /// Whether this workspace is the one in front (panes render only then).
    public var isFront = true {
        didSet { if isFront != oldValue { for it in items { applyShown(it) } } }
    }

    /// The layout as displayed (a copy of the controller's `layout`).
    public private(set) var model = Layout()
    public private(set) var geometry: WorkspaceGeometry?
    /// The scroll offset (points, strip space).
    public private(set) var scroll: Double = 0

    // MARK: Items

    private final class Item {
        let id: String
        let kind: PaneKind
        let frame: PaneFrame
        var pane: WorkspacePane?
        /// From the session list, until the pane reports its own (S-04).
        var seedTitle: String?
        var col = 0
        var row = 0
        /// Final box, snapped, strip space: the frame's frame.
        var box = Box()
        var flight: Flight?
        /// A new pane on its way in: it does not render until it has arrived.
        var arriving = false

        init(id: String, kind: PaneKind, frame: PaneFrame) {
            self.id = id
            self.kind = kind
            self.frame = frame
        }
    }

    private struct Leaving {
        let item: Item
        let from: Box
        let cut: StripAnimation.Cut
    }

    private struct Anim {
        let serial: Int
        let duration: Double
        var timer: Timer?
    }

    private struct Chase {
        var target: Double
        var pos: Double
        var last: CFTimeInterval?
    }

    private let strip = StripContentView()
    private var items: [Item] = []
    private var dividers: [DividerView] = []
    private var ghosts: [GhostView] = []
    private var leaving: [Leaving] = []
    private var anim: Anim?
    private var animSerial = 0
    private var chase: Chase?
    /// The old scroll extent held open while a move runs.
    private var keeper: Double?
    private var displayLink: CADisplayLink?
    private var wheelMonitor: Any?
    private var cellPoll: Timer?
    private var lastSize = NSSize.zero
    private var dragging: DividerView?

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        applyColors()
        strip.frame = bounds
        addSubview(strip)
        cellPoll = Timer.scheduledTimer(withTimeInterval: Self.cellPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCellWidth() }
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        cellPoll?.invalidate()
        chaseTimer?.invalidate()
        if let m = wheelMonitor { NSEvent.removeMonitor(m) }
        displayLink?.invalidate()
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private func applyColors() {
        layer?.backgroundColor = WorkspaceColors.strip(dark: WorkspaceColors.isDark(effectiveAppearance)).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = wheelMonitor {
            NSEvent.removeMonitor(m)
            wheelMonitor = nil
        }
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread, where the view lives.
            guard let self else { return event }
            return self.handleWheel(event) ? nil : event
        }
    }

    // MARK: Panes

    /// Add a pane (or, with `pane` nil, a placeholder saying `placeholderText`)
    /// for `id`. The frame gets its box at the next `setLayout`/`commit`.
    public func addPane(id: String, kind: PaneKind, pane: WorkspacePane?, seedTitle: String? = nil, placeholderText: String? = nil) {
        guard item(id) == nil else { return }
        let frame = PaneFrame(id: id, kind: kind)
        let it = Item(id: id, kind: kind, frame: frame)
        it.seedTitle = seedTitle
        if let pane {
            it.pane = pane
            frame.setBody(pane.view, pane: pane)
        } else {
            let text = placeholderText ?? (kind == .files ? "File browser — not available in this build." : "Terminal — not available in this build.")
            let p = PlaceholderPane(id: id, kind: kind, text: text)
            it.pane = p
            frame.setBody(p.view, pane: p)
        }
        frame.onPressed = { [weak self] in
            guard let self else { return }
            self.delegate?.workspaceView(self, didPressPane: id)
        }
        frame.onBarClicked = { [weak self] in
            guard let self else { return }
            self.delegate?.workspaceView(self, didClickBar: id)
        }
        frame.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.workspaceView(self, didClickClose: id)
        }
        frame.layer?.zPosition = 2
        strip.addSubview(frame)
        items.append(it)
        applyShown(it)
        refreshTitle(it)
    }

    /// Remove a pane at once, without animation (reconciliation). Its pane is closed.
    public func removePane(id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            let it = items.remove(at: i)
            destroy(it)
        }
        if let i = leaving.firstIndex(where: { $0.item.id == id }) {
            let l = leaving.remove(at: i)
            destroy(l.item)
        }
    }

    public var paneIds: [String] { items.map(\.id) }

    public func pane(for id: String) -> WorkspacePane? {
        item(id)?.pane
    }

    public func frame(for id: String) -> PaneFrame? {
        item(id)?.frame
    }

    /// Re-read a pane's title (the pane reported a change).
    public func refreshTitle(id: String) {
        if let it = item(id) { refreshTitle(it) }
    }

    private func item(_ id: String) -> Item? {
        items.first { $0.id == id }
    }

    private func refreshTitle(_ it: Item) {
        let t: String
        if let x = it.pane?.title, !x.isEmpty {
            t = x
        } else if let s = it.seedTitle, !s.isEmpty {
            t = s
        } else {
            t = it.kind == .files ? "files" : it.id
        }
        it.frame.setTitle(t)
    }

    private func destroy(_ it: Item) {
        it.frame.detach()
        it.frame.layer?.removeAllAnimations()
        it.frame.removeFromSuperview()
        it.pane?.close()
        it.pane = nil
        delegate?.workspaceView(self, didFinishClosing: it.id)
    }

    /// A pane renders while its host is in front and it is not on its way in.
    private func applyShown(_ it: Item) {
        it.pane?.setShown(isFront && !it.arriving)
    }

    /// Every pane of the layout has an item (a failed factory gets a placeholder).
    private func ensureItems() {
        for col in model.columns {
            for p in col.panes where item(p.id) == nil {
                addPane(id: p.id, kind: p.kind, pane: nil, placeholderText: "This pane could not be opened.")
            }
        }
    }

    // MARK: Showing a layout

    /// Show `layout` without a layout animation: a focus change (L-22: ring,
    /// fade and reveal only), a divider drag, reconciliation, the first show.
    public func setLayout(_ newLayout: Layout) {
        let structural = LayoutChange.diff(from: model.snapshot(), to: newLayout.snapshot()).structural || geometry == nil
        self.model = newLayout
        ensureItems()
        if structural {
            settle(.now)
            syncDividers()
            relayout()
            clampScrollNow()
        }
        updateFocus()
        reveal()
    }

    /// Before a change: the model's structure and what the eye sees.
    public func prepareChange() -> ChangeCapture {
        var panes: [PaneSlot] = []
        var divs: [PaneSlot] = []
        for it in items {
            panes.append(PaneSlot(col: it.col, row: it.row, box: currentBox(of: it.frame, final: it.box)))
        }
        for d in dividers {
            divs.append(PaneSlot(col: d.col, row: d.row, box: currentBox(of: d, final: d.box)))
        }
        var cols: [Box] = []
        var extent: Double = 0
        if let g = geometry {
            for ci in 0..<g.strip.columns.count { if let b = g.columnBox(ci) { cols.append(b) } }
            extent = max(g.extent, keeper ?? 0)
        }
        return ChangeCapture(before: model.snapshot(), panes: panes, dividers: divs, columns: cols, extent: extent)
    }

    /// After the model changed (new panes were added with `addPane`; the ids
    /// in `closing` left the layout): lay the final geometry out once and
    /// animate into it. `what` names the change for the log.
    public func commit(_ newLayout: Layout, capture: ChangeCapture, closing: [String] = [], what: String = "change") {
        let animate = !reducedMotion && window != nil && geometry != nil && bounds.width > 0
        // Panes held for a move this change interrupts stay held if it
        // starts another (decided below).
        settle(.keepHolds)

        let after = newLayout.snapshot()
        let change = LayoutChange.diff(from: capture.before, to: after)
        model = newLayout

        // The closing panes leave the item list; they are animated out below
        // or destroyed at once.
        var gone: [Item] = []
        for id in closing {
            if let i = items.firstIndex(where: { $0.id == id }) {
                let it = items.remove(at: i)
                it.frame.detach()
                it.pane?.setShown(false)
                gone.append(it)
            }
        }
        ensureItems()
        if animate {
            // Deviation 69: a pane that was on screen keeps drawing at its old
            // size until the move ends (held before its frame changes below);
            // a new pane takes its final size at once and attaches there.
            for it in items where capture.before.find(it.id) != nil { it.pane?.holdResize(true) }
        }
        syncDividers()
        relayout()

        var any = false
        var travel: Double = 0
        var flights: [(CALayer, Flight)] = []
        if animate {
            let f = model.focused
            for it in items {
                guard let pc = change.pane(it.id) else { continue }
                let to = it.box
                let from: Box
                switch pc.origin {
                case .moved(let s): from = capture.oldPane(s) ?? to
                default: from = StripAnimation.entryBox(origin: pc.origin, isPane: true, to: to, oldPane: capture.oldPane, oldColumn: capture.oldColumn)
                }
                let fresh = pc.origin.isFresh
                if !fresh && from == to { continue }
                let fl = Flight(from: from, to: to, fresh: fresh)
                it.flight = fl
                any = true
                travel = max(travel, fl.travel)
                if let layer = it.frame.layer { flights.append((layer, fl)) }
                if fl.shrinks { addGhost(fl, pane: true, focused: f == it.id) }
            }
            for d in dividers {
                guard d.col < change.columns.count, d.row < change.columns[d.col].dividers.count else { continue }
                let origin = change.columns[d.col].dividers[d.row].origin
                let to = d.box
                let from: Box
                switch origin {
                case .moved(let s): from = capture.oldDivider(s) ?? to
                default: from = StripAnimation.entryBox(origin: origin, isPane: false, to: to, oldPane: capture.oldPane, oldColumn: capture.oldColumn)
                }
                if from == to { continue }
                let fl = Flight(from: from, to: to)
                d.flight = fl
                any = true
                travel = max(travel, fl.travel)
                if let layer = d.layer { flights.append((layer, fl)) }
                if fl.shrinks { addGhost(fl, pane: false, focused: false) }
            }
            for it in gone {
                guard let l = change.leavingPane(it.id), let from = capture.oldPane(l.old) else { continue }
                let above = l.above.flatMap { item($0)?.box }
                let below = l.below.flatMap { item($0)?.box }
                leaving.append(Leaving(item: it, from: from, cut: StripAnimation.exitCut(from: from, alone: l.alone, aboveNew: above, belowNew: below)))
                it.frame.layer?.zPosition = 1
                it.frame.frame = from.rect
                any = true
                travel = max(travel, l.alone ? from.w : from.h)
            }
        }
        for it in gone where !leaving.contains(where: { $0.item === it }) {
            destroy(it)
        }

        if any {
            animSerial += 1
            let serial = animSerial
            let duration = StripAnimation.moveDuration(travel: travel) * timeScale / 1000
            Self.logger.debug("\(what, privacy: .public): move \(Int(travel)) pt in \(Int(duration * 1000)) ms")
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1))
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { self?.settleFromAnimation(serial) }
            }
            for (layer, fl) in flights { animateFlight(layer, fl, duration: duration) }
            for g in ghosts { if let fl = g.flight, let layer = g.layer { animateGhost(layer, fl, duration: duration) } }
            for l in leaving { if let layer = l.item.frame.layer { animateLeaving(layer, l, duration: duration) } }
            CATransaction.commit()
            // L-39 / deviation 69: the bound for a move whose completion never
            // comes (the window is not being drawn).
            let timer = Timer.scheduledTimer(withTimeInterval: duration + StripAnimation.settleSlackMs / 1000 * timeScale, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleFromAnimation(serial) }
            }
            anim = Anim(serial: serial, duration: duration, timer: timer)
            holdPanes()
            keeper = capture.extent
        } else if chase == nil {
            releasePanes()
        }

        clampScrollNow()
        if any { chaseEnd() }
        updateFocus()
        reveal()
        positionStrip()
    }

    /// Mid-flight or not, where an element is on screen right now (L-37).
    private func currentBox(of view: NSView, final: Box) -> Box {
        guard anim != nil, let p = view.layer?.presentation() else { return final }
        return Box(p.frame)
    }

    /// The box an element shows right now, for the control socket.
    public func visualBox(of id: String) -> Box? {
        guard let it = item(id) else { return nil }
        return currentBox(of: it.frame, final: it.box)
    }

    // MARK: Core Animation

    /// Position for a visible box `v` (strip space, content origin `c`) of a
    /// layer whose model frame is `m`: a delta on the model position, so
    /// whatever anchor point and orientation AppKit gave the layer, the end
    /// values are its own.
    private func position(of layer: CALayer, visible v: Box, model m: Box) -> CGPoint {
        let a = layer.anchorPoint
        let flipped = layer.superlayer?.isGeometryFlipped ?? true
        let dx = (v.x + Double(a.x) * v.w) - (m.x + Double(a.x) * m.w)
        var dy = (v.y + Double(a.y) * v.h) - (m.y + Double(a.y) * m.h)
        if !flipped { dy = -dy }
        return CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
    }

    private func basic(_ keyPath: String, from: Any, to: Any, duration: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        a.fillMode = .both
        return a
    }

    /// An element at its final frame, travelling from `fl.from` (L-31, L-32):
    /// the clip starts at the smaller of old and new in each dimension (a
    /// growing box is revealed; a shrinking one shows its new size at once
    /// over its ghost), the origin follows the move, a fresh one fades in (L-33).
    private func animateFlight(_ layer: CALayer, _ fl: Flight, duration: Double) {
        let to = fl.to
        let clip = Box(x: fl.from.x, y: fl.from.y, w: min(fl.from.w, to.w), h: min(fl.from.h, to.h))
        let mb = layer.bounds
        layer.add(basic("bounds", from: CGRect(origin: mb.origin, size: CGSize(width: clip.w, height: clip.h)), to: mb, duration: duration), forKey: "wm.bounds")
        layer.add(basic("position", from: position(of: layer, visible: clip, model: to), to: layer.position, duration: duration), forKey: "wm.position")
        if fl.fresh {
            layer.add(basic("opacity", from: 0.0, to: 1.0, duration: duration), forKey: "wm.opacity")
        }
    }

    /// A ghost sits at the element's final box and is clipped from the old box
    /// down to it.
    private func animateGhost(_ layer: CALayer, _ fl: Flight, duration: Double) {
        let mb = layer.bounds
        layer.add(basic("bounds", from: CGRect(origin: mb.origin, size: CGSize(width: fl.from.w, height: fl.from.h)), to: mb, duration: duration), forKey: "wm.bounds")
        layer.add(basic("position", from: position(of: layer, visible: fl.from, model: fl.to), to: layer.position, duration: duration), forKey: "wm.position")
    }

    /// A leaving pane stays at its old box while a clip closes in (L-34). The
    /// animation keeps its end value: the frame is torn down at settle.
    private func animateLeaving(_ layer: CALayer, _ l: Leaving, duration: Double) {
        let clip = StripAnimation.exitClip(from: l.from, cut: l.cut, p: 1)
        let c = l.cut
        let mb = layer.bounds
        let toBounds = CGRect(x: mb.origin.x + c.left, y: mb.origin.y + c.top, width: clip.w, height: clip.h)
        let b = basic("bounds", from: mb, to: toBounds, duration: duration)
        let p = basic("position", from: layer.position, to: position(of: layer, visible: clip, model: l.from), duration: duration)
        for a in [b, p] {
            a.isRemovedOnCompletion = false
            a.fillMode = .forwards
        }
        layer.add(b, forKey: "wm.bounds")
        layer.add(p, forKey: "wm.position")
    }

    private func addGhost(_ fl: Flight, pane: Bool, focused: Bool) {
        let g = GhostView(pane: pane, focused: focused)
        g.flight = fl
        g.frame = fl.to.rect
        g.layer?.zPosition = -1
        strip.addSubview(g)
        ghosts.append(g)
    }

    private enum SettleMode { case now, keepHolds }

    private func settleFromAnimation(_ serial: Int) {
        guard let a = anim, a.serial == serial else { return }
        settle(.now)
    }

    /// End a layout animation (app.js settleStrip): flights cleared, ghosts
    /// and leaving panes gone. The frames were final already.
    private func settle(_ mode: SettleMode) {
        if let a = anim {
            a.timer?.invalidate()
            anim = nil
        }
        for it in items {
            it.flight = nil
            it.frame.layer?.removeAllAnimations()
        }
        for d in dividers {
            d.flight = nil
            d.layer?.removeAllAnimations()
        }
        for g in ghosts { g.removeFromSuperview() }
        ghosts.removeAll()
        let gone = leaving
        leaving.removeAll()
        for l in gone { destroy(l.item) }
        if chase == nil {
            keeper = nil
            clampScrollNow()
            if mode == .now { releasePanes() }
        }
        positionStrip()
    }

    /// End every animation now (tests; a window going away).
    public func settleNow() {
        settle(.now)
        endChase()
    }

    public var isAnimating: Bool { anim != nil }
    public var isChasing: Bool { chase != nil }
    public var scrollTarget: Double? { chase?.target }

    /// While the strip moves, the terminals hold still (deviation 69).
    private func holdPanes() {
        for it in items {
            it.pane?.holdResize(true)
            if let f = it.flight, f.fresh {
                it.arriving = true
                applyShown(it)
            }
        }
    }

    private func releasePanes() {
        for it in items {
            it.pane?.holdResize(false)
            if it.arriving {
                it.arriving = false
                applyShown(it)
            }
        }
    }

    public var reducedMotion: Bool {
        reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Geometry and scrolling (L-15, L-16, L-25 … L-28)

    private var effectiveCellPx: Double { cellPx * max(0.1, zoom) }

    private func syncDividers() {
        var need = 0
        for c in model.columns { need += max(0, c.count - 1) }
        while dividers.count > need {
            let d = dividers.removeLast()
            d.removeFromSuperview()
        }
        while dividers.count < need {
            let d = DividerView()
            d.layer?.zPosition = 1
            d.onDragBegan = { [weak self, weak d] y in
                guard let self, let d else { return }
                self.dividerDragBegan(d, y)
            }
            d.onDragMoved = { [weak self, weak d] y in
                guard let self, let d else { return }
                self.dividerDragMoved(d, y)
            }
            d.onDragEnded = { [weak self, weak d] in
                guard let self, let d else { return }
                self.dividerDragEnded(d)
            }
            strip.addSubview(d)
            dividers.append(d)
        }
        var k = 0
        for (ci, c) in model.columns.enumerated() {
            for row in 0..<max(0, c.count - 1) {
                dividers[k].col = ci
                dividers[k].row = row
                k += 1
            }
        }
    }

    /// Recompute the geometry from the layout and the strip's size, and give
    /// every pane and divider its final box.
    private func relayout() {
        let w = Double(bounds.width), h = Double(bounds.height)
        let g = WorkspaceGeometry(layout: model, width: w, height: h, cellPx: effectiveCellPx, settings: widthSettings)
        geometry = g
        for slot in g.panes {
            let id = model.columns[slot.col].panes[slot.row].id
            guard let it = item(id) else { continue }
            it.col = slot.col
            it.row = slot.row
            it.box = slot.box.snapped
            if it.frame.frame != it.box.rect {
                it.frame.frame = it.box.rect
                // The body takes its size now, not at the next layout pass: a
                // held terminal keeps its old one, any other refits here.
                it.frame.layoutSubtreeIfNeeded()
            }
        }
        for (i, slot) in g.dividers.enumerated() where i < dividers.count {
            dividers[i].box = slot.box.snapped
            dividers[i].frame = dividers[i].box.rect
        }
        positionStrip()
    }

    /// L-16 / deviation 20: a refit (settings, zoom, cell width, size) is
    /// instant and re-reveals the focused column.
    private func refit() {
        settle(.now)
        relayout()
        clampScrollNow()
        updateFocus()
        reveal()
    }

    public override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize = bounds.size
            if geometry != nil || !model.isEmpty {
                refit()
            }
        }
        positionStrip()
    }

    /// The strip's content view, offset by the scroll on the device pixel grid.
    private func positionStrip() {
        let extent = max(geometry?.extent ?? 0, keeper ?? 0, Double(bounds.width))
        let scale = window?.backingScaleFactor ?? 2
        let sx = (scroll * scale).rounded() / scale
        let f = NSRect(x: -sx, y: 0, width: extent, height: bounds.height)
        if strip.frame != f { strip.frame = f }
    }

    public var maxScroll: Double {
        geometry?.maxScroll(keeper: keeper) ?? 0
    }

    private func clampScrollNow() {
        scroll = max(0, min(scroll, maxScroll))
    }

    /// app.js scrollStripTo.
    public func scrollTo(_ targetIn: Double) {
        guard let g = geometry else { return }
        let target = g.clampScroll(targetIn, keeper: keeper)
        if reducedMotion {
            endChase()
            scroll = target
            positionStrip()
            return
        }
        if chase != nil {
            chase?.target = target
            return
        }
        if target == scroll { return }
        chase = Chase(target: target, pos: scroll, last: nil)
        startDisplayLink()
    }

    private func endChase() {
        chase = nil
        stopDisplayLink()
        if anim == nil {
            releasePanes()
            if keeper != nil {
                keeper = nil
                clampScrollNow()
                positionStrip()
            }
        }
    }

    /// L-25 (app.js revealFocusedNow): the minimum scroll that shows the
    /// focused column whole, judged against the target in flight.
    public func reveal() {
        guard let g = geometry, let ci = model.focusedColumn, ci < g.strip.columns.count else { return }
        let c = g.strip.columns[ci]
        let left = c.x - g.strip.stripPad
        let right = c.right + g.strip.stripPad
        var target = chase?.target ?? scroll
        if left < target {
            target = left
        } else if right > target + g.strip.viewport {
            target = right - g.strip.viewport
        }
        scrollTo(target)
    }

    /// L-28 (app.js chaseStripEnd).
    private func chaseEnd() {
        guard let g = geometry, let last = g.strip.columns.last else { return }
        let m = max(0, last.right + g.strip.stripPad - g.strip.viewport)
        if scroll > m { scrollTo(m) }
    }

    /// L-27: a horizontal swipe pans the strip directly, cancelling any reveal in flight.
    public func pan(_ dx: Double) {
        endChase()
        scroll = max(0, min(scroll + dx, maxScroll))
        positionStrip()
    }

    /// The chase's clock: the view's display link while the window is on a
    /// display (steps as even as the frames), a timer otherwise (an occluded
    /// or never-shown window has no frames; the move still has to end).
    private var chaseTimer: Timer?

    private func startDisplayLink() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible {
            chaseTimer?.invalidate()
            chaseTimer = nil
            if displayLink == nil {
                let link = displayLink(target: self, selector: #selector(displayTick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
            if chaseTimer == nil {
                chaseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.chaseStep(refreshMs: 1000.0 / 60) }
                }
            }
        }
    }

    private func stopDisplayLink() {
        displayLink?.isPaused = true
        chaseTimer?.invalidate()
        chaseTimer = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        chaseStep(refreshMs: max(1, (link.targetTimestamp - link.timestamp) * 1000))
    }

    /// One frame of the chase (L-26): `refreshMs` is the step the first tick
    /// counts; later ticks use the clock's own dt, capped at 100 ms.
    private func chaseStep(refreshMs: Double) {
        guard var c = chase else {
            stopDisplayLink()
            return
        }
        let now = CACurrentMediaTime()
        let dt = c.last.map { min((now - $0) * 1000, 100) } ?? refreshMs
        c.last = now
        let step = ChaseStep(pos: c.pos, target: c.target, dtMs: dt / timeScale)
        c.pos = step.pos
        chase = c
        scroll = step.pos
        positionStrip()
        if step.done { endChase() }
    }

    /// The pane under a point in the view's coordinates.
    private func item(at p: NSPoint) -> Item? {
        let sx = Double(p.x) + scroll
        let y = Double(p.y)
        return items.first { $0.box.contains(sx, y) }
    }

    private func handleWheel(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return false }
        let dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        guard abs(dx) > abs(dy) else { return false }
        let px = event.hasPreciseScrollingDeltas ? dx : dx * Self.wheelStepPx
        // A file browser's own columns scroll first (L-27).
        if let it = item(at: p), let pane = it.pane, pane.consumeHorizontalScroll(deltaX: px) { return true }
        // AppKit: a positive delta scrolls towards the start.
        pan(-px)
        return true
    }

    // MARK: Divider drags (L-30)

    private func dividerDragBegan(_ d: DividerView, _ y: Double) {
        settle(.now)
        dragging = d
    }

    private func dividerDragMoved(_ d: DividerView, _ y: Double) {
        guard dragging === d, let g = geometry, d.col < g.stacks.count else { return }
        let st = g.stacks[d.col]
        guard let span = st.dividerSpan(d.row), let offset = st.dividerOffset(d.row, pointerY: y) else { return }
        delegate?.workspaceView(self, dragDivider: d.col, index: d.row, offsetPx: offset, spanPx: span)
    }

    private func dividerDragEnded(_ d: DividerView) {
        guard dragging === d else { return }
        dragging = nil
        delegate?.workspaceViewDividerDragDidEnd(self)
    }

    // MARK: Focus (L-19 … L-23)

    private func updateFocus() {
        let f = model.focused
        for it in items {
            let focused = f == it.id
            it.frame.setFocused(focused, fadeStrength: fadeStrength)
            // L-35: the focused pane above the others while boxes overlap.
            it.frame.layer?.zPosition = focused ? 3 : 2
        }
    }

    // MARK: Cell width (L-16)

    private func checkCellWidth() {
        for it in items where it.kind == .terminal {
            guard let css = it.pane?.cellWidthPx, css > 0 else { continue }
            if abs(css - cellPx) > 0.001 {
                Self.logger.info("cell width \(css) pt (was \(self.cellPx))")
                cellPx = css
                refit()
            }
            return
        }
    }

    // MARK: Keyboard (PARITY § 5, T-15)

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let cmd = WorkspaceCommand.match(event) {
            // K-18: not while a text field has the keyboard.
            if window?.firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
            delegate?.workspaceView(self, run: cmd)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Introspection

    public func paneInfos() -> [WorkspacePaneInfo] {
        var out: [WorkspacePaneInfo] = []
        for col in model.columns {
            for p in col.panes {
                guard let it = item(p.id) else { continue }
                out.append(WorkspacePaneInfo(
                    id: it.id, kind: it.kind, title: it.frame.title, box: it.box,
                    visual: currentBox(of: it.frame, final: it.box),
                    focused: model.focused == it.id,
                    placeholder: it.pane is PlaceholderPane,
                    hasFlight: it.flight != nil))
            }
        }
        return out
    }

    /// Ids of panes still animating out.
    public var leavingIds: [String] { leaving.map(\.item.id) }
    public var ghostCount: Int { ghosts.count }
}

/// The scrolled content: panes, dividers and ghosts in strip space.
final class StripContentView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
}
