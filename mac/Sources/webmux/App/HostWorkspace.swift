// One connection's workspace in the app: a `WorkspaceController` (the
// Workspace area) wired to the chrome. Created by the AppDelegate when a
// connection reaches `connected` (or for the dev host), torn down when it goes
// away. The wiring, in one place:
//
//   controller.onStatus         → the HUD, from this connection (M-*)
//   controller.onLog            → the engine's connection log under the host name (G-*)
//   controller.onSummaryChanged → HostContentView.paneCount / isOffline, HostHub.setOffline (S-12)
//   controller.onPaneCreated    → a terminal pane's chooser/status relays (TerminalPaneDelegate):
//                                 chooseLink → LinkChooser (M-04), status → the HUD
//   Settings (min/max cols, fade) → controller.settings, live
import AppKit
import os
import WebmuxConnection
import WebmuxLayout
import WebmuxPanels
import WebmuxTerminal
import WebmuxWorkspace

@MainActor
final class HostWorkspace {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "app")

    let controller: WorkspaceController
    let hostView: HostContentView
    let name: String
    private weak var engine: ConnectionEngine?
    private let window: () -> NSWindow?
    /// The hub's offline flag (nil in dev mode).
    var onOffline: ((String, Bool) -> Void)?

    init(hostView: HostContentView, connection: WorkspaceConnection, ghostty: Ghostty.App, layoutURL: URL?,
         settings: Settings?, engine: ConnectionEngine?, window: @escaping () -> NSWindow?) {
        self.hostView = hostView
        self.name = connection.name
        self.engine = engine
        self.window = window
        controller = WorkspaceController(
            connection: connection, ghostty: ghostty, layoutURL: layoutURL,
            settings: Self.workspaceSettings(settings))
        let name = connection.name
        controller.onStatus = { [window] text in StatusHUD.show(text, from: name, in: window()) }
        controller.onLog = { [weak engine] entry in
            let data = (entry.data ?? [:]).keys.sorted().map { LogField($0, entry.data?[$0] ?? "") }
            _ = engine?.log.push(level: LogLevel(rawValue: entry.level.rawValue) ?? .info, src: .page, conn: name, msg: entry.message, data: data)
        }
        controller.onSummaryChanged = { [weak self] count, offline in
            guard let self else { return }
            self.hostView.paneCount = count
            self.hostView.isOffline = offline
            self.onOffline?(self.name, offline)
        }
        controller.onPaneCreated = { [weak self] pane in self?.wire(pane) }
    }

    static func workspaceSettings(_ s: Settings?) -> WorkspaceSettings {
        guard let s else { return WorkspaceSettings() }
        return WorkspaceSettings(minCols: s.minCols, maxCols: s.maxCols, unfocusedFade: s.unfocusedFade)
    }

    /// E-06: settings changed (the saved values).
    func apply(settings s: Settings) {
        controller.settings = Self.workspaceSettings(s)
    }

    /// The fade slider is moving (live preview, deviation 27).
    func previewFade(_ fade: Int) {
        controller.settings.unfocusedFade = fade
    }

    /// Put the view in the container and start listing sessions.
    func start() {
        hostView.setContent(controller.view)
        controller.attachInBackground()
    }

    /// The connection is gone (or the app quits): save and close everything.
    func stop() {
        controller.detach()
        if hostView.content === controller.view { hostView.setContent(nil) }
    }

    /// Every terminal pane on screen, layout order.
    var terminalPanes: [TerminalPane] {
        controller.view.paneIds.compactMap { controller.pane(id: $0) as? TerminalPane }
    }

    /// The focused pane's terminal, if the focused pane is one.
    var focusedTerminal: TerminalPaneView? {
        (controller.focusedPane as? TerminalPane)?.surface
    }

    private func wire(_ pane: WorkspacePane) {
        guard let t = pane as? TerminalPane else { return }
        let name = self.name
        let window = self.window
        t.onStatus = { text in StatusHUD.show(text, from: name, in: window()) }
        t.onChooseLink = { url, kind in
            // The relay (xdg-open on the host) lets the URL decide its buttons;
            // mailto/other are what the terminal classified.
            let urlKind: URLKind?
            switch kind {
            case .relay: urlKind = nil
            case .http: urlKind = .web
            case .mailto: urlKind = .mailto
            case .other: urlKind = .other
            }
            LinkChooser.present(url: url, kind: urlKind, in: window())
        }
    }
}
