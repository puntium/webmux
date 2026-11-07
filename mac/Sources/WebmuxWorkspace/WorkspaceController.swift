// `WorkspaceController`: one connection's workspace. Owns the `Layout`, the
// `WorkspaceView`, the panes, the session calls and the layout file; the
// model half of gtk/ghostty/src/apprt/webmux/workspace/workspace.zig
// (sessions.zig, store.zig). PARITY § 3 (session lifecycle), § 4's commands
// (L-06 … L-18), § 5's chords (through the view), L-40 persistence.
//
// Threading: everything here runs on the main actor. Host calls are `async`
// on the `HostAPI` (Network.framework underneath) and hop back here.
import AppKit
import Combine
import os
import WebmuxHost
import WebmuxLayout
import WebmuxTerminal

/// The workspace's settings (settings.js: min/max column width, unfocused fade).
public struct WorkspaceSettings: Sendable, Equatable {
    public var minCols: Int = 90
    public var maxCols: Int = 200
    /// 0…100 (E-02).
    public var unfocusedFade: Int = 40

    public init(minCols: Int = 90, maxCols: Int = 200, unfocusedFade: Int = 40) {
        self.minCols = minCols
        self.maxCols = maxCols
        self.unfocusedFade = unfocusedFade
    }

    var width: WidthSettings { WidthSettings(minCols: minCols, maxCols: maxCols).sanitized }
    var fadeStrength: Double { Double(min(max(unfocusedFade, 0), 100)) / 100 }
}

/// A connection-log line from the workspace (G-*: the app relays these to the
/// Connection Log window).
public struct WorkspaceLogEntry: Sendable, Equatable {
    public enum Level: String, Sendable { case debug, info, warn, error }
    public let level: Level
    public let message: String
    public let data: [String: String]?
}

/// The built-in factory for terminal panes.
@MainActor
public final class TerminalPaneFactory: WorkspacePaneFactory {
    public let ghostty: Ghostty.App

    public init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
    }

    public enum Failure: Error { case engineNotReady }

    public func makePane(id: String, kind: PaneKind, state: String?, connection: WorkspaceConnection) throws -> WorkspacePane {
        guard let app = ghostty.app else { throw Failure.engineNotReady }
        return TerminalPane(app: app, socketPath: connection.socketPath, sessionId: id)
    }
}

