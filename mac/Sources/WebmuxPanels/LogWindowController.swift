// The Connection Log window (G-20…G-28; reference: panels/log_window.zig):
// an `NSTableView` over the engine's `ConnectionLog`, loaded from the ring
// and tailed live, with Host / Level / text filters, follow, Copy visible,
// Copy all, Reveal in Finder and Clear. One window; `show()` presents the
// existing one; it can be closed and reopened.
import AppKit
import os
import WebmuxConnection

@MainActor
public final class LogWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static let logger = Logger(subsystem: panelsLogSubsystem, category: "panels")
    public static let windowTitle = "webmux — connection log"
    public static let searchDelayMs = 80
    public static let flashMs = 2000

    private let log: ConnectionLog
    /// Every entry in the ring at load plus what arrived since (bounded by
    /// the ring's size, deviation 27).
    private var entries: [LogEntry] = []
    private var shown: [LogEntry] = []
    private var lastSeq: UInt64 = 0
    private var filter = LogFilter()
    private var hosts = LogHostList()
    private var subscription: UInt64?
    private var pullScheduled = false
    private var follow = true
    private var searchTimer: DispatchWorkItem?
    private var flashTimer: DispatchWorkItem?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hostPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let search = NSSearchField()
    private let followBox = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let flashLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    public init(log: ConnectionLog) {
        self.log = log
        let window = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Self.windowTitle
        window.minSize = NSSize(width: 520, height: 240)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("webmux.log")
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.initialFirstResponder = table
        pathLabel.stringValue = log.filePath ?? ""
        pathLabel.toolTip = log.filePath
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// G-20: open or bring to the front; the ring is (re)loaded on open.
    public func show() {
        guard let window else { return }
        if !window.isVisible {
            reload()
            start()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The visible rows' file-format lines (for the control socket).
    public var visibleLines: [String] { shown.map { $0.line } }
    public var entryCount: Int { entries.count }
    public var currentFilter: LogFilter { filter }

    // MARK: Content

    private func buildContent() -> NSView {
        let root = NSView()

        // Toolbar row
        hostPopup.target = self
        hostPopup.action = #selector(filterChanged(_:))
        levelPopup.target = self
        levelPopup.action = #selector(filterChanged(_:))
        for (level, label) in LogFilter.levelLabels {
            levelPopup.addItem(withTitle: label)
            levelPopup.lastItem?.representedObject = level.rawValue
        }
        levelPopup.selectItem(at: 1)
        rebuildHostPopup()
        search.placeholderString = "filter text…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        followBox.state = .on
        followBox.target = self
        followBox.action = #selector(followToggled(_:))
        followBox.toolTip = "Keep the newest entry in view"

        let copyVisible = NSButton(title: "Copy Visible", target: self, action: #selector(copyVisible(_:)))
        copyVisible.toolTip = "Copy the lines currently shown (⌘⇧C)"
        copyVisible.keyEquivalent = "C"
        copyVisible.keyEquivalentModifierMask = [.command, .shift]
        let copyAll = NSButton(title: "Copy All", target: self, action: #selector(copyAll(_:)))
        copyAll.toolTip = "Copy every entry in memory, ignoring the filters"
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealFile(_:)))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog(_:)))
        clear.toolTip = "Empty the in-memory log (the file is kept)"

        let bar = NSStackView(views: [labelled("Host", hostPopup), labelled("Level", levelPopup), search, followBox,
                                      NSView(), copyVisible, copyAll, reveal, clear])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 12)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        // Table
        let columns: [(String, String, CGFloat)] = [("time", "Time", 92), ("level", "Level", 50), ("host", "Host", 110), ("msg", "Message", 500)]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            if id == "msg" { c.resizingMask = .autoresizingMask } else { c.resizingMask = .userResizingMask }
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 18
        table.style = .plain
        table.menu = contextMenu()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        // Status bar
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        flashLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        flashLabel.textColor = .controlAccentColor
        pathLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        let status = NSStackView(views: [countLabel, flashLabel, NSView(), pathLabel])
        status.orientation = .horizontal
        status.spacing = 12
        status.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)

        for v in [bar, scroll, emptyLabel, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func labelled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        let s = NSStackView(views: [label, control])
        s.orientation = .horizontal
        s.spacing = 4
        return s
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy Visible", action: #selector(copyVisible(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy All", action: #selector(copyAll(_:)), keyEquivalent: "")
        return m
    }

    private func rebuildHostPopup() {
        let selected = filter.host
        hostPopup.removeAllItems()
        hostPopup.addItem(withTitle: "all")
        for h in hosts.hosts {
            hostPopup.addItem(withTitle: h)
            hostPopup.lastItem?.representedObject = h
        }
        if hosts.hasClient {
            hostPopup.addItem(withTitle: LogFilter.clientLabel)
            hostPopup.lastItem?.representedObject = LogFilter.clientKey
        }
        if let s = selected, let i = hostPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == s }) {
            hostPopup.selectItem(at: i)
        } else {
            hostPopup.selectItem(at: 0)
            filter.host = nil
        }
    }

    // MARK: Data flow

    private func reload() {
        entries = log.since(0)
        lastSeq = entries.last?.seq ?? 0
        hosts = LogHostList()
        for e in entries { hosts.note(e) }
        rebuildHostPopup()
        refilter()
    }

    private func start() {
        guard subscription == nil else { return }
        // G-21: the subscriber only wakes the main thread; it pulls everything
        // newer than what it has, so the initial load never duplicates.
        subscription = log.subscribe { [weak self] _ in
            DispatchQueue.main.async { self?.pull() }
        }
    }

    private func stop() {
        if let s = subscription { log.unsubscribe(s) }
        subscription = nil
    }

    private func pull() {
        let fresh = log.since(lastSeq)
        guard !fresh.isEmpty else { return }
        lastSeq = fresh.last?.seq ?? lastSeq
        entries.append(contentsOf: fresh)
        if entries.count > ConnectionLog.maxEntries {
            entries.removeFirst(entries.count - ConnectionLog.maxEntries)
        }
        var hostsChanged = false
        for e in fresh where hosts.note(e) { hostsChanged = true }
        if hostsChanged { rebuildHostPopup() }
        let before = shown.count
        let added = fresh.filter { filter.passes($0) }
        if entries.count == ConnectionLog.maxEntries {
            // The ring dropped old entries: rebuild the view from the kept set.
            refilter()
        } else if !added.isEmpty {
            shown.append(contentsOf: added)
            table.insertRows(at: IndexSet(integersIn: before..<shown.count), withAnimation: [])
            updateStatus()
            if follow { scrollToEnd() }
        } else {
            updateStatus()
        }
    }

    private func refilter() {
        shown = entries.filter { filter.passes($0) }
        table.reloadData()
        updateStatus()
        if follow { scrollToEnd() }
    }

    private func updateStatus() {
        countLabel.stringValue = LogFilter.countText(shown: shown.count, total: entries.count)
        emptyLabel.stringValue = LogFilter.emptyText(total: entries.count)
        emptyLabel.isHidden = !shown.isEmpty
    }

    private func scrollToEnd() {
        guard !shown.isEmpty else { return }
        table.scrollRowToVisible(shown.count - 1)
    }

    private func flash(_ text: String) {
        flashLabel.stringValue = text
        flashTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flashLabel.stringValue = "" }
        flashTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.flashMs), execute: item)
    }

    // MARK: Actions

    @objc private func filterChanged(_ sender: Any?) {
        filter.host = hostPopup.selectedItem?.representedObject as? String
        if let raw = levelPopup.selectedItem?.representedObject as? String { filter.level = LogLevel.parse(raw) }
        refilter()
    }

    public func controlTextDidChange(_ obj: Notification) {
        searchTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.filter.text = self.search.stringValue
            self.refilter()
        }
        searchTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.searchDelayMs), execute: item)
    }

    @objc private func followToggled(_ sender: Any?) {
        follow = followBox.state == .on
        if follow { scrollToEnd() }
    }

    /// G-24: scrolling away from the bottom unticks follow; back to it reticks.
    @objc private func scrolled(_ note: Notification) {
        let clip = scroll.contentView
        guard let doc = scroll.documentView else { return }
        let bottomGap = doc.bounds.maxY - clip.bounds.maxY
        let atBottom = bottomGap <= 4
        if atBottom != follow, doc.bounds.height > clip.bounds.height {
            follow = atBottom
            followBox.state = atBottom ? .on : .off
        }
    }

    @objc public func copyVisible(_ sender: Any?) {
        let lines = shown.map { $0.line }
        copy(lines)
        flash(LogFilter.copiedText(lines.count, visible: true))
    }

    @objc public func copyAll(_ sender: Any?) {
        let lines = entries.map { $0.line }
        copy(lines)
        flash(LogFilter.copiedText(lines.count, visible: false))
    }

    @objc private func copySelection(_ sender: Any?) {
        let rows = table.selectedRowIndexes
        let lines = rows.isEmpty ? shown.map { $0.line } : rows.compactMap { $0 < shown.count ? shown[$0].line : nil }
        copy(lines)
        flash(LogFilter.copiedText(lines.count, visible: rows.isEmpty))
    }

    /// Edit › Copy with rows selected copies them.
    @objc public func copy(_ sender: Any?) { copySelection(sender) }

    private func copy(_ lines: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(LogFilter.copyText(lines), forType: .string)
    }

    @objc public func revealFile(_ sender: Any?) {
        guard let path = log.filePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc public func clearLog(_ sender: Any?) {
        log.clear()
        entries.removeAll()
        shown.removeAll()
        lastSeq = 0
        table.reloadData()
        pull()
        updateStatus()
    }

    /// ⌘F focuses the text filter (G-28).
    @objc public func performFindPanelAction(_ sender: Any?) {
        window?.makeFirstResponder(search)
        search.selectText(nil)
    }

    // MARK: NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count, let column = tableColumn else { return nil }
        let e = shown[row]
        let id = column.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        guard let field = cell.textField else { return cell }
        let color = Self.color(for: e.level)
        switch id.rawValue {
        case "time":
            field.stringValue = LogFilter.localTime(e.t)
            field.textColor = .secondaryLabelColor
            field.toolTip = e.t
        case "level":
            field.stringValue = e.level.rawValue.uppercased()
            field.textColor = color
            field.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        case "host":
            field.stringValue = (e.conn ?? "") + (e.src == .page ? " page" : "")
            field.textColor = e.src == .page ? .systemGreen : .controlAccentColor
        default:
            field.stringValue = Self.messageText(e)
            field.textColor = color
            field.toolTip = e.line
        }
        return cell
    }

    /// The message with its `k=v` data: the file-format line without the
    /// timestamp, level, `[conn]` and `page:` prefix.
    static func messageText(_ e: LogEntry) -> String {
        var prefix = e.t.count + 1 + 5 + 1
        if let c = e.conn { prefix += c.count + 3 }
        if e.src == .page { prefix += 6 }
        let line = e.line
        guard prefix <= line.count else { return e.msg }
        return String(line.dropFirst(prefix))
    }

    /// G-23's level colours in system terms.
    static func color(for level: LogLevel) -> NSColor {
        switch level {
        case .debug: return .tertiaryLabelColor
        case .info: return .labelColor
        case .warn: return .systemOrange
        case .error: return .systemRed
        }
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        stop()
    }

    /// Escape closes the window (G-28).
}
