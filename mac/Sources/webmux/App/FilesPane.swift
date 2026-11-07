// The file-browser pane as the workspace sees it: `FilesPane` adapts the Files
// area's `FilesPaneView` to `WorkspacePane` (PARITY § 6; the adapter the view's
// header describes), and `FilesPaneFactory` is what the app registers once
// with `WorkspacePaneFactories.shared` for `.files`.
//
// Routing: `onStatus` → the HUD (from this connection), `onLog` → the engine's
// connection log under the host name, `onDownloadDirChosen` → the profile
// (F-55, through the engine), `onOpenURL` → the browser or the pasteboard,
// `onMailto` → the link chooser (M-04). The title is the directory path,
// fitted to the pane's width with `FilesPaths.fitPath` (F-15) in the pane
// frame's label font and refitted when the pane is resized.
import AppKit
import WebmuxConnection
import WebmuxFiles
import WebmuxHost
import WebmuxLayout
import WebmuxPanels
import WebmuxWorkspace

@MainActor
final class FilesPane: WorkspacePane {
    let id: String
    let kind: PaneKind = .files
    let files: FilesPaneView
    var view: NSView { files }
    weak var host: WorkspacePaneHost?
    private(set) var title: String?
    private var rawTitle = ""
    private var frameObserver: NSObjectProtocol?

    /// The frame's title label font (PaneFrame) and what the icon, paddings
    /// and ✕ take from the bar.
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let titleInsets: CGFloat = 64

    init(id: String, files: FilesPaneView) {
        self.id = id
        self.files = files
        files.onTitleChange = { [weak self] t in self?.titleChanged(t) }
        files.onRequestClose = { [weak self] in
            guard let self else { return }
            self.host?.paneRequestsClose(self)
        }
        files.onStateChange = { [weak self] _ in
            guard let self else { return }
            self.host?.paneStateDidChange(self)
        }
        files.onFocusEntered = { [weak self] in
            guard let self else { return }
            self.host?.paneDidTakeFocus(self)
        }
        files.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: files, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        }
        if !files.title.isEmpty { titleChanged(files.title) }
    }

    deinit {
        if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func titleChanged(_ full: String) {
        rawTitle = full
        refit()
    }

    /// F-15: `~/…/ui/app.js` as the width allows.
    private func refit() {
        let width = max(0, files.bounds.width - Self.titleInsets)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
        let fitted = rawTitle.isEmpty ? nil : FilesPaths.fitPath(rawTitle, maxWidth: width) { s in
            (s as NSString).size(withAttributes: attrs).width
        }
        guard fitted != title else { return }
        title = fitted
        host?.paneTitleDidChange(self)
    }

    // MARK: WorkspacePane

    func focus() { files.focus() }
    func setShown(_ shown: Bool) { files.setShown(shown) }
    var persistedState: String? { files.persistedState }
    func restore(state: String) { files.restore(state: state) }

    /// L-27: the Miller columns scroll before the strip pans.
    func consumeHorizontalScroll(deltaX: Double) -> Bool {
        let h = files.horizontalScroll
        guard h.total > h.visible + 0.5 else { return false }
        if deltaX > 0 { return h.offset > 0.5 }                               // towards the left edge
        if deltaX < 0 { return h.offset + h.visible < h.total - 0.5 }         // towards the right edge
        return false
    }

    func close() {
        files.close()
        files.removeFromSuperview()
    }
}

/// Builds `FilesPane`s for every workspace. One per app, holding the engine
/// (profiles: download folder) and where to show chrome.
@MainActor
final class FilesPaneFactory: WorkspacePaneFactory {
    private weak var engine: ConnectionEngine?
    /// The window the HUD and the chooser attach to (the main window).
    var window: () -> NSWindow?

    init(engine: ConnectionEngine?, window: @escaping () -> NSWindow?) {
        self.engine = engine
        self.window = window
    }

    func makePane(id: String, kind: PaneKind, state: String?, connection: WorkspaceConnection) throws -> WorkspacePane {
        let profile = engine?.profile(named: connection.name)
        let dir = profile.flatMap { $0.downloadDir.isEmpty ? nil : URL(fileURLWithPath: ($0.downloadDir as NSString).expandingTildeInPath) }
        let files = FilesPaneView(host: connection.api, profileDownloadDir: dir, state: state)
        let name = connection.name
        let window = self.window
        let engine = self.engine
        files.onStatus = { text in StatusHUD.show(text, from: name, in: window()) }
        files.onLog = { msg, data in
            _ = engine?.log.push(src: .page, conn: name, msg: msg, data: data.keys.sorted().map { LogField($0, data[$0] ?? "") })
        }
        files.onDownloadDirChosen = { url in
            // F-55: remembered per profile; dev mode has none.
            guard let engine, engine.profile(named: name) != nil else { return }
            if let err = engine.setDownloadDir(name, url.path) {
                StatusHUD.show("download folder not saved: \(err)", in: window())
            }
        }
        files.onOpenURL = { href, copy in
            if copy { LinkChooser.copy(href, in: window()) } else { LinkChooser.open(href, in: window()) }
        }
        files.onMailto = { href in LinkChooser.present(url: href, kind: .mailto, in: window()) }
        return FilesPane(id: id, files: files)
    }
}