@MainActor
public final class WorkspaceController: NSObject, ObservableObject, WorkspaceViewDelegate, WorkspacePaneHost {
    nonisolated private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "workspace")

    public let connection: WorkspaceConnection
    public let view: WorkspaceView
    public let api: HostAPI
    /// Where the layout is saved (`~/Library/Application Support/<bundle id>/
    /// layout/<slug>.json` is the app's business); nil: never persisted.
    public var layoutURL: URL?
    public private(set) var layout = Layout()

    public var settings: WorkspaceSettings {
        didSet {
            guard settings != oldValue else { return }
            view.widthSettings = settings.width
            view.fadeStrength = settings.fadeStrength
        }
    }

    /// S-12: any session socket dropped and is retrying (cleared when any opens).
    @Published public private(set) var isOffline = false
    @Published public private(set) var paneCount = 0
    /// The session list has been read and the layout built (S-01…S-06).
    @Published public private(set) var isLoaded = false
    /// Session creates in flight.
    @Published public private(set) var pendingCreates = 0

    /// Transient status messages for the window (M-*).
    public var onStatus: ((String) -> Void)?
    /// Connection-log lines (G-*).
    public var onLog: ((WorkspaceLogEntry) -> Void)?
    /// Pane count / offline changed (the window's status).
    public var onSummaryChanged: ((Int, Bool) -> Void)?
    /// A pane was created and is about to enter the strip (the app hooks a
    /// terminal pane's chooser/status relays and a files pane's callbacks here).
    public var onPaneCreated: ((WorkspacePane) -> Void)?

    private let factories: WorkspacePaneFactories
    private let terminalFactory: TerminalPaneFactory
    private var panes: [String: WorkspacePane] = [:]
    /// Sessions to DELETE once their pane is gone (S-09).
    private var pendingKills = Set<String>()
    private var listInFlight = false
    private var listRetry: Timer?
    private var listBackoff: TimeInterval = 1
    private var saveTimer: Timer?
    public private(set) var saveCount = 0
    private var reportedOffline = false
    private var reportedPanes: Int?
    private var detached = false

    public init(connection: WorkspaceConnection, ghostty: Ghostty.App, layoutURL: URL?, settings: WorkspaceSettings = WorkspaceSettings(), factories: WorkspacePaneFactories? = nil) {
        self.connection = connection
        self.api = connection.api
        self.layoutURL = layoutURL
        self.settings = settings
        self.factories = factories ?? .shared
        self.terminalFactory = TerminalPaneFactory(ghostty: ghostty)
        self.view = WorkspaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        view.delegate = self
        view.widthSettings = settings.width
        view.fadeStrength = settings.fadeStrength
    }

    // MARK: Sessions: list (attach, reload), create, close

    /// S-01 … S-07: list the host's sessions and build the workspace from the
    /// saved layout. Completes after one attempt; a failed fetch retries with
    /// backoff (A-07) until `detach()`.
    public func attach() async {
        await fetchSessions()
    }

    /// S-13: reconcile what is on screen with the host (reconnect, Reload).
    public func reload() async {
        await fetchSessions()
    }

    /// Fire-and-forget forms for AppKit callers.
    public func attachInBackground() { Task { await attach() } }

    private func fetchSessions() async {
        guard !listInFlight, !detached else { return }
        listRetry?.invalidate()
        listRetry = nil
        listInFlight = true
        let result: Result<[SessionInfo], Error>
        do {
            result = .success(try await api.sessions.list())
        } catch {
            result = .failure(error)
        }
        listInFlight = false
        guard !detached else { return }
        switch result {
        case .failure(let error):
            log(.error, "session list fetch failed", ["api": connection.socketPath, "error": "\(error)"])
            let secs = Int(listBackoff)
            Self.logger.warning("\(self.connection.name, privacy: .public): session list fetch failed (\(String(describing: error), privacy: .public)); retrying in \(secs) s")
            if panes.isEmpty || listBackoff == 1 {
                onStatus?("Cannot list the sessions on \(connection.name) (\(error)); retrying in \(secs) s")
            }
            listRetry = Timer.scheduledTimer(withTimeInterval: listBackoff, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.listRetry = nil
                    Task { await self.fetchSessions() }
                }
            }
            listBackoff = min(listBackoff * 2, 10)
        case .success(let list):
            listBackoff = 1
            apply(sessionList: list)
        }
    }

    private func apply(sessionList list: [SessionInfo]) {
        let ids = list.map(\.id)
        if !isLoaded {
            log(.info, "page attached", ["sessions": "\(list.count)", "api": connection.socketPath])
            let data = layoutURL.flatMap { try? Data(contentsOf: $0) }
            layout = LayoutPersistence.load(data, live: ids)
            isLoaded = true
        } else {
            view.settleNow()
            let focus = layout.focused
            LayoutPersistence.reconcile(&layout, live: ids, savedFocus: focus)
            for id in panes.keys where layout.find(id) == nil {
                view.removePane(id: id)
                panes.removeValue(forKey: id)
            }
        }
        // Every pane of the model gets its frame (S-04: titles seeded).
        for col in layout.columns {
            for p in col.panes where panes[p.id] == nil {
                let seed = list.first { $0.id == p.id && !$0.title.isEmpty }?.title
                makePane(id: p.id, kind: p.kind, state: p.state, seedTitle: seed)
            }
        }
        view.setLayout(layout)
        scheduleSave()
        reportSummary()

        // S-06: an empty workspace opens a first terminal.
        if layout.isEmpty {
            if pendingCreates == 0 { requestNewTerminal(below: false) }
        } else {
            focusKeyboard()
        }
    }

    private func makePane(id: String, kind: PaneKind, state: String?, seedTitle: String?) {
        let factory: WorkspacePaneFactory? = kind == .terminal ? terminalFactory : factories.factory(for: kind)
        guard let factory else {
            view.addPane(id: id, kind: kind, pane: nil, seedTitle: seedTitle)
            return
        }
        do {
            let pane = try factory.makePane(id: id, kind: kind, state: state, connection: connection)
            pane.host = self
            onPaneCreated?(pane)
            if let state { pane.restore(state: state) }
            panes[id] = pane
            view.addPane(id: id, kind: kind, pane: pane, seedTitle: seedTitle)
        } catch {
            Self.logger.error("\(self.connection.name, privacy: .public): pane \(id, privacy: .public) could not be created: \(String(describing: error), privacy: .public)")
            view.addPane(id: id, kind: kind, pane: nil, seedTitle: seedTitle, placeholderText: "This pane could not be opened (\(error)).")
        }
    }

    /// S-08 / L-06 / L-07: POST a session, then place it. Deviation 6: the
    /// position is decided when the id is known.
    private func requestNewTerminal(below: Bool) {
        pendingCreates += 1
        Task {
            let result: Result<String, Error>
            do {
                result = .success(try await api.sessions.create(cols: 80, rows: 24))
            } catch {
                result = .failure(error)
            }
            pendingCreates = max(0, pendingCreates - 1)
            guard !detached else {
                if case .success(let id) = result { Task { try? await api.sessions.delete(id: id) } }
                return
            }
            switch result {
            case .failure(let error):
                // A-08: a failed create is reported, not swallowed.
                var message = "\(error)"
                if case let HostError.httpStatus(_, m) = error, !m.isEmpty { message = m }
                onStatus?("Could not create a terminal on \(connection.name): \(message)")
                log(.error, "session create failed", nil)
            case .success(let id):
                sessionCreated(id, below: below)
            }
        }
    }

    private func sessionCreated(_ id: String, below: Bool) {
        let capture = view.prepareChange()
        do {
            if below && layout.focused != nil {
                try layout.newTerminalBelow(id)
            } else {
                try layout.newTerminal(id)
            }
        } catch {
            Self.logger.error("\(self.connection.name, privacy: .public): new session \(id, privacy: .public) not added: \(String(describing: error), privacy: .public)")
            return
        }
        makePane(id: id, kind: .terminal, state: nil, seedTitle: nil)
        view.commit(layout, capture: capture, what: below ? "new-terminal-below" : "new-terminal")
        afterChange()
    }

    /// L-08: a file browser as a new column right of the focused one.
    @discardableResult
    public func newFiles() -> String? {
        guard isLoaded else { return nil }
        let id = Self.newFilesId()
        let capture = view.prepareChange()
        do {
            try layout.newFiles(id, state: Self.initialFilesState)
        } catch {
            Self.logger.error("\(self.connection.name, privacy: .public): new file browser not added: \(String(describing: error), privacy: .public)")
            return nil
        }
        makePane(id: id, kind: .files, state: Self.initialFilesState, seedTitle: nil)
        view.commit(layout, capture: capture, what: "new-files")
        afterChange()
        return id
    }

    /// L-06 / L-07: a new terminal (the session is created first).
    public func newTerminal(below: Bool = false) {
        guard isLoaded else { return }
        requestNewTerminal(below: below)
    }

    /// S-09 / L-34: close a pane. `kill`: also DELETE its session on the host
    /// (✕ and close-pane; not for a session that already ended).
    public func closePane(id: String, kill: Bool) {
        guard layout.find(id) != nil else { return }
        let capture = view.prepareChange()
        let kind = layout.find(id)?.kind
        layout.remove(id)
        if kill && kind == .terminal { pendingKills.insert(id) }
        panes.removeValue(forKey: id)
        view.commit(layout, capture: capture, closing: [id], what: "close")
        afterChange()
    }

    /// app.js createFilesWidget: `files-<ms in base 36><0…9999>`.
    static func newFilesId() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return "files-\(String(ms, radix: 36))\(UInt32.random(in: 0..<10000))"
    }

    /// app.js: a new file browser starts in the home directory.
    public static let initialFilesState = "{\"type\":\"files\",\"dir\":\"~\",\"cursor\":null}"

    // MARK: Commands (L-06 … L-18, through the chords and menus)

    public func run(_ cmd: LayoutCommand) {
        guard isLoaded else {
            Self.logger.info("\(self.connection.name, privacy: .public): \(cmd.name, privacy: .public) ignored: sessions not listed yet")
            return
        }
        switch cmd {
        case .newTerminal: requestNewTerminal(below: false)
        case .newTerminalBelow: requestNewTerminal(below: true)
        case .newFiles: newFiles()
        case .closePane:
            if let f = layout.focused { closePane(id: f, kill: true) }
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            guard layout.run(cmd) else { return }
            // Focus moves rebuild nothing (L-22): ring, fade, scroll.
            view.setLayout(layout)
            scheduleSave()
            focusKeyboard()
        default:
            let capture = view.prepareChange()
            guard layout.run(cmd) else { return }
            view.commit(layout, capture: capture, what: cmd.name)
            afterChange()
        }
    }

    private func afterChange() {
        scheduleSave()
        reportSummary()
        focusKeyboard()
    }

    // MARK: Focus (L-19 … L-22)

    /// Focus bookkeeping (app.js setFocus): the pane becomes focused and its
    /// column's active pane; the strip reveals its column. `keyboard`: also
    /// move keyboard focus into it.
    public func setFocus(_ id: String, keyboard: Bool) {
        guard isLoaded else { return }
        if layout.setFocus(id) {
            view.setLayout(layout)
            scheduleSave()
        } else {
            view.reveal()
        }
        if keyboard { focusKeyboard() }
    }

    /// The pane the layout marks focused, if it is on screen.
    public var focusedPane: WorkspacePane? {
        layout.focused.flatMap { view.pane(for: $0) }
    }

    /// Every pane on screen, by id (the control socket).
    public func pane(id: String) -> WorkspacePane? { view.pane(for: id) }

    /// Keyboard focus into the focused pane (or the strip itself when it
    /// holds none, so the pane chords still work).
    public func focusKeyboard() {
        if let f = layout.focused, let p = view.pane(for: f) {
            p.focus()
            return
        }
        view.window?.makeFirstResponder(view)
    }

    /// The workspace in front renders; others pause (W-45).
    public func setFront(_ front: Bool) {
        view.isFront = front
    }

    // MARK: Persistence (L-40, deviation 35)

    private func scheduleSave() {
        guard isLoaded, layoutURL != nil, saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: LayoutPersistence.saveDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveTimer = nil
                self.saveNow()
            }
        }
    }

    /// Write the layout file now (also flushes a pending debounced save).
    public func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isLoaded, let url = layoutURL else { return }
        // File browsers' own state (F-02) goes in with the layout.
        for (id, pane) in panes where pane.kind == .files {
            if let s = pane.persistedState {
                do { try layout.setPaneState(id, s) } catch {
                    Self.logger.warning("\(self.connection.name, privacy: .public): pane \(id, privacy: .public) state not saved: \(String(describing: error), privacy: .public)")
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LayoutPersistence.encode(layout).write(to: url, options: .atomic)
            saveCount += 1
        } catch {
            Self.logger.warning("\(self.connection.name, privacy: .public): layout not saved to \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Teardown

    /// The connection is going away (or the window): save, close every pane.
    public func detach() {
        guard !detached else { return }
        detached = true
        listRetry?.invalidate()
        listRetry = nil
        if saveTimer != nil { saveNow() }
        view.settleNow()
        for id in view.paneIds { view.removePane(id: id) }
        panes.removeAll()
        pendingKills.removeAll()
    }

    // MARK: Summary (S-12)

    private func reportSummary() {
        let n = layout.paneCount
        let offline = isOffline
        if offline != reportedOffline {
            if offline {
                log(.warn, "link down — a session socket dropped and is retrying", nil)
            } else {
                log(.info, "link up — a session socket is open again", nil)
            }
        }
        if let r = reportedPanes, r == n, offline == reportedOffline { return }
        reportedPanes = n
        reportedOffline = offline
        paneCount = n
        onSummaryChanged?(n, offline)
    }

    private func log(_ level: WorkspaceLogEntry.Level, _ message: String, _ data: [String: String]?) {
        onLog?(WorkspaceLogEntry(level: level, message: message, data: data))
    }

    // MARK: WorkspaceViewDelegate

    public func workspaceView(_ view: WorkspaceView, run command: LayoutCommand) {
        run(command)
    }

    public func workspaceView(_ view: WorkspaceView, didPressPane id: String) {
        // A pane whose body cannot take focus by itself gets it here.
        let keyboard = view.pane(for: id) is PlaceholderPane
        setFocus(id, keyboard: keyboard)
    }

    public func workspaceView(_ view: WorkspaceView, didClickBar id: String) {
        setFocus(id, keyboard: true)
    }

    public func workspaceView(_ view: WorkspaceView, didClickClose id: String) {
        closePane(id: id, kill: true)
    }

    public func workspaceView(_ view: WorkspaceView, dragDivider column: Int, index: Int, offsetPx: Double, spanPx: Double) {
        if layout.dragDivider(column: column, divider: index, offsetPx: offsetPx, spanPx: spanPx) {
            view.setLayout(layout)
        }
    }

    public func workspaceViewDividerDragDidEnd(_ view: WorkspaceView) {
        scheduleSave()
    }

    public func workspaceView(_ view: WorkspaceView, didFinishClosing id: String) {
        // S-09: the session is deleted once the pane is gone and its socket
        // closed, so the host's `exit` never reaches it.
        guard pendingKills.remove(id) != nil else { return }
        let api = self.api
        Task.detached {
            do { try await api.sessions.delete(id: id) } catch {
                WorkspaceController.logger.debug("delete session \(id, privacy: .public): \(String(describing: error), privacy: .public) (ignored)")
            }
        }
    }

    // MARK: WorkspacePaneHost

    public func paneTitleDidChange(_ pane: WorkspacePane) {
        view.refreshTitle(id: pane.id)
    }

    public func paneRequestsClose(_ pane: WorkspacePane) {
        let id = pane.id
        Self.logger.info("\(self.connection.name, privacy: .public): pane \(id, privacy: .public) asked to close")
        // Never from inside the call.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.detached else { return }
            self.closePane(id: id, kill: false)
        }
    }

    public func paneStateDidChange(_ pane: WorkspacePane) {
        scheduleSave()
    }

    public func paneDidTakeFocus(_ pane: WorkspacePane) {
        setFocus(pane.id, keyboard: false)
    }

    public func pane(_ pane: WorkspacePane, linkDidChange up: Bool) {
        // app.js setLinkDown: down when any socket drops, up again when any
        // socket opens (not "while any is down").
        isOffline = !up
        Self.logger.info("\(self.connection.name, privacy: .public): pane \(pane.id, privacy: .public) link \(up ? "up" : "down", privacy: .public)")
        reportSummary()
    }
}
