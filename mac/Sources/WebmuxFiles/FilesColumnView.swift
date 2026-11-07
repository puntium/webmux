// One listing column of the Miller view (F-04…F-13): an NSTableView of the
// directory's entries inside its own scroll view, with the on-path or
// cursor highlight, the `(empty)` / `(list truncated)` / error messages,
// the cursor row's Rename and Delete buttons, the inline rename field
// (F-50) and a file drop target (F-54).
import AppKit
import WebmuxHost

enum ColumnContent: Equatable {
    case loading
    case listing(DirectoryListing)
    case error(String)

    var entries: [DirectoryEntry] {
        if case .listing(let l) = self { return l.entries }
        return []
    }

    var errorText: String? {
        if case .error(let e) = self { return e }
        return nil
    }
}

@MainActor
protocol FilesColumnDelegate: AnyObject {
    var paneHasFocus: Bool { get }
    func column(_ col: FilesColumnView, clicked name: String)
    func columnRequestsRename(_ col: FilesColumnView)
    func columnRequestsDelete(_ col: FilesColumnView)
    /// `newName` nil: cancelled.
    func column(_ col: FilesColumnView, renameFinished old: String, newName: String?)
    func column(_ col: FilesColumnView, dropped urls: [URL])
}

/// A table that never takes the keyboard focus: the pane is the responder.
final class ColumnTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Selection is drawn emphasised (accent) only in the cursor column of a
/// focused pane; ancestor columns show the unemphasised (grey) look.
final class FilesRowView: NSTableRowView {
    var emphasize = false
    override var isEmphasized: Bool {
        get { emphasize }
        set { _ = newValue }
    }
}

/// One row: name (dot-files faded, symlinks italic), the directory chevron,
/// and on the cursor row the ✎ / ✕ buttons.
final class FilesRowCell: NSView {
    let name = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    let renameButton = NSButton(title: "", target: nil, action: nil)
    let deleteButton = NSButton(title: "", target: nil, action: nil)
    let actions: NSStackView

    override init(frame: NSRect) {
        actions = NSStackView(views: [renameButton, deleteButton])
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(name)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "folder")
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        for (b, sym, tip) in [(renameButton, "pencil", "Rename (r)"), (deleteButton, "xmark", "Delete (d)")] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            b.toolTip = tip
            b.isBordered = false
            b.bezelStyle = .inline
            b.imagePosition = .imageOnly
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: actions.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(entry: DirectoryEntry, font: NSFont, showActions: Bool, selected: Bool) {
        name.stringValue = entry.name
        var f = font
        if entry.symlink {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: f.pointSize) ?? f
        }
        name.font = f
        name.alphaValue = entry.name.hasPrefix(".") ? 0.55 : 1
        name.textColor = selected ? .controlTextColor : .labelColor
        chevron.isHidden = entry.kind != .dir
        actions.isHidden = !showActions
    }
}

