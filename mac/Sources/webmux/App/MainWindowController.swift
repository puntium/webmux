// The main window (W-01, W-06, W-07; docs/macos-client.md "Idiomatic macOS"):
// a unified title bar with an `NSToolbar` — the host popup (one entry per live
// connection with its status dot, "webmux" when none), New Terminal, New File
// Browser, Connection Log, Settings — over a content area that shows one
// connection's `HostContentView` at a time, or a small landing view when no
// host is in front. The window title is the connection's name, the subtitle
// its state.
//
// The pane commands (`PaneCommandTarget`: menu items and toolbar buttons with
// a nil target) land here through the responder chain and go to the front
// host's workspace; they validate as enabled only while one is in front.
import AppKit
import os
import GhosttyKit
import WebmuxLayout
import WebmuxPanels
import WebmuxTerminal
import WebmuxWorkspace

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSUserInterfaceValidations, NSToolbarItemValidation {
    private static let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "window")

    let ghostty: Ghostty.App
    /// What the content area shows: a host view or nil for the landing view.
    private(set) var frontView: HostContentView?
    private let baseTitle: String
    private let container = NSView()
    private let landing = NSView()
    private let landingLabel = NSTextField(labelWithString: "webmux")
    private let landingHint = NSTextField(labelWithString: "")
    private let hostPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24), pullsDown: false)
    private var hosts: [(name: String, kind: HostStatusKind, active: Bool)] = []
    /// The popup's choice (user navigation).
    var onHostSelected: ((String) -> Void)?

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.baseTitle = AppEnvironment.isDevMode ? "webmux (dev)" : "webmux"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false)
        window.title = baseTitle
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 240)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.setFrameAutosaveName("webmux.main")
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "webmux.main.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        container.wantsLayer = true
        window.contentView = container
        buildLanding()
        setHosts([])
        showLanding()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Landing / hosts

    private func buildLanding() {
        landingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        landingLabel.textColor = .secondaryLabelColor
        landingLabel.alignment = .center
        landingHint.font = .systemFont(ofSize: 13)
        landingHint.textColor = .tertiaryLabelColor
        landingHint.alignment = .center
        landingHint.stringValue = "No host in front."
        let button = NSButton(title: "Connections…", target: nil, action: #selector(AppDelegate.showConnections(_:)))
        button.keyEquivalent = ""
        let stack = NSStackView(views: [landingLabel, landingHint, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        landing.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: landing.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: landing.centerYAnchor),
        ])
    }

    /// The content area shows the landing view (nothing in front).
    func showLanding() {
        frontView?.workspace?.controller.setFront(false)
        frontView?.removeFromSuperview()
        frontView = nil
        if landing.superview == nil {
            landing.frame = container.bounds
            landing.autoresizingMask = [.width, .height]
            container.addSubview(landing)
        }
        setTitle(baseTitle, subtitle: "")
        selectPopupEntry(nil)
    }

    /// Bring a host's content to the front (W-02: exactly one content view).
    func showHost(_ view: HostContentView) {
        guard frontView !== view else { return }
        frontView?.workspace?.controller.setFront(false)
        frontView?.removeFromSuperview()
        landing.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        frontView = view
        // W-45: the workspace in front renders, the others pause.
        view.workspace?.controller.setFront(true)
        // W-05: keyboard focus belongs to the content (the focused pane).
        if let ws = view.workspace {
            ws.controller.focusKeyboard()
        } else {
            window?.makeFirstResponder(view.content ?? view)
        }
        selectPopupEntry(view.name)
    }

    /// The workspace of the host in front, if it has one.
    var frontWorkspace: WorkspaceController? { frontView?.workspace?.controller }

    var isLandingShown: Bool { frontView == nil && landing.superview != nil }

    func setTitle(_ title: String, subtitle: String) {
        window?.title = title
        window?.subtitle = subtitle
    }

    /// Rebuild the toolbar popup: one entry per live connection, with its
    /// status dot; "webmux" when there is none.
    func setHosts(_ list: [(name: String, kind: HostStatusKind, active: Bool)]) {
        hosts = list
        hostPopup.removeAllItems()
        if list.isEmpty {
            hostPopup.addItem(withTitle: baseTitle)
            hostPopup.lastItem?.image = HostStatusKind.none.dotImage()
            hostPopup.isEnabled = false
            return
        }
        hostPopup.isEnabled = true
        for (i, h) in list.enumerated() {
            let item = NSMenuItem(title: h.name, action: nil, keyEquivalent: "")
            item.image = h.kind.dotImage()
            item.toolTip = "\(h.name) — \(h.kind.stateText())" + (i < 9 ? " (⌘\(i + 1))" : "")
            item.representedObject = h.name
            hostPopup.menu?.addItem(item)
        }
        selectPopupEntry(list.first { $0.active }?.name)
    }

    private func selectPopupEntry(_ name: String?) {
        guard let name, let i = hostPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == name }) else {
            if !hosts.isEmpty {
                // No host in front: show the app name as the popup's title
                // without selecting a host.
                hostPopup.selectItem(at: -1)
                hostPopup.setTitle(baseTitle)
            }
            return
        }
        hostPopup.selectItem(at: i)
    }

    @objc private func hostPopupChanged(_ sender: Any?) {
        guard let name = hostPopup.selectedItem?.representedObject as? String else { return }
        onHostSelected?(name)
    }

    /// The popup's entries (control socket).
    var hostEntries: [(name: String, kind: HostStatusKind, active: Bool)] { hosts }

    /// A line of text in the content area (dev mode's status before attach).
    func showStatus(_ text: String) {
        landingHint.stringValue = text
    }

    // MARK: Toolbar

    private static let hostItem = NSToolbarItem.Identifier("webmux.host")
    private static let newTerminalItem = NSToolbarItem.Identifier("webmux.newTerminal")
    private static let newFilesItem = NSToolbarItem.Identifier("webmux.newFiles")
    private static let logItem = NSToolbarItem.Identifier("webmux.log")
    private static let settingsItem = NSToolbarItem.Identifier("webmux.settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.hostItem, .flexibleSpace, Self.newTerminalItem, Self.newFilesItem, Self.logItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.hostItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Host"
            item.paletteLabel = "Host"
            hostPopup.bezelStyle = .texturedRounded
            hostPopup.target = self
            hostPopup.action = #selector(hostPopupChanged(_:))
            hostPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            item.view = hostPopup
            item.visibilityPriority = .high
            return item
        case Self.newTerminalItem:
            return button(id, "New Terminal", "New terminal in a new column (⌘↩)", "plus.rectangle.on.rectangle",
                          #selector(PaneCommandTarget.newTerminal(_:)))
        case Self.newFilesItem:
            return button(id, "New File Browser", "New file browser in a new column (⌘⇧↩)", "folder.badge.plus",
                          #selector(PaneCommandTarget.newFileBrowser(_:)))
        case Self.logItem:
            return button(id, "Connection Log", "Connection log (⌃⌘L)", "list.bullet.rectangle",
                          #selector(AppDelegate.showLog(_:)))
        case Self.settingsItem:
            return button(id, "Settings", "Settings (⌘,)", "gearshape", #selector(AppDelegate.showSettings(_:)))
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ tip: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = nil
        item.action = action
        return item
    }

    // MARK: Pane commands (PaneCommandTarget, through the responder chain)

    /// Chromium's zoom presets (K-31): the Electron client zooms the page by
    /// these steps; here the step scales the cell width the width rule sees
    /// (deviation 24).
    static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    private func run(_ command: LayoutCommand) {
        guard let ws = frontWorkspace else { return NSSound.beep() }
        ws.run(command)
    }

    @objc func newTerminal(_ sender: Any?) { run(.newTerminal) }
    @objc func newTerminalBelow(_ sender: Any?) { run(.newTerminalBelow) }
    @objc func newFileBrowser(_ sender: Any?) { run(.newFiles) }
    @objc func closePane(_ sender: Any?) { run(.closePane) }
    @objc func toggleFullWindow(_ sender: Any?) { run(.toggleFull) }
    @objc func focusLeft(_ sender: Any?) { run(.focusLeft) }
    @objc func focusRight(_ sender: Any?) { run(.focusRight) }
    @objc func focusUp(_ sender: Any?) { run(.focusUp) }
    @objc func focusDown(_ sender: Any?) { run(.focusDown) }
    @objc func consumeExpelLeft(_ sender: Any?) { run(.consumeExpelLeft) }
    @objc func consumeExpelRight(_ sender: Any?) { run(.consumeExpelRight) }
    @objc func moveColumnLeft(_ sender: Any?) { run(.moveColumnLeft) }
    @objc func moveColumnRight(_ sender: Any?) { run(.moveColumnRight) }
    @objc func movePaneUp(_ sender: Any?) { run(.movePaneUp) }
    @objc func movePaneDown(_ sender: Any?) { run(.movePaneDown) }

    /// W-43 / S-13: reconcile the front workspace with its host.
    @objc func reloadWorkspace(_ sender: Any?) {
        guard let ws = frontWorkspace else { return NSSound.beep() }
        Task { await ws.reload() }
    }

    @objc func actualSize(_ sender: Any?) { frontWorkspace?.view.zoom = 1 }
    @objc func zoomIn(_ sender: Any?) { stepZoom(+1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }

    private func stepZoom(_ dir: Int) {
        guard let view = frontWorkspace?.view else { return }
        let levels = Self.zoomLevels
        // The nearest preset, then one step.
        let i = levels.indices.min { abs(levels[$0] - view.zoom) < abs(levels[$1] - view.zoom) } ?? 5
        let j = max(0, min(levels.count - 1, i + dir))
        view.zoom = levels[j]
    }

    /// Pane items are enabled while a workspace is in front and has listed
    /// its sessions (`run` ignores commands before that); View › Reload and
    /// the zoom items as soon as there is a workspace.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        switch action {
        case #selector(reloadWorkspace(_:)), #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return frontWorkspace != nil
        default:
            return frontWorkspace?.isLoaded == true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validateUserInterfaceItem(item)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // W-06: the app quits with its main window (AppDelegate); the
        // workspaces are torn down there.
    }
}

extension MainWindowController: PaneCommandTarget {}
