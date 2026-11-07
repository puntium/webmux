// The chrome's state (reference: chrome/hub.zig; electron/main.js "Window &
// views" and "Connections"): one entry per live connection in connection
// order, which host is in front, and the view rules —
//   - startup opens the Connections window; nothing connects by itself (W-04,
//     deviation 67);
//   - connecting from the window marks the entry `reveal`: its workspace comes
//     to the front when the server first answers, unless the user navigated
//     anywhere in the meantime (X-18, X-25, X-28);
//   - a connection whose workspace never came up and fails while in front
//     sends the window back to the Connections window (X-20); one with
//     content rides out retries in place (X-29);
//   - disconnecting the front host opens the Connections window (X-23).
// Main thread only: engine events are hopped here by the AppDelegate.
import AppKit
import os
import WebmuxConnection
import WebmuxPanels

@MainActor
final class HostHub {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "hub")

    @MainActor
    final class Entry {
        var name: String
        var status: ConnectionStatus
        var reveal = false
        let view: HostContentView
        init(status: ConnectionStatus) {
            name = status.name
            self.status = status
            view = HostContentView(name: status.name)
            view.slug = Profile.hostSlug(host: status.host, instance: status.instance)
        }
        var kind: HostStatusKind { HostStatusKind(status: status, offline: view.isOffline) }
    }

    let engine: ConnectionEngine
    unowned let window: MainWindowController
    unowned let app: AppDelegate
    private(set) var entries: [Entry] = []
    /// The host in front; nil = the landing view (or, in dev mode, the dev surface).
    private(set) var active: String?
    /// Names whose connect was just requested from the UI (reveal when the entry appears).
    private var pendingReveal: Set<String> = []

    init(engine: ConnectionEngine, window: MainWindowController, app: AppDelegate) {
        self.engine = engine
        self.window = window
        self.app = app
    }

    var activeEntry: Entry? { entries.first { $0.name == active } }
    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Every host for the toolbar popup, in order.
    var hostList: [(name: String, kind: HostStatusKind, active: Bool)] {
        entries.map { ($0.name, $0.kind, $0.name == active) }
    }

    // MARK: Engine events (already on the main queue)

    func handle(_ event: ConnectionEvent) {
        switch event {
        case .status:
            reconcile()
        case .removed(let name):
            Self.logger.info("connection removed: \(name, privacy: .public)")
            reconcile()
        case .restartDone(let r):
            app.connectionsController()?.restartDone(r)
            StatusHUD.show("\(r.name): \(r.msg)", in: window.window)
            if r.ok, let ws = entry(named: r.name)?.view.workspace {
                // The workspace's sessions are gone; it reloads them (S-13).
                Task { await ws.controller.reload() }
            }
        case .settings(let s):
            app.applySettings(s)
        }
    }

    /// Reconcile the entries against the engine's snapshot (order included),
    /// apply the view rules, and refresh the chrome.
    func reconcile() {
        let snapshot = engine.snapshot()
        var next: [Entry] = []
        for s in snapshot {
            let e: Entry
            if let existing = entries.first(where: { $0.name == s.name }) {
                e = existing
                e.status = s
            } else {
                e = Entry(status: s)
                if pendingReveal.remove(s.name) != nil { e.reveal = true }
                Self.logger.info("connection added: \(s.name, privacy: .public)")
            }
            e.view.name = s.name
            if s.state == .connected, let sock = s.socketPath, e.view.socketPath != sock {
                e.view.socketPath = sock
                e.view.slug = Profile.hostSlug(host: s.host, instance: s.instance)
                app.hostDidConnect(e.view)
            }
            next.append(e)
        }
        let gone = entries.filter { old in !next.contains { $0 === old } }
        entries = next
        for g in gone {
            app.hostDidGoAway(g.view)
            if active == g.name {
                active = nil
                window.showLanding()
                if !AppEnvironment.isDevMode || !entries.isEmpty { app.showConnections(nil) }
            }
        }
        for e in entries {
            // X-25: reveal when the server first answers.
            if e.reveal && e.status.state == .connected {
                e.reveal = false
                show(e.name, user: false)
            }
            // X-20: a front host whose workspace never came up and that failed
            // goes back to the Connections window.
            if e.status.state == .failed && !e.status.hadConnection && !e.view.hasContent && active == e.name {
                app.showConnections(nil)
            }
        }
        refresh()
    }

    /// Push the current state to the window and the Connections window.
    func refresh() {
        window.setHosts(hostList)
        if let e = activeEntry {
            var retry: Int?
            if e.status.state == .retry {
                retry = retryCountdownSeconds(remainingMs: e.status.retryRemainingMs(now: engine.nowMs()))
            }
            window.setTitle(e.name, subtitle: e.kind.stateText(retrySeconds: retry))
        } else if !AppEnvironment.isDevMode {
            window.setTitle("webmux", subtitle: "")
        }
        let offline = Set(entries.filter { $0.view.isOffline }.map { $0.name })
        app.connectionsControllerIfLoaded?.apply(statuses: entries.map { $0.status }, offline: offline)
    }

    // MARK: Navigation

    /// A connect requested from the UI (X-18): reveal its workspace when the
    /// server first answers.
    func connectRequested(_ name: String) {
        if let e = entry(named: name) {
            if e.status.state == .connected && e.status.socketPath != nil {
                show(name, user: true)
            } else {
                e.reveal = true
            }
        } else {
            pendingReveal.insert(name)
        }
        reconcile()
    }

    /// Bring a host to the front. `user` navigation cancels every pending
    /// reveal (X-28) and closes the Connections window (deviation 67).
    func show(_ name: String, user: Bool) {
        guard let e = entry(named: name) else { return }
        if user {
            for x in entries { x.reveal = false }
            pendingReveal.removeAll()
        }
        active = name
        window.showHost(e.view)
        StatusHUD.setFront(name, in: window.window)
        app.connectionsControllerIfLoaded?.window?.orderOut(nil)
        refresh()
    }

    /// K-24: the Nth host (1-based), no-op if none.
    func show(index: Int, user: Bool = true) {
        guard index >= 1, index <= entries.count else { return }
        show(entries[index - 1].name, user: user)
    }

    /// K-25 / K-26: wrapping; from the landing view the last / first host.
    func showNeighbour(_ delta: Int) {
        guard !entries.isEmpty else { return }
        guard let i = entries.firstIndex(where: { $0.name == active }) else {
            show(delta < 0 ? entries[entries.count - 1].name : entries[0].name, user: true)
            return
        }
        let n = entries.count
        show(entries[((i + delta) % n + n) % n].name, user: true)
    }

    /// X-30: reconnect the visible host; with none, show the Connections window.
    func reconnectVisible() {
        guard let name = active else {
            app.showConnections(nil)
            return
        }
        if let err = engine.reconnect(name) {
            StatusHUD.show("\(name): \(err)", in: window.window)
        }
    }

    /// The workspace reports its session sockets down/up (degraded, S-12).
    func setOffline(_ name: String, _ offline: Bool) {
        guard let e = entry(named: name), e.view.isOffline != offline else { return }
        e.view.isOffline = offline
        refresh()
    }
}