@MainActor
final class FilesColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 420
    static let chrome: CGFloat = 72
    static let rowFont = NSFont.systemFont(ofSize: 12.5)

    let dir: String
    weak var delegate: FilesColumnDelegate?
    private(set) var content: ColumnContent = .loading
    private(set) var highlightName: String?
    private(set) var isCursorColumn = false
    private(set) var preferredWidth: CGFloat = FilesColumnView.minWidth

    let scroll = NSScrollView()
    let table = ColumnTableView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    // Rename (F-50)
    private(set) var renamingName: String?
    private var renameField: NSTextField?
    private var renameCommit = false

    init(dir: String) {
        self.dir = dir
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: 100))
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        for l in [message, footer] {
            l.font = Self.italic(Self.rowFont)
            l.textColor = .secondaryLabelColor
            l.alphaValue = 0.8
            l.translatesAutoresizingMaskIntoConstraints = false
            l.isHidden = true
            addSubview(l)
        }
        message.alignment = .left
        footer.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            message.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        setFooter(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func italic(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: d, size: f.pointSize) ?? f
    }

    private var footerHeight: NSLayoutConstraint?
    private func setFooter(_ text: String?) {
        footer.stringValue = text ?? ""
        footer.isHidden = text == nil
        footerHeight?.isActive = false
        footerHeight = footer.heightAnchor.constraint(equalToConstant: text == nil ? 0 : 18)
        footerHeight?.isActive = true
    }

    var entries: [DirectoryEntry] { content.entries }

    /// The rows' message text (`(empty)`, an error code), if shown.
    var messageText: String? { message.isHidden ? nil : message.stringValue }

    /// A column is as wide as its longest name plus the row chrome, within
    /// 200–420 (F-08).
    static func width(for entries: [DirectoryEntry]) -> CGFloat {
        var w: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: rowFont]
        for e in entries { w = max(w, (e.name as NSString).size(withAttributes: attrs).width) }
        return (max(minWidth, min(maxWidth, w + chrome))).rounded()
    }

    /// Show `content` with `highlight` on the path (ancestor column) or
    /// under the cursor (cursor column). Scroll position is kept.
    func update(content: ColumnContent, highlight: String?, isCursorColumn: Bool) {
        let sameEntries = self.content.entries == content.entries
        self.content = content
        self.highlightName = highlight
        self.isCursorColumn = isCursorColumn
        let entries = content.entries
        if !entries.isEmpty { preferredWidth = Self.width(for: entries) }
        switch content {
        case .loading:
            message.isHidden = true
            scroll.isHidden = false
        case .error(let e):
            message.stringValue = e
            message.isHidden = false
            scroll.isHidden = true
        case .listing(let l):
            if l.entries.isEmpty {
                message.stringValue = "(empty)"
                message.isHidden = false
                scroll.isHidden = true
            } else {
                message.isHidden = true
                scroll.isHidden = false
            }
            setFooter(l.truncated ? "(list truncated)" : nil)
        }
        if case .listing = content {} else { setFooter(nil) }
        if sameEntries {
            // Re-style the rows in place (highlight / actions) without reload.
            for row in 0..<table.numberOfRows { configureRow(row) }
        } else {
            table.reloadData()
        }
        applySelection()
    }

    private func applySelection() {
        if let h = highlightName, let i = entries.firstIndex(where: { $0.name == h }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        refreshSelectionAppearance()
    }

    /// Re-draw the selection emphasis after a focus change.
    func refreshSelectionAppearance() {
        let emph = isCursorColumn && (delegate?.paneHasFocus ?? false)
        for row in 0..<table.numberOfRows {
            if let rv = table.rowView(atRow: row, makeIfNecessary: false) as? FilesRowView {
                rv.emphasize = emph
                rv.needsDisplay = true
            }
        }
    }

    /// Keep the cursor row vertically in view (F-64).
    func revealCursorRow() {
        guard let h = highlightName, let i = entries.firstIndex(where: { $0.name == h }) else { return }
        table.scrollRowToVisible(i)
    }

    var selectedRow: Int { table.selectedRow }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = FilesRowView()
        rv.emphasize = isCursorColumn && (delegate?.paneHasFocus ?? false)
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FilesRowCell) ?? {
            let c = FilesRowCell(frame: .zero)
            c.identifier = id
            c.renameButton.target = self
            c.renameButton.action = #selector(renameClicked(_:))
            c.deleteButton.target = self
            c.deleteButton.action = #selector(deleteClicked(_:))
            return c
        }()
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: FilesRowCell, row: Int) {
        guard row < entries.count else { return }
        let e = entries[row]
        let selected = e.name == highlightName
        cell.configure(entry: e, font: Self.rowFont, showActions: isCursorColumn && selected && renamingName == nil, selected: selected && isCursorColumn)
        cell.toolTip = e.name
    }

    private func configureRow(_ row: Int) {
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FilesRowCell { configure(cell, row: row) }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Selection is driven by the model; clicks go through `rowClicked`.
        false
    }

    @objc private func rowClicked(_ sender: Any?) {
        let r = table.clickedRow
        guard r >= 0, r < entries.count else { return }
        if renamingName != nil { return }
        delegate?.column(self, clicked: entries[r].name)
    }

    @objc private func renameClicked(_ sender: Any?) { delegate?.columnRequestsRename(self) }
    @objc private func deleteClicked(_ sender: Any?) { delegate?.columnRequestsDelete(self) }

    // MARK: - rename (F-50)

    /// Swap the cursor row's name for a text field with the stem selected.
    @discardableResult
    func beginRename() -> Bool {
        guard renamingName == nil, let name = highlightName, let i = entries.firstIndex(where: { $0.name == name }),
              let cell = table.view(atColumn: 0, row: i, makeIfNecessary: true) as? FilesRowCell else { return false }
        renamingName = name
        renameCommit = false
        cell.actions.isHidden = true
        let field = NSTextField(string: name)
        field.font = Self.rowFont
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .default
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.chevron.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.name.isHidden = true
        renameField = field
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let stem = FilesPaths.renameStem(name)
            let ns = name as NSString
            _ = ns
            let loc = name.utf16.distance(from: name.utf16.startIndex, to: stem.lowerBound.samePosition(in: name.utf16) ?? name.utf16.startIndex)
            let len = name.utf16.distance(from: stem.lowerBound.samePosition(in: name.utf16) ?? name.utf16.startIndex, to: stem.upperBound.samePosition(in: name.utf16) ?? name.utf16.endIndex)
            editor.selectedRange = NSRange(location: loc, length: len)
        }
        return true
    }

    var isRenaming: Bool { renamingName != nil }
    var renameFieldForTests: NSTextField? { renameField }

    /// End the rename: commit (Enter) or cancel (Escape, focus loss).
    func endRename(commit: Bool) {
        guard let old = renamingName, let field = renameField else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingName = nil
        renameField = nil
        field.delegate = nil
        if field.currentEditor() != nil, window?.firstResponder === field.currentEditor() {
            window?.makeFirstResponder(nil)
        }
        field.removeFromSuperview()
        if let i = entries.firstIndex(where: { $0.name == old }), let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? FilesRowCell {
            cell.name.isHidden = false
            configure(cell, row: i)
        }
        let newName: String? = (commit && !typed.isEmpty && typed != old) ? typed : nil
        delegate?.column(self, renameFinished: old, newName: newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            renameCommit = true
            endRename(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus loss cancels (Enter was handled in doCommandBy).
        if renamingName != nil { endRename(commit: false) }
    }

    // MARK: - drop target (F-54)

    private func hasFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        dropHighlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        delegate?.column(self, dropped: urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dropHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            bounds.fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }
    }
}
