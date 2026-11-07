// The main window (W-01, W-06, W-07; docs/macos-client.md "Idiomatic macOS"):
// a unified title bar with an `NSToolbar` — the host switcher (a segmented
// control, one segment per live connection with its status dot, so switching
// is one click), a "+" that opens the Connections window to start another
// connection, New Terminal, New File Browser, Settings — over a content area
// that shows one
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
    /// The host switcher: a pill per host with its status colour and minimap.
    private let hostPills = HostPillsView()
    private var hosts: [HostEntry] = []
    /// A pill clicked (user navigation).
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
        // The host switcher and its "+" sit centred, apart from the pane
        // actions on the right (the title takes the flexible space).
        toolbar.centeredItemIdentifiers = [Self.hostItem, Self.connectItem]
        window.toolbar = toolbar

        container.wantsLayer = true
        window.contentView = container
        buildLanding()
        hostPills.onSelectHost = { [weak self] name in self?.onHostSelected?(name) }
        hostPills.onSelectPane = { [weak self] name, id in
            guard let self else { return }
            if self.frontView?.name != name { self.onHostSelected?(name) }
            guard self.frontView?.name == name else { return }
            self.frontWorkspace?.setFocus(id, keyboard: true)
        }
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
        markActive(nil)
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
        markActive(view.name)
    }

    /// The workspace of the host in front, if it has one.
    var frontWorkspace: WorkspaceController? { frontView?.workspace?.controller }

    var isLandingShown: Bool { frontView == nil && landing.superview != nil }

    func setTitle(_ title: String, subtitle: String) {
        window?.title = title
        window?.subtitle = subtitle
    }

    /// Rebuild the host switcher: one pill per live connection; out of the
    /// toolbar when there is none.
    func setHosts(_ list: [HostEntry]) {
        hosts = list
        hostPills.set(list)
        setSwitcherShown(!list.isEmpty)
    }

    /// The front host changed here before the hub's next refresh says so.
    private func markActive(_ name: String?) {
        guard hosts.contains(where: { $0.active != ($0.name == name) }) else { return }
        setHosts(hosts.map { var e = $0; e.active = e.name == name; return e })
    }

    /// The switcher is in the toolbar only while there are connections (an
    /// empty view measures as zero, which the toolbar rejects).
    private func setSwitcherShown(_ shown: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let i = toolbar.items.firstIndex { $0.itemIdentifier == Self.hostItem }
        if shown, i == nil {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == Self.connectItem } ?? 0
            toolbar.insertItem(withItemIdentifier: Self.hostItem, at: at)
        } else if !shown, let i {
            toolbar.removeItem(at: i)
        }
    }

    /// A host's pill and minimap as data (control socket): the pill's frame,
    /// the map's cells and viewport outline in its own points; nil for an
    /// unknown host.
    func minimapInfo(_ name: String) -> [String: Any]? {
        guard let pill = hostPills.pill(named: name) else { return nil }
        let m = pill.minimap.map
        func r(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 } }
        return [
            "pill": r(pill.frame),
            "mapShown": !pill.minimap.isHidden,
            "size": [Double(m.size.width), Double(m.size.height)],
            "cells": m.cells.map { ["id": $0.id, "rect": r($0.rect), "focused": $0.focused] as [String: Any] },
            "viewport": m.viewport.map(r) as Any? ?? NSNull(),
        ]
    }

    /// The switcher's entries (control socket).
    var hostEntries: [HostEntry] { hosts }

    /// A line of text in the content area (dev mode's status before attach).
    func showStatus(_ text: String) {
        landingHint.stringValue = text
    }

    // MARK: Toolbar

    private static let hostItem = NSToolbarItem.Identifier("webmux.host")
    private static let newTerminalItem = NSToolbarItem.Identifier("webmux.newTerminal")
    private static let newFilesItem = NSToolbarItem.Identifier("webmux.newFiles")
    private static let connectItem = NSToolbarItem.Identifier("webmux.connect")
    private static let settingsItem = NSToolbarItem.Identifier("webmux.settings")

    /// The host switcher is not a default item: `setHosts` inserts it before
    /// the "+" while there are connections.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.connectItem, .flexibleSpace, Self.newTerminalItem, Self.newFilesItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.hostItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.hostItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Hosts"
            item.paletteLabel = "Hosts"
            item.view = hostPills
            item.autovalidates = false
            item.visibilityPriority = .high
            return item
        case Self.connectItem:
            let item = button(id, "Connect", "New connection… (Connections window)", "plus",
                              #selector(AppDelegate.showConnections(_:)))
            item.visibilityPriority = .high
            return item
        case Self.newTerminalItem:
            return button(id, "New Terminal", "New terminal in a new column (⌘↩)", "plus.rectangle.on.rectangle",
                          #selector(PaneCommandTarget.newTerminal(_:)))
        case Self.newFilesItem:
            return button(id, "New File Browser", "New file browser in a new column (⌘⇧↩)", "folder.badge.plus",
                          #selector(PaneCommandTarget.newFileBrowser(_:)))
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
