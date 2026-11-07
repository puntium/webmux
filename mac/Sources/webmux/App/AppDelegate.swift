// The application delegate: owns the Ghostty app, the connection engine, the
// main window and the hub of connections, the panels (Connections, Settings,
// Connection Log), dev mode and the control socket. See docs/macos-client.md.
import AppKit
import os
import GhosttyKit
import WebmuxConnection
import WebmuxLayout
import WebmuxPanels
import WebmuxTerminal
import WebmuxWorkspace

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "app")

    /// The one `ghostty_app_t` owner.
    private(set) var ghostty: Ghostty.App?
    private(set) var mainWindow: MainWindowController?
    /// The connection engine (nil only if it failed to start; dev mode runs
    /// one too, deviation 30, so Settings and the log are real there).
    private(set) var engine: ConnectionEngine?
    private(set) var hub: HostHub?
    private let keychain = Keychain()
    private var connections: ConnectionsWindowController?
    private var settings: SettingsWindowController?
    private var logWindow: LogWindowController?
    private var control: ControlServer?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    /// One workspace per connected host (and the dev host), creation order.
    private(set) var workspaces: [HostWorkspace] = []
    private var filesFactory: FilesPaneFactory?
    /// Dev mode's host view (no hub entry behind it).
    private var devHostView: HostContentView?

    /// Dev mode: `WEBMUX_MAC_DEV_SOCKET=<unix socket path>` opens one workspace
    /// on that host without ssh.
    var devSocketPath: String? { AppEnvironment.devSocketPath }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = startEngine()
        self.engine = engine

        let config = TerminalConfig.config(.dark)
        if !config.errors.isEmpty {
            Self.logger.error("terminal config has \(config.errors.count) error(s); see the ghostty log")
        }
        let ghostty = Ghostty.App(config: config)
        self.ghostty = ghostty
        guard ghostty.readiness == .ready else {
            Self.logger.critical("GhosttyKit failed to start")
            let alert = NSAlert()
            alert.messageText = "webmux could not start the terminal engine"
            alert.informativeText = "GhosttyKit failed to initialize. See the log."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let window = MainWindowController(ghostty: ghostty)
        self.mainWindow = window
        if let engine {
            let hub = HostHub(engine: engine, window: window, app: self)
            self.hub = hub
            window.onHostSelected = { [weak hub] name in hub?.show(name, user: true) }
            engine.log.info(nil, "ui ready", [LogField("mode", AppEnvironment.isDevMode ? "dev" : "normal")])
        }

        // The file-browser pane kind, once for every workspace.
        let factory = FilesPaneFactory(engine: engine) { [weak window] in window?.window }
        filesFactory = factory
        WorkspacePaneFactories.shared.register(.files, factory)

        // T-07: the colour scheme reaches the terminals through the Ghostty app,
        // once, app-wide; the fade preview reaches every workspace live.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: PanelNotification.themeChange, object: nil, queue: .main) { [weak self] note in
            let scheme = note.userInfo?[PanelNotification.schemeKey] as? String
            MainActor.assumeIsolated { self?.applyTerminalTheme(TerminalTheme(settingsValue: scheme)) }
        })
        observers.append(center.addObserver(forName: PanelNotification.fadeChange, object: nil, queue: .main) { [weak self] note in
            guard let fade = note.userInfo?[PanelNotification.fadeKey] as? Int else { return }
            MainActor.assumeIsolated { self?.workspaces.forEach { $0.previewFade(fade) } }
        })
        // "System" follows the desktop: re-resolve the palette when it flips.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let s = self.engine?.settings, Appearance(theme: s.theme) == .system else { return }
                    ThemeController.apply(.system)
                }
            }
        }
        // C-09: an image put on the clipboard elsewhere is synced to the front
        // host when the app comes back.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncClipboardImage() }
        })
        ThemeController.apply(Appearance(theme: engine?.settings.theme ?? "dark"))
        if let s = engine?.settings { ThemeController.applyFade(s.unfocusedFade) }

        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let socket = devSocketPath {
            // Dev mode: a full workspace on that host, no ssh (slug `dev`, its
            // layout under the (dev) Application Support root).
            Self.logger.info("dev mode: host socket \(socket, privacy: .public)")
            let view = HostContentView(name: "dev")
            view.socketPath = socket
            view.slug = "dev"
            devHostView = view
            hostDidConnect(view)
            window.showHost(view)
            refreshHosts()
            window.setTitle("webmux (dev)", subtitle: "")
            StatusHUD.setFront("dev", in: window.window)
        } else {
            // W-04 / deviation 67: startup shows the Connections window over the
            // landing view; nothing connects by itself.
            showConnections(nil)
        }

        // X-27: wake from sleep kills every live tunnel so reconnection starts now.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.notifyResume() }
        })

        if let path = AppEnvironment.controlPath {
            do {
                control = try ControlServer(path: path, app: self)
                Self.logger.info("control socket at \(path, privacy: .public)")
            } catch {
                Self.logger.error("control socket: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// T-07: every open terminal repaints with the palette; idempotent.
    private func applyTerminalTheme(_ theme: TerminalTheme) {
        guard let ghostty, theme != TerminalTheme.current || !themeApplied else { return }
        themeApplied = true
        if !ghostty.apply(theme: theme) {
            Self.logger.error("terminal theme \(theme.rawValue, privacy: .public) did not apply (config error)")
        }
    }
    private var themeApplied = false

    /// C-09: the front workspace's focused terminal (else its first live one)
    /// syncs a clipboard image to its host.
    private func syncClipboardImage() {
        guard let ws = frontHostWorkspace else { return }
        if let t = ws.focusedTerminal, t.isLinkUp {
            t.syncClipboardImageIfAny()
        } else {
            TerminalPaneView.syncClipboardImage(through: ws.terminalPanes.map(\.surface))
        }
    }

    // MARK: Workspace access (menus, control socket)

    var frontHostWorkspace: HostWorkspace? { mainWindow?.frontView?.workspace }
    var frontWorkspace: WorkspaceController? { frontHostWorkspace?.controller }
    /// The front workspace's focused terminal pane's surface.
    var focusedTerminal: TerminalPaneView? { frontHostWorkspace?.focusedTerminal }

    /// Create the engine on the Application Support root with the Keychain as
    /// the password store; events hop to the main queue and the hub.
    private func startEngine() -> ConnectionEngine? {
        var options = EngineOptions(paths: AppEnvironment.paths())
        options.passwordStore = keychain
        options.passwordStoreName = "keychain"
        options.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        if let ssh = AppEnvironment.sshExecutable { options.sshExecutable = ssh }
        options.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.hub?.handle(event) }
            }
        }
        do {
            let engine = try ConnectionEngine(options: options)
            // Secrets whose profile id was re-issued at load are orphans (X-09).
            for id in engine.droppedPasswordIDs { try? keychain.delete(profileID: id) }
            if engine.payloadDir == nil {
                Self.logger.warning("no payload directory found; connecting will fail at the deploy step (D-04)")
            }
            return engine
        } catch {
            Self.logger.critical("connection engine: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "webmux could not start its connection engine"
            alert.informativeText = "\(error)\n\nConnections are unavailable; dev mode still works."
            alert.runModal()
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // W-06: closing the main window quits (the panels are not main windows).
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        settings?.flushPendingSave()
        // Save every layout and free the surfaces before the app, so the
        // backends' threads are joined while everything is still alive.
        for ws in workspaces { ws.stop() }
        workspaces.removeAll()
        // W-06: every tunnel and deploy step is killed; remote sessions survive.
        // Bounded: a supervisor stuck behind a pending Keychain prompt must not
        // keep the app from exiting.
        if let engine {
            let done = DispatchSemaphore(value: 0)
            let t = Thread {
                engine.shutdown()
                done.signal()
            }
            t.name = "webmux.engine.shutdown"
            t.start()
            if done.wait(timeout: .now() + 3) == .timedOut {
                Self.logger.warning("engine shutdown did not finish in 3 s; exiting anyway")
            }
        }
        ghostty = nil
    }

    // MARK: Panels

    /// The Connections window, created on first use.
    func connectionsController() -> ConnectionsWindowController? {
        if let c = connections { return c }
        guard let engine else { return nil }
        let c = ConnectionsWindowController(engine: engine, passwords: keychain)
        c.onConnectRequested = { [weak self] name in self?.hub?.connectRequested(name) }
        c.onShowHost = { [weak self] name in self?.hub?.show(name, user: true) }
        c.onOpenLog = { [weak self] in self?.showLog(nil) }
        connections = c
        hub?.refresh()
        return c
    }

    var connectionsControllerIfLoaded: ConnectionsWindowController? { connections }

    func settingsController() -> SettingsWindowController? {
        if let s = settings { return s }
        guard let engine else { return nil }
        let s = SettingsWindowController(engine: engine)
        s.onOpenLog = { [weak self] in self?.showLog(nil) }
        settings = s
        return s
    }

    func logController() -> LogWindowController? {
        if let l = logWindow { return l }
        guard let engine else { return nil }
        let l = LogWindowController(log: engine.log)
        logWindow = l
        return l
    }

    /// E-06: a settings change (from the Settings window or a later source)
    /// applies everywhere; re-applying is idempotent.
    func applySettings(_ s: Settings) {
        ThemeController.apply(Appearance(theme: s.theme))
        ThemeController.applyFade(s.unfocusedFade)
        settings?.apply(settings: s)
        for ws in workspaces { ws.apply(settings: s) }
    }

    // MARK: Workspace per connection

    /// A connection reached `connected`: `view.socketPath` is the tunnel's
    /// local socket and `view.slug` the per-host key. A workspace is built on
    /// it, put in the view and attached (S-01); a reconnect with a new socket
    /// replaces the old one.
    /// Dev mode's host in the switcher (always connected, never in the hub).
    var devHostEntry: HostEntry? {
        guard let v = devHostView else { return nil }
        let kind: HostStatusKind = v.isOffline ? .degraded : .connected
        return HostEntry(name: v.name, kind: kind, active: mainWindow?.frontView === v, workspace: v.workspace?.controller.view)
    }

    /// Push the host list to the switcher (the hub's, or dev mode's alone).
    func refreshHosts() {
        if let hub { hub.refresh() } else if let e = devHostEntry { mainWindow?.setHosts([e]) }
    }

    func hostDidConnect(_ view: HostContentView) {
        Self.logger.info("host connected: \(view.name, privacy: .public) socket \(view.socketPath ?? "-", privacy: .public)")
        guard let ghostty, let socket = view.socketPath else { return }
        if let old = view.workspace {
            old.stop()
            workspaces.removeAll { $0 === old }
        }
        let slug = view.slug ?? Profile.hostSlug(host: view.name, instance: "")
        let layoutURL = URL(fileURLWithPath: AppEnvironment.paths().layoutDir).appendingPathComponent("\(slug).json")
        let ws = HostWorkspace(
            hostView: view,
            connection: WorkspaceConnection(socketPath: socket, name: view.name, slug: slug),
            ghostty: ghostty, layoutURL: layoutURL, settings: engine?.settings, engine: engine,
            window: { [weak self] in self?.mainWindow?.window })
        ws.onOffline = { [weak self, weak view] name, offline in
            self?.hub?.setOffline(name, offline)
            if let self, view != nil, view === self.devHostView { self.refreshHosts() }
        }
        view.workspace = ws
        workspaces.append(ws)
        ws.start()
        refreshHosts()
        if mainWindow?.frontView === view {
            ws.controller.setFront(true)
            ws.controller.focusKeyboard()
        } else {
            ws.controller.setFront(false)
        }
    }

    /// The connection was disconnected and removed; the workspace tears down.
    func hostDidGoAway(_ view: HostContentView) {
        if let ws = view.workspace {
            ws.stop()
            workspaces.removeAll { $0 === ws }
            view.workspace = nil
        }
        view.setContent(nil)
        refreshHosts()
    }

    // MARK: Menu actions

    @objc func showConnections(_ sender: Any?) {
        guard let c = connectionsController() else { return NSSound.beep() }
        c.show()
    }

    @objc func reconnect(_ sender: Any?) {
        hub?.reconnectVisible()
    }

    @objc func openConfigFile(_ sender: Any?) {
        guard let engine else { return NSSound.beep() }
        let path = engine.configPath
        if !FileManager.default.fileExists(atPath: path) {
            // Nothing saved yet: write the (empty) store so the editor has a file.
            _ = engine.updateSettings(Settings.Patch())
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    @objc func showLog(_ sender: Any?) {
        guard let l = logController() else { return NSSound.beep() }
        l.show()
    }

    @objc func showSettings(_ sender: Any?) {
        guard let s = settingsController() else { return NSSound.beep() }
        s.show()
    }

    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show(engineVersion: Ghostty.info.version)
    }

    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/puntium/webmux/blob/main/docs/using.md") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func previousHost(_ sender: Any?) {
        hub?.showNeighbour(-1)
    }

    @objc func nextHost(_ sender: Any?) {
        hub?.showNeighbour(1)
    }

    /// Host 1…9 (the item's tag).
    @objc func showHostNumber(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag, n >= 1 else { return }
        hub?.show(index: n)
    }
}
