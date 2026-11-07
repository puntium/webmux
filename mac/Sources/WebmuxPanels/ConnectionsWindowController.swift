// The Connections window (⌘⇧O; PARITY W-20…W-32 as functions, X-03…X-10,
// X-18, X-22, X-23, X-30; deviations 23, 67; reference: chrome/page.zig):
// a sidebar of profiles with status dots and a form on the right; Connect /
// Disconnect / Cancel / Show / Reconnect; Restart Sessions and Delete behind
// `NSAlert` sheets; below the form the live status detail (deploy step and
// push progress, the retry countdown ticking every second, the failure
// message with ssh's stderr tail, the Local Network hint) and, at the top,
// the config-problem banner.
//
// Main thread only. The app feeds `apply(statuses:offline:)` from the
// engine's events (hopped to the main queue) and `restartDone(_:)`.
import AppKit
import os
import WebmuxConnection

@MainActor
public final class ConnectionsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let logger = Logger(subsystem: panelsLogSubsystem, category: "panels")
    public static let windowTitle = "Connections"
    public static let noticeMs = 8000
    public static let emptyText = "No profiles yet — create one to connect."
    public static let hint = "A host needs nothing but ssh: connecting pushes the webmux server (one small static binary) to ~/.webmux/dist on the host and starts it — updates are pushed the same way, and sessions survive them. Connect to several hosts at once; each is a workspace in the main window (⌘1…9 or ⌘⇧[ / ⌘⇧] switch, ⌘⇧O opens this window). Key auth needs no prompt (use ssh-agent for passphrases); or save a password per profile — it is kept in your Keychain and fed to ssh through an askpass helper. ⌘⇧R reconnects the current host."

    private let engine: ConnectionEngine
    private let passwords: PasswordStore?

    /// The user asked to connect this profile (X-18: reveal its workspace when
    /// the server first answers).
    public var onConnectRequested: ((String) -> Void)?
    /// `Show`: bring this connected host to the front.
    public var onShowHost: ((String) -> Void)?
    /// The Log button.
    public var onOpenLog: (() -> Void)?

    private var profiles: [Profile] = []
    private var statuses: [String: ConnectionStatus] = [:]
    private var offline: Set<String> = []
    /// The name of the profile being edited (nil: a new profile).
    private var editing: String?
    private var formTag = 0
    private var countdown: Timer?
    private var noticeTimer: DispatchWorkItem?
    private var confirmOpen = false

    // Views
    private let table = NSTableView()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let bannerBox = NSBox()
    private let emptyLabel = NSTextField(labelWithString: ConnectionsWindowController.emptyText)
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let identityField = NSTextField()
    private let instanceField = NSTextField()
    private let extraField = NSTextField()
    private let downloadField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let clearPasswordBox = NSButton(checkboxWithTitle: "Clear saved password", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let formTitle = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let showButton = NSButton(title: "Show", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let restartButton = NSButton(title: "Restart Sessions…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let detailBox = NSStackView()
    private let detailDot = NSImageView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailMessage = NSTextField(wrappingLabelWithString: "")
    private let detailProgress = NSProgressIndicator()
    private let detailExplanation = NSTextField(wrappingLabelWithString: "")
    private let lanButton = NSButton(title: "Open Privacy & Security Settings", target: nil, action: nil)
    private let diagnostics = NSTextView()
    private let diagnosticsScroll = NSScrollView()

    public init(engine: ConnectionEngine, passwords: PasswordStore?) {
        self.engine = engine
        self.passwords = passwords
        let window = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Self.windowTitle
        window.minSize = NSSize(width: 640, height: 420)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("webmux.connections")
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        reloadProfiles()
        applyStatuses()
        updateBanner()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// Open, or bring to the front. The last-connected profile is selected on
    /// first open; a half-typed form is kept across close/open (deviation 67).
    public func show() {
        guard let window else { return }
        if !window.isVisible, table.selectedRow < 0, editing == nil, !formDirty {
            let last = engine.lastProfile
            if let i = profiles.firstIndex(where: { $0.name == last }) ?? (profiles.isEmpty ? nil : 0) {
                table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        if profiles.isEmpty { window.makeFirstResponder(nameField) }
    }

    /// The store changed outside the window (e.g. a profile deleted elsewhere).
    public func profilesChanged() {
        reloadProfiles()
        applyStatuses()
    }

    /// The engine's connection list (`snapshot()`) and which connected hosts
    /// the workspace reports offline (degraded).
    public func apply(statuses: [ConnectionStatus], offline: Set<String> = []) {
        var map: [String: ConnectionStatus] = [:]
        for s in statuses { map[s.name] = s }
        self.statuses = map
        self.offline = offline
        applyStatuses()
    }

    /// W-25: the Restart Sessions outcome.
    public func restartDone(_ r: RestartResult) {
        notice("\(r.name): \(r.msg)")
    }

    /// A transient line under the form (W-25), cleared after 8 s.
    public func notice(_ text: String) {
        noticeLabel.stringValue = text
        noticeLabel.isHidden = false
        noticeTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.noticeLabel.stringValue = ""
            self?.noticeLabel.isHidden = true
        }
        noticeTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.noticeMs), execute: item)
    }

    /// The selected profile's name (control socket / tests).
    public var selectedProfile: String? {
        let r = table.selectedRow
        return r >= 0 && r < profiles.count ? profiles[r].name : nil
    }

    public var currentError: String { errorLabel.stringValue }
    public var currentNotice: String { noticeLabel.stringValue }
    public var currentDiagnostics: String { detailBox.isHidden || diagnosticsScroll.isHidden ? "" : diagnostics.string }
    public var currentDetail: String { [detailMessage.stringValue, detailExplanation.stringValue].filter { !$0.isEmpty }.joined(separator: " | ") }

    // MARK: Scripted control (the app's control socket; the same paths as the controls)

    /// Select a profile row by name (nil: none).
    public func select(name: String?) {
        guard let name, let i = profiles.firstIndex(where: { $0.name == name }) else {
            table.deselectAll(nil)
            loadSelected()
            updateButtons()
            updateDetail()
            return
        }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
    }

    /// Type into the form's fields (keys: name, host, sshPort, identityFile,
    /// instance, extraOptions, password, clearPassword).
    public func setForm(_ fields: [String: String]) {
        for (k, v) in fields {
            switch k {
            case "name": nameField.stringValue = v
            case "host": hostField.stringValue = v
            case "sshPort": portField.stringValue = v
            case "identityFile": identityField.stringValue = v
            case "instance": instanceField.stringValue = v
            case "extraOptions": extraField.stringValue = v
            case "password": passwordField.stringValue = v
            case "clearPassword": clearPasswordBox.state = (v == "true" || v == "1") ? .on : .off
            default: break
            }
        }
    }

    /// Press a button: save, connect (Connect / Disconnect / Cancel by state),
    /// show, reconnect, new. Returns false for an unknown button.
    @discardableResult
    public func press(_ button: String) -> Bool {
        switch button {
        case "save": save(nil)
        case "connect": connect(nil)
        case "show": showHost(nil)
        case "reconnect": reconnect(nil)
        case "new": newProfile(nil)
        default: return false
        }
        return true
    }

    /// The form as it stands (passwords excluded).
    public var formFields: [String: String] {
        let v = currentValues()
        return ["name": v.name, "host": v.host, "sshPort": v.sshPort, "identityFile": v.identityFile,
                "instance": v.instance, "extraOptions": v.extraOptions, "editing": editing ?? "",
                "connectTitle": connectButton.title, "saveTitle": saveButton.title]
    }

    /// Start a new profile (the + button, "New Profile").
    @objc public func newProfile(_ sender: Any?) {
        table.deselectAll(nil)
        editing = nil
        load(values: ProfileFormValues(), hasPassword: false)
        window?.makeFirstResponder(nameField)
        updateButtons()
        updateDetail()
    }

    // MARK: Content

    private func buildContent() -> NSView {
        // Sidebar
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 40
        table.style = .sourceList
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(connectOrShow(_:))
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 3

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Profile") ?? NSImage(), target: self, action: #selector(newProfile(_:)))
        add.bezelStyle = .smallSquare
        add.isBordered = false
        add.toolTip = "New Profile"
        let logButton = NSButton(title: "Log", target: self, action: #selector(openLog(_:)))
        logButton.bezelStyle = .inline
        logButton.controlSize = .small
        logButton.toolTip = "Connection log (⌃⌘L)"
        let sidebarBar = NSStackView(views: [add, NSView(), logButton])
        sidebarBar.orientation = .horizontal
        sidebarBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        for v in [listScroll, emptyLabel, sidebarBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: sidebarBar.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listScroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: listScroll.topAnchor, constant: 24),
            emptyLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarBar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarBar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarBar.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])

        // Form
        formTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        for f in [nameField, hostField, portField, identityField, instanceField, extraField, passwordField, downloadField] {
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.delegate = self
        }
        nameField.placeholderString = "devbox"
        hostField.placeholderString = "me@devbox.example.com"
        portField.placeholderString = "22"
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        identityField.placeholderString = "~/.ssh/id_ed25519"
        instanceField.placeholderString = "default"
        extraField.placeholderString = "-o ProxyJump=bastion"
        downloadField.placeholderString = "set by the file browser's downloads"
        downloadField.isEditable = false
        downloadField.textColor = .secondaryLabelColor
        clearPasswordBox.isHidden = true
        passwordField.placeholderString = ProfileFormValues.passwordPlaceholder(hasStored: false)
        let identityRow = NSStackView(views: [identityField, browseButton()])
        identityRow.orientation = .horizontal
        identityRow.spacing = 4
        let portRow = NSStackView(views: [portField, NSView()])
        portRow.orientation = .horizontal

        let grid = NSGridView(views: [
            [label("Profile name:"), nameField],
            [label("Host:"), hostField],
            [NSGridCell.emptyContentView, description("anything ssh accepts, ~/.ssh/config aliases included")],
            [label("SSH port:"), portRow],
            [label("Identity file:"), identityRow],
            [label(ProfileFormValues.passwordLabel + ":"), passwordField],
            [NSGridCell.emptyContentView, clearPasswordBox],
            [label("Instance:"), instanceField],
            [NSGridCell.emptyContentView, description("blank = default — separate instances have separate sessions")],
            [label("Extra ssh options:"), extraField],
            [label("Download folder:"), downloadField],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.row(at: 2).topPadding = -4
        grid.row(at: 8).topPadding = -4

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.isHidden = true

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        showButton.target = self
        showButton.action = #selector(showHost(_:))
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect(_:))
        restartButton.target = self
        restartButton.action = #selector(restartSessions(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteProfile(_:))
        deleteButton.hasDestructiveAction = true
        let buttons = NSStackView(views: [restartButton, deleteButton, NSView(), reconnectButton, showButton, connectButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        // Status detail
        detailDot.imageScaling = .scaleNone
        detailDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailHeader = NSStackView(views: [detailDot, detailTitle])
        detailHeader.orientation = .horizontal
        detailHeader.spacing = 6
        detailMessage.textColor = .labelColor
        detailProgress.isIndeterminate = false
        detailProgress.minValue = 0
        detailProgress.maxValue = 1
        detailProgress.controlSize = .small
        detailExplanation.textColor = .secondaryLabelColor
        detailExplanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lanButton.target = self
        lanButton.action = #selector(openPrivacySettings(_:))
        lanButton.controlSize = .small
        lanButton.bezelStyle = .rounded
        diagnostics.isEditable = false
        diagnostics.isSelectable = true
        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textColor = .secondaryLabelColor
        diagnostics.backgroundColor = .textBackgroundColor
        diagnostics.textContainerInset = NSSize(width: 4, height: 4)
        diagnostics.isVerticallyResizable = true
        diagnostics.isHorizontallyResizable = false
        diagnostics.autoresizingMask = [.width]
        diagnostics.textContainer?.widthTracksTextView = true
        diagnosticsScroll.documentView = diagnostics
        diagnosticsScroll.hasVerticalScroller = true
        diagnosticsScroll.borderType = .bezelBorder
        diagnosticsScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        detailBox.orientation = .vertical
        detailBox.alignment = .leading
        detailBox.spacing = 6
        for v in [detailHeader, detailMessage, detailProgress, detailExplanation, lanButton, diagnosticsScroll] { detailBox.addArrangedSubview(v) }
        detailBox.isHidden = true
        detailProgress.widthAnchor.constraint(equalTo: detailBox.widthAnchor).isActive = true
        diagnosticsScroll.widthAnchor.constraint(equalTo: detailBox.widthAnchor).isActive = true
        detailMessage.widthAnchor.constraint(equalTo: detailBox.widthAnchor).isActive = true
        detailExplanation.widthAnchor.constraint(equalTo: detailBox.widthAnchor).isActive = true

        let hintLabel = NSTextField(wrappingLabelWithString: Self.hint)
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor

        // Banner (configProblem)
        banner.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        banner.textColor = .labelColor
        bannerBox.boxType = .custom
        bannerBox.fillColor = NSColor.systemYellow.withAlphaComponent(0.18)
        bannerBox.borderColor = NSColor.systemYellow.withAlphaComponent(0.5)
        bannerBox.cornerRadius = 6
        bannerBox.contentViewMargins = NSSize(width: 10, height: 8)
        bannerBox.contentView = banner
        bannerBox.isHidden = true

        let right = NSStackView(views: [bannerBox, formTitle, grid, errorLabel, noticeLabel, buttons, detailBox, NSView(), hintLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for v in [bannerBox, grid, errorLabel, buttons, detailBox, hintLabel, noticeLabel] {
            v.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -40).isActive = true
        }
        let rightScroll = NSScrollView()
        rightScroll.documentView = right
        rightScroll.hasVerticalScroller = true
        rightScroll.autohidesScrollers = true
        rightScroll.drawsBackground = false
        right.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            right.leadingAnchor.constraint(equalTo: rightScroll.contentView.leadingAnchor),
            right.trailingAnchor.constraint(equalTo: rightScroll.contentView.trailingAnchor),
            right.topAnchor.constraint(equalTo: rightScroll.contentView.topAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(rightScroll)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        rightScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        DispatchQueue.main.async { split.setPosition(230, ofDividerAt: 0) }
        return split
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private func description(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func browseButton() -> NSButton {
        let b = NSButton(title: "Choose…", target: self, action: #selector(chooseIdentity(_:)))
        b.controlSize = .small
        b.bezelStyle = .rounded
        return b
    }

    // MARK: Data

    private func reloadProfiles() {
        let selected = selectedProfile
        profiles = engine.profiles
        table.reloadData()
        emptyLabel.isHidden = !profiles.isEmpty
        if let s = selected, let i = profiles.firstIndex(where: { $0.name == s }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        updateButtons()
    }

    private func updateBanner() {
        if let p = engine.configProblem {
            banner.stringValue = p
            bannerBox.isHidden = false
        } else {
            bannerBox.isHidden = true
        }
    }

    private func kind(of name: String) -> HostStatusKind {
        HostStatusKind(status: statuses[name], offline: offline.contains(name))
    }

    private func applyStatuses() {
        // Rows are refreshed in place (W-29: the form is never touched).
        for (i, p) in profiles.enumerated() {
            guard let row = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? ProfileCell else { continue }
            row.configure(profile: p, kind: kind(of: p.name), live: liveNote(p))
        }
        updateButtons()
        updateDetail()
        updateCountdown()
    }

    /// "on <host>; Reconnect to use the edit" when the live connection is on
    /// different fields than the stored profile (X-06).
    private func liveNote(_ p: Profile) -> String? {
        guard let s = statuses[p.name] else { return nil }
        if s.host != p.host || s.instance != p.instance || s.sshPort != p.sshPort {
            return "on \(s.host)\(s.instance.isEmpty ? "" : " → \(s.instance)"); Reconnect to use the edit"
        }
        return nil
    }

    private func updateCountdown() {
        let anyRetry = statuses.values.contains { $0.state == .retry }
        if anyRetry, countdown == nil {
            countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateDetail()
                    for (i, p) in self.profiles.enumerated() where self.statuses[p.name]?.state == .retry {
                        (self.table.view(atColumn: 0, row: i, makeIfNecessary: false) as? ProfileCell)?
                            .configure(profile: p, kind: self.kind(of: p.name), live: self.liveNote(p))
                    }
                }
            }
        } else if !anyRetry {
            countdown?.invalidate()
            countdown = nil
        }
    }

    // MARK: Form

    private var formDirty: Bool {
        let v = currentValues()
        if let e = editing, let p = profiles.first(where: { $0.name == e }) {
            var stored = ProfileFormValues(profile: p)
            stored.password = v.password
            stored.clearPassword = v.clearPassword
            return stored != v
        }
        return v != ProfileFormValues()
    }

    private func currentValues() -> ProfileFormValues {
        var v = ProfileFormValues()
        v.name = nameField.stringValue
        v.host = hostField.stringValue
        v.sshPort = portField.stringValue
        v.identityFile = identityField.stringValue
        v.instance = instanceField.stringValue
        v.extraOptions = extraField.stringValue
        v.password = passwordField.stringValue
        v.clearPassword = clearPasswordBox.state == .on
        return v
    }

    private func load(values v: ProfileFormValues, hasPassword: Bool, downloadDir: String = "") {
        nameField.stringValue = v.name
        hostField.stringValue = v.host
        portField.stringValue = v.sshPort
        identityField.stringValue = v.identityFile
        instanceField.stringValue = v.instance
        extraField.stringValue = v.extraOptions
        downloadField.stringValue = downloadDir
        passwordField.stringValue = ""
        passwordField.placeholderString = ProfileFormValues.passwordPlaceholder(hasStored: hasPassword)
        clearPasswordBox.state = .off
        clearPasswordBox.isHidden = !hasPassword
        errorLabel.stringValue = ""
        formTitle.stringValue = editing == nil ? "New Profile" : v.name
        formTag += 1
    }

    private func loadSelected() {
        guard let name = selectedProfile, let p = profiles.first(where: { $0.name == name }) else {
            if editing != nil {
                editing = nil
                load(values: ProfileFormValues(), hasPassword: false)
            }
            return
        }
        editing = name
        load(values: ProfileFormValues(profile: p), hasPassword: passwords?.has(profileID: p.id) ?? false, downloadDir: p.downloadDir)
    }

    private func setError(_ text: String?) {
        errorLabel.stringValue = text ?? ""
    }

    private func updateButtons() {
        let isNew = editing == nil
        let k = editing.map(kind(of:)) ?? .none
        saveButton.title = isNew ? "Save & Connect" : "Save"
        restartButton.isHidden = isNew
        deleteButton.isHidden = isNew
        // W-23: Disconnect + Show while up; Cancel while connecting/retrying; else Connect.
        switch k {
        case .connected, .degraded:
            connectButton.title = "Disconnect"
            showButton.isHidden = false
            reconnectButton.isHidden = false
        case .connecting, .retry:
            connectButton.title = "Cancel"
            showButton.isHidden = true
            reconnectButton.isHidden = true
        case .failed:
            connectButton.title = "Connect"
            showButton.isHidden = true
            reconnectButton.isHidden = false
        case .none:
            connectButton.title = "Connect"
            showButton.isHidden = true
            reconnectButton.isHidden = true
        }
        connectButton.isHidden = isNew
        connectButton.hasDestructiveAction = k.isUp
    }

    private func updateDetail() {
        guard let name = editing, let st = statuses[name] else {
            detailBox.isHidden = true
            return
        }
        var retrySeconds: Int?
        if st.state == .retry {
            retrySeconds = retryCountdownSeconds(remainingMs: st.retryRemainingMs(now: engine.nowMs()))
        }
        guard let d = StatusDetail(status: st, offline: offline.contains(name), retrySeconds: retrySeconds) else {
            detailBox.isHidden = true
            return
        }
        detailBox.isHidden = false
        detailDot.image = d.kind.dotImage(diameter: 10)
        detailTitle.stringValue = "\(d.name) — \(d.kind.cardLabel)"
        detailMessage.stringValue = d.message
        detailMessage.isHidden = d.message.isEmpty
        if let f = d.pushFraction {
            detailProgress.doubleValue = f
            detailProgress.isHidden = false
        } else {
            detailProgress.isHidden = true
        }
        detailExplanation.stringValue = d.explanation ?? ""
        detailExplanation.isHidden = d.explanation == nil
        lanButton.isHidden = !d.isLocalNetworkHint
        diagnostics.string = d.diagnostics
        diagnosticsScroll.isHidden = d.diagnostics.isEmpty
    }

    // MARK: Actions

    @objc private func save(_ sender: Any?) {
        let values = currentValues()
        let input: ProfileInput
        switch values.input() {
        case .failure(let e): return setError(e.description)
        case .success(let i): input = i
        }
        let original = editing
        if let err = engine.validateProfile(input, originalName: original) { return setError(err) }
        var saveInput = input
        let existing = original.flatMap { o in profiles.first { $0.name == o } }
        var newID: String?
        switch values.passwordAction {
        case .set(let pw):
            guard let store = passwords else {
                return setError("OS keychain encryption is unavailable — cannot store a password")
            }
            let id = existing?.id ?? engine.newProfileID()
            if existing == nil { newID = id }
            saveInput.id = id
            do {
                try store.set(profileID: id, label: "webmux: \(input.name)", password: pw)
            } catch let e as KeychainError {
                return setError(e.userMessage)
            } catch {
                return setError("\(error)")
            }
        case .keep, .clear:
            break
        }
        if let err = engine.saveProfile(saveInput, originalName: original) {
            if let id = newID { try? passwords?.delete(profileID: id) }
            return setError(err)
        }
        if values.passwordAction == .clear, let p = existing {
            try? passwords?.delete(profileID: p.id)
        }
        passwordField.stringValue = ""
        setError(nil)
        let wasNew = original == nil
        editing = input.name
        reloadProfiles()
        if let i = profiles.firstIndex(where: { $0.name == input.name }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        loadSelected()
        if wasNew { startConnect(input.name) }
    }

    private func startConnect(_ name: String) {
        if let err = engine.connect(name) {
            setError(err)
            return
        }
        onConnectRequested?(name)
    }

    /// Connect / Disconnect / Cancel by state (W-23, X-18, X-23).
    @objc private func connect(_ sender: Any?) {
        guard let name = editing else { return }
        switch kind(of: name) {
        case .connected, .degraded, .connecting, .retry:
            engine.disconnect(name)
        case .failed, .none:
            setError(nil)
            startConnect(name)
        }
    }

    /// Double-click a row: Show when up, else Connect.
    @objc private func connectOrShow(_ sender: Any?) {
        guard let name = selectedProfile else { return }
        if kind(of: name).isUp { onShowHost?(name) } else { startConnect(name) }
    }

    @objc private func showHost(_ sender: Any?) {
        guard let name = editing else { return }
        onShowHost?(name)
    }

    @objc private func reconnect(_ sender: Any?) {
        guard let name = editing else { return }
        if let err = engine.reconnect(name) { setError(err) } else { setError(nil) }
    }

    @objc private func restartSessions(_ sender: Any?) {
        guard let name = editing, let window, !confirmOpen else { return }
        let alert = NSAlert()
        alert.messageText = "Restart sessions on “\(name)”?"
        alert.informativeText = "This shuts down the remote session host: every shell on it is killed. Fresh sessions start on demand. The profile and the connection are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Sessions")
        alert.addButton(withTitle: "Cancel")
        confirmOpen = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmOpen = false
                guard response == .alertFirstButtonReturn else { return }
                if let err = self.engine.restartSessions(name) {
                    self.notice("\(name): \(err)")
                } else {
                    self.notice("\(name): restarting sessions…")
                }
            }
        }
    }

    @objc private func deleteProfile(_ sender: Any?) {
        guard let name = editing, let window, !confirmOpen else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the profile “\(name)”?"
        alert.informativeText = "This removes the profile and its saved password. A live connection to it is disconnected; remote sessions keep running."
        alert.alertStyle = .warning
        let del = alert.addButton(withTitle: "Delete Profile")
        del.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        confirmOpen = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmOpen = false
                guard response == .alertFirstButtonReturn else { return }
                let id = self.profiles.first { $0.name == name }?.id
                if let err = self.engine.deleteProfile(name) {
                    self.setError(err)
                    return
                }
                if let id { try? self.passwords?.delete(profileID: id) }
                self.editing = nil
                self.table.deselectAll(nil)
                self.reloadProfiles()
                self.load(values: ProfileFormValues(), hasPassword: false)
                self.updateButtons()
                self.updateDetail()
            }
        }
    }

    @objc private func chooseIdentity(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.identityField.stringValue = url.path
            }
        }
    }

    @objc private func openLog(_ sender: Any?) {
        onOpenLog?()
    }

    /// X-41: the Local Network pane of System Settings.
    @objc private func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }


    // MARK: NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < profiles.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ProfileCell) ?? ProfileCell(identifier: id)
        let p = profiles[row]
        cell.configure(profile: p, kind: kind(of: p.name), live: liveNote(p))
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        loadSelected()
        updateButtons()
        updateDetail()
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        if !errorLabel.stringValue.isEmpty { setError(nil) }
    }
}

/// One sidebar row: dot, name, state label, the monospace detail line.
@MainActor
private final class ProfileCell: NSTableCellView {
    private let dot = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        dot.imageScaling = .scaleNone
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let top = NSStackView(views: [dot, name, state])
        top.orientation = .horizontal
        top.spacing = 5
        top.alignment = .firstBaseline
        let col = NSStackView(views: [top, detail])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            col.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
        ])
        textField = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(profile p: Profile, kind: HostStatusKind, live: String?) {
        dot.image = kind.dotImage(diameter: 8)
        name.stringValue = p.name
        state.stringValue = kind.cardLabel
        detail.stringValue = profileDetailLine(p) + (live.map { "  (\($0))" } ?? "")
        toolTip = kind == .none ? p.name : "\(p.name) — \(kind.stateText())"
    }
}
