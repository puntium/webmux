// The workspace against a real, isolated webmux host (TestHost.swift) in an
// offscreen window: attach, new terminal right/below, close, the chords,
// reconciliation, persistence, the width rule, link state, a session that
// exits. Skipped when the host binary or GhosttyKit's engine is missing.
// Animations run (the window is never shown, but Core Animation still
// completes offscreen); every assertion is on an end state.
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import WebmuxWorkspace
import WebmuxHost
import WebmuxLayout
import WebmuxTerminal
import GhosttyKit

@MainActor
final class WorkspaceLiveTests: XCTestCase {
    nonisolated(unsafe) private static var ghostty: Ghostty.App?

    private var window: NSWindow!
    private var controller: WorkspaceController!
    private var api: HostAPI!
    private var layoutURL: URL!
    private var tempDir: URL!

    override class func tearDown() {
        TestHost.stop()
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        let sock = try TestHost.socketPath()
        _ = NSApplication.shared
        if Self.ghostty == nil {
            // Ghostty's global state first (the app does this in main.swift).
            guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { throw XCTSkip("ghostty_init failed") }
            let app = Ghostty.App(config: TerminalConfig.config(.dark))
            guard app.readiness == .ready else { throw XCTSkip("GhosttyKit did not start") }
            Self.ghostty = app
        }
        api = HostAPI(socketPath: sock, timeout: .seconds(10))
        // A known host state: no sessions.
        for s in try await api.sessions.list() { try? await api.sessions.delete(id: s.id) }
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-ws-\(UUID().uuidString)")
        layoutURL = tempDir.appendingPathComponent("layout/ws-tests.json")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    override func tearDown() async throws {
        controller?.detach()
        controller = nil
        window?.contentView = nil
        window = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeController(settings: WorkspaceSettings = WorkspaceSettings()) -> WorkspaceController {
        let conn = WorkspaceConnection(socketPath: api.client.socketPath, name: "ws-tests", slug: "ws-tests")
        let c = WorkspaceController(connection: conn, ghostty: Self.ghostty!, layoutURL: layoutURL, settings: settings)
        c.view.frame = window.contentLayoutRect
        window.contentView = c.view
        c.view.layoutSubtreeIfNeeded()
        return c
    }

    /// Poll the main actor until `cond` holds (the surfaces' events and the
    /// view's timers run on the main run loop in between).
    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ cond: () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func waitSettled(_ c: WorkspaceController) async throws {
        try await waitUntil("settle") { !c.view.isAnimating && !c.view.isChasing && c.pendingCreates == 0 }
    }

    private func key(_ chars: String, code: Int, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 1, windowNumber: window.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    // MARK: S-01 … S-07

    func testAttachShowsTheHostSessionsAsPanes() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        let b = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        XCTAssertTrue(controller.isLoaded)
        XCTAssertEqual(controller.layout.allIds, [a, b])
        XCTAssertEqual(controller.layout.columns.count, 2)
        XCTAssertEqual(controller.layout.focused, a)
        XCTAssertEqual(Set(controller.view.paneIds), [a, b])
        XCTAssertEqual(controller.paneCount, 2)
        let infos = controller.view.paneInfos()
        XCTAssertEqual(infos.map(\.id), [a, b])
        XCTAssertTrue(infos.allSatisfy { !$0.placeholder && $0.box.w > 0 && $0.box.h > 0 })
        XCTAssertEqual(infos[0].focused, true)
        XCTAssertEqual(infos[1].focused, false)
        // L-15 against the window: fit 2 at 1920 wide, the two columns share it.
        let g = controller.view.geometry!
        XCTAssertEqual(g.strip.widths.fit, 2)
        XCTAssertEqual(infos[0].box.x, 6)
        XCTAssertEqual(infos[0].box.w, 951)
        XCTAssertEqual(infos[1].box.x, 963)
        // The panes are real terminals attached to their sessions.
        let pane = controller.view.pane(for: a) as? TerminalPane
        XCTAssertNotNil(pane)
        try await waitUntil("link up") { pane?.isLinkUp == true }
        XCTAssertFalse(controller.isOffline)
        XCTAssertTrue(pane?.surface.isAttached == true)
        // Frame and layer agree on where a pane is (the animation's assumption).
        let f = controller.view.frame(for: a)!
        XCTAssertEqual(f.layer?.frame, f.frame)
        // Keyboard focus follows the focused pane.
        XCTAssertTrue(window.firstResponder === pane?.surface)
    }

    /// S-06: an empty host gets one terminal.
    func testEmptyHostOpensAFirstTerminal() async throws {
        controller = makeController()
        await controller.attach()
        try await waitUntil("first terminal") { self.controller.paneCount == 1 }
        try await waitSettled(controller)
        let list = try await api.sessions.list()
        XCTAssertEqual(list.map(\.id), controller.layout.allIds)
    }

    // MARK: L-06, L-07, S-08

    func testNewTerminalRightAndBelow() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        controller.newTerminal()
        try await waitUntil("second pane") { self.controller.paneCount == 2 }
        try await waitSettled(controller)
        let b = controller.layout.focused!
        XCTAssertNotEqual(b, a)
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [b]])
        controller.newTerminal(below: true)
        try await waitUntil("third pane") { self.controller.paneCount == 3 }
        try await waitSettled(controller)
        let c = controller.layout.focused!
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [b, c]])
        XCTAssertEqual(controller.layout.columns[1].active, c)
        // The sessions exist on the host, in creation order.
        let live = try await api.sessions.list().map(\.id)
        XCTAssertEqual(live, [a, b, c])
        // Geometry: the stack splits the column, with a divider between.
        let infos = controller.view.paneInfos()
        let ib = infos.first { $0.id == b }!, ic = infos.first { $0.id == c }!
        XCTAssertEqual(ib.box.x, ic.box.x)
        XCTAssertEqual(ib.box.bottom + 8, ic.box.y)
        // The new terminals attach and the frames show the right titles.
        for id in [b, c] {
            let p = controller.view.pane(for: id) as? TerminalPane
            try await waitUntil("link up \(id)") { p?.isLinkUp == true }
        }
        XCTAssertEqual(controller.view.frame(for: c)?.title, c)
        // Terminals took their final size once the move ended.
        let pc = controller.view.pane(for: c) as! TerminalPane
        XCTAssertEqual(pc.surface.frame.size, pc.view.bounds.size)
    }

    // MARK: S-09, L-09, L-34

    func testClosePaneDeletesTheSessionAndThePane() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        let b = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        controller.setFocus(b, keyboard: true)
        controller.closePane(id: b, kill: true)
        XCTAssertEqual(controller.layout.allIds, [a])
        XCTAssertEqual(controller.layout.focused, a)
        XCTAssertEqual(controller.view.leavingIds, [b], "the pane animates out")
        try await waitUntil("pane gone") { self.controller.view.leavingIds.isEmpty && !self.controller.view.isAnimating }
        XCTAssertEqual(controller.view.paneIds, [a])
        try await waitUntil("session deleted") {
            let sema = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ids: [String] = []
            let api = self.api!
            Task.detached {
                ids = (try? await api.sessions.list().map(\.id)) ?? ["?"]
                sema.signal()
            }
            sema.wait()
            return ids == [a]
        }
    }

    // MARK: K-01 … K-15 through the view

    func testChordsDispatchThroughPerformKeyEquivalent() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        let v = controller.view
        // ⌘↩: a new terminal to the right.
        XCTAssertTrue(v.performKeyEquivalent(with: key("\r", code: kVK_Return, [.command])))
        try await waitUntil("new pane") { self.controller.paneCount == 2 }
        try await waitSettled(controller)
        let b = controller.layout.focused!
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [b]])
        // ⌘← / ⌘→: focus moves, nothing else.
        XCTAssertTrue(v.performKeyEquivalent(with: key("h", code: kVK_ANSI_H, [.command])))
        XCTAssertEqual(controller.layout.focused, a)
        XCTAssertTrue(v.performKeyEquivalent(with: key(KeyChord.rightArrow, code: kVK_RightArrow, [.command, .function])))
        XCTAssertEqual(controller.layout.focused, b)
        // ⌥⌘←: the column moves.
        XCTAssertTrue(v.performKeyEquivalent(with: key("h", code: kVK_ANSI_H, [.command, .option])))
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[b], [a]])
        XCTAssertTrue(v.isAnimating)
        try await waitSettled(controller)
        // ⌘[: a lone pane merges into the column on its left... there is none; ⌘] merges right.
        XCTAssertTrue(v.performKeyEquivalent(with: key("]", code: kVK_ANSI_RightBracket, [.command])))
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a, b]])
        try await waitSettled(controller)
        // ⌘F: a stacked pane splits out full.
        XCTAssertTrue(v.performKeyEquivalent(with: key("f", code: kVK_ANSI_F, [.command])))
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [b]])
        XCTAssertEqual(controller.layout.columns[1].full, true)
        try await waitSettled(controller)
        XCTAssertEqual(controller.view.paneInfos().first { $0.id == b }?.box.w, 1908)
        // K-17: not a chord, not swallowed.
        XCTAssertFalse(v.performKeyEquivalent(with: key("w", code: kVK_ANSI_W, [.command, .option])))
        // ⌘W closes the focused pane (and its session).
        XCTAssertTrue(v.performKeyEquivalent(with: key("w", code: kVK_ANSI_W, [.command])))
        XCTAssertEqual(controller.layout.allIds, [a])
        try await waitUntil("pane gone") { self.controller.view.paneIds == [a] && !self.controller.view.isAnimating }
    }

    // MARK: S-13, S-02/S-03 on reload

    func testReconcileAfterASessionVanishesOrAppears() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        let b = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        controller.setFocus(b, keyboard: false)
        // Killed by another client, unnoticed until a reload (S-11)…
        try await api.sessions.delete(id: b)
        // …except that the host tells the attached pane: it closes itself (S-10).
        try await waitUntil("exit closes the pane") { self.controller.layout.find(b) == nil && self.controller.view.paneIds == [a] }
        XCTAssertEqual(controller.layout.focused, a)
        // A session created elsewhere appears at the right end on reload (S-03).
        let c = try await api.sessions.create(cols: 80, rows: 24)
        await controller.reload()
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [c]])
        XCTAssertEqual(controller.layout.focused, a)
        XCTAssertEqual(Set(controller.view.paneIds), [a, c])
    }

    // MARK: L-40 … L-42

    func testPersistenceRoundTrip() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        let b = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        controller.run(.moveColumnRight) // [b, a], focus a
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[b], [a]])
        let files = controller.newFiles()!
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[b], [a], [files]])
        try await waitUntil("debounced save") { self.controller.saveCount >= 1 }
        try await waitSettled(controller)
        controller.saveNow()
        let data = try Data(contentsOf: layoutURL)
        let parsed = LayoutPersistence.parse(data)
        XCTAssertEqual(parsed.columns.map(\.ids), [[b], [a], [files]])
        XCTAssertEqual(parsed.focused, files)
        XCTAssertEqual(parsed.find(files)?.state, WorkspaceController.initialFilesState)

        // A second controller on the same file comes back in the saved order, not the server's.
        controller.detach()
        let second = makeController()
        controller = second
        await second.attach()
        XCTAssertEqual(second.layout.columns.map(\.ids), [[b], [a], [files]])
        XCTAssertEqual(second.layout.focused, files)
        // The files pane has no factory in this target: a placeholder.
        XCTAssertEqual(second.view.paneInfos().first { $0.id == files }?.placeholder, true)
        XCTAssertEqual(second.view.frame(for: files)?.title, "files")
    }

    // MARK: L-15 / L-16 against the window

    func testWidthRuleFollowsTheWindow() async throws {
        let ids = try await (0..<3).asyncMap { _ in try await api.sessions.create(cols: 80, rows: 24) }
        controller = makeController()
        await controller.attach()
        let v = controller.view
        // Three columns at 1920: fit 2 → the strip overflows at the column minimum.
        let cell = v.cellPx
        let widths = ColumnWidths(stripWidth: 1920, cellPx: cell, settings: WidthSettings(), metrics: WorkspaceMetrics.strip)
        XCTAssertEqual(v.geometry?.strip.widths, widths)
        XCTAssertTrue(v.geometry!.strip.overflows)
        XCTAssertEqual(v.paneInfos().map(\.box.w), [widths.min, widths.min, widths.min])
        // Narrower: a resize refits at once (deviation 20) and re-reveals the focused column.
        window.setContentSize(NSSize(width: 1000, height: 700))
        v.layoutSubtreeIfNeeded()
        let w2 = ColumnWidths(stripWidth: 1000, cellPx: cell, settings: WidthSettings(), metrics: WorkspaceMetrics.strip)
        XCTAssertEqual(w2.fit, 1)
        XCTAssertEqual(v.geometry?.strip.widths, w2)
        XCTAssertEqual(v.paneInfos().first?.box.w, 988)
        // Focus the last column: the strip reveals it (L-25), chasing to the end.
        controller.setFocus(ids[2], keyboard: false)
        try await waitUntil("reveal") { !v.isChasing }
        XCTAssertEqual(v.scroll, v.maxScroll)
        // Narrower settings: the rule follows the settings live (L-16);
        // px(40) at an 8 pt cell is 344, so two fit in 988.
        controller.settings = WorkspaceSettings(minCols: 40, maxCols: 60)
        XCTAssertEqual(v.geometry?.strip.widths.fit, ColumnWidths(stripWidth: 1000, cellPx: cell, settings: WidthSettings(minCols: 40, maxCols: 60), metrics: WorkspaceMetrics.strip).fit)
        XCTAssertEqual(v.geometry?.strip.widths.fit, 2)
        // Zoom: a wider cell, fewer fit (K-31).
        v.zoom = 2
        XCTAssertEqual(v.geometry?.strip.widths.fit, 1)
    }

    // MARK: L-31, L-33, L-37: the move travels, and ends where the frames are

    func testAMoveTravelsAndSettlesAtTheFinalBoxes() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        let b = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        let v = controller.view
        v.timeScale = 5 // a 200 ms move takes 1 s
        let before = v.paneInfos().map(\.box)
        controller.run(.moveColumnRight) // [b, a]
        XCTAssertTrue(v.isAnimating)
        let after = v.paneInfos().map(\.box)
        XCTAssertEqual(after.map(\.x), [before[0].x, before[1].x], "final frames are in place from the first frame")
        try await Task.sleep(for: .milliseconds(400))
        if let mid = v.visualBox(of: a), v.isAnimating {
            // a travels from column 0 to column 1: mid-flight it is strictly between.
            XCTAssertGreaterThan(mid.x, before[0].x)
            XCTAssertLessThan(mid.x, before[1].x)
            // A pane's terminal holds its size while the strip moves (deviation 69).
            let pane = v.pane(for: a) as! TerminalPane
            XCTAssertEqual(pane.surface.frame.size, pane.view.bounds.size, "same-size move: nothing to hold")
        }
        // L-37: a change mid-flight continues from the current geometry.
        controller.run(.moveColumnLeft) // back to [a, b]
        XCTAssertTrue(v.isAnimating)
        try await waitUntil("settle", timeout: 4) { !v.isAnimating }
        XCTAssertEqual(controller.layout.columns.map(\.ids), [[a], [b]])
        for info in v.paneInfos() {
            XCTAssertEqual(info.visual, info.box, "\(info.id) rests at its final box")
        }
        XCTAssertEqual(v.ghostCount, 0)
        XCTAssertTrue(v.leavingIds.isEmpty)
        // A new pane below: it arrives faded in, and its terminal takes its size once.
        v.timeScale = 1
        controller.newTerminal(below: true)
        try await waitUntil("new pane") { self.controller.paneCount == 3 }
        try await waitSettled(controller)
        let c = controller.layout.focused!
        let pc = v.pane(for: c) as! TerminalPane
        XCTAssertEqual(pc.surface.frame.size, pc.view.bounds.size)
        XCTAssertEqual(v.frame(for: c)?.layer?.opacity, 1)
        XCTAssertEqual(v.frame(for: c)?.layer?.animationKeys() ?? [], [])
    }

    // MARK: Divider drag (L-30)

    func testDividerDragResplitsTheStack() async throws {
        let a = try await api.sessions.create(cols: 80, rows: 24)
        controller = makeController()
        await controller.attach()
        controller.newTerminal(below: true)
        try await waitUntil("stack") { self.controller.paneCount == 2 }
        try await waitSettled(controller)
        let g = controller.view.geometry!
        let span = g.stacks[0].dividerSpan(0)!
        // Pointer at a quarter of the span: pane 0 gets 25 %.
        controller.workspaceView(controller.view, dragDivider: 0, index: 0, offsetPx: span / 4, spanPx: span)
        let sizes = controller.layout.columns[0].sizes
        XCTAssertEqual(sizes[0] / (sizes[0] + sizes[1]), 0.25, accuracy: 1e-9)
        let infos = controller.view.paneInfos()
        XCTAssertLessThan(infos[0].box.h, infos[1].box.h)
        XCTAssertEqual(controller.layout.allIds.first, a)
    }
}

extension Range where Bound == Int {
    func asyncMap<T>(_ f: (Int) async throws -> T) async throws -> [T] {
        var out: [T] = []
        for i in self { out.append(try await f(i)) }
        return out
    }
}
