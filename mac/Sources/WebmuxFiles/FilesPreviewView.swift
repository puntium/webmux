// The preview column (F-30…F-45): header (name, `<size> · [<N> entries ·]
// <mtime>`, the ⤓ download button, the Rendered / Source toggle for
// markdown) and a body that is an image, monospaced text, rendered
// markdown (selectable), a zip table of contents as an outline, a PDF, or a
// message (`binary file`, `no preview`, an error code, `…`, `preview
// failed`). The column is "narrow" (280) when there is nothing but the
// header to show, "wide" (600) otherwise.
import AppKit
import PDFKit
import WebmuxHost

@MainActor
protocol FilesPreviewDelegate: AnyObject {
    func previewRequestsDownload(_ pv: FilesPreviewView)
    func preview(_ pv: FilesPreviewView, markdownSourceChanged source: Bool)
    func preview(_ pv: FilesPreviewView, clickedLink href: String, shift: Bool)
    /// A click on the preview itself (not a link or button): drill in.
    func previewClicked(_ pv: FilesPreviewView)
    func preview(_ pv: FilesPreviewView, dropped urls: [URL])
    /// The preview arrived (or failed); `narrow` says which width it wants.
    func preview(_ pv: FilesPreviewView, loaded narrow: Bool)
}

/// A text view that reports plain clicks (not on links) to the preview.
final class PreviewTextView: NSTextView {
    var onPlainClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        var onLink = false
        if idx < textStorage?.length ?? 0, textStorage?.attribute(.link, at: idx, effectiveRange: nil) != nil { onLink = true }
        super.mouseDown(with: event)
        if !onLink, selectedRange().length == 0 { onPlainClick?() }
    }
}

@MainActor
final class FilesPreviewView: NSView, NSTextViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let wideWidth: CGFloat = 600
    static let narrowWidth: CGFloat = 280
    static let imageLimit = 50 * 1024 * 1024
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    enum Body: Equatable {
        case pending
        case message(String)
        case text
        case markdown(source: Bool)
        case image
        case zip
        case pdf
    }

    let host: HostAPI
    weak var delegate: FilesPreviewDelegate?
    private(set) var path: String = ""
    private(set) var info: FilePreview?
    private(set) var body: Body = .pending
    private(set) var isNarrow = true
    var markdownSource = false
    var isDrilled = false { didSet { updateHeaderHighlight() } }
    private var generation = 0

    // Header
    private let header = NSView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    let downloadButton = NSButton(title: "", target: nil, action: nil)
    let viewToggle = NSSegmentedControl(labels: ["Rendered", "Source"], trackingMode: .selectOne, target: nil, action: nil)

    // Body
    let scroll = NSScrollView()
    private let message = NSTextField(labelWithString: "")
    private var textView: PreviewTextView?
    private var imageView: NSImageView?
    private var outline: NSOutlineView?
    private var zipRoot: ZipNode?
    private var pdfView: PDFView?
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    init(host: HostAPI) {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: Self.narrowWidth, height: 100))
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        header.wantsLayer = true
        header.layer?.cornerRadius = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byCharWrapping
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(nameLabel)
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(metaLabel)
        downloadButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Download")
        downloadButton.toolTip = "Download (D)"
        downloadButton.bezelStyle = .accessoryBarAction
        downloadButton.isBordered = true
        downloadButton.imagePosition = .imageOnly
        downloadButton.target = self
        downloadButton.action = #selector(downloadClicked(_:))
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.setContentHuggingPriority(.required, for: .horizontal)
        header.addSubview(downloadButton)
        viewToggle.controlSize = .small
        viewToggle.segmentStyle = .rounded
        viewToggle.target = self
        viewToggle.action = #selector(toggleChanged(_:))
        viewToggle.translatesAutoresizingMaskIntoConstraints = false
        viewToggle.isHidden = true
        header.addSubview(viewToggle)

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        message.font = FilesColumnView.italic(FilesColumnView.rowFont)
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            downloadButton.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            downloadButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            downloadButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewToggle.leadingAnchor, constant: -6),
            viewToggle.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            viewToggle.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            metaLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        ])
        header.isHidden = true
        showMessage("…")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var preferredWidth: CGFloat { isNarrow ? Self.narrowWidth : Self.wideWidth }

    /// The text shown in the body (text / markdown / message), for tests.
    var bodyText: String? {
        if !message.isHidden { return message.stringValue }
        return textView?.string
    }

    var nameText: String { nameLabel.stringValue }
    var metaText: String { metaLabel.stringValue }
    var zipRows: [ZipRow] { info?.entries.map(ZipTree.rows) ?? [] }

    private func updateHeaderHighlight() {
        header.layer?.backgroundColor = isDrilled ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : nil
    }

    // MARK: - loading

    /// Fetch and show the preview of `path`. A re-load of the same path
    /// keeps the body and its scroll position until the new data differs
    /// (deviation 28).
    func load(path: String) {
        generation += 1
        let g = generation
        let same = path == self.path
        self.path = path
        if !same {
            info = nil
            header.isHidden = true
            showMessage("…")
            body = .pending
        }
        let api = host.files
        Task { @MainActor [weak self] in
            do {
                let p = try await api.preview(path: path)
                guard let self, g == self.generation else { return }
                self.apply(p, same: same)
            } catch {
                guard let self, g == self.generation else { return }
                self.info = nil
                self.header.isHidden = true
                if case HostError.httpStatus(_, let m) = error, !m.isEmpty {
                    self.showMessage(m)
                } else {
                    self.showMessage("preview failed")
                }
                self.setNarrow(true)
            }
        }
    }

    private func apply(_ p: FilePreview, same: Bool) {
        let name = FilesPaths.base(path)
        if same, let old = info, old == p, body != .pending, body != .message("…") {
            // Nothing changed: keep the body (and the reader's place).
            setNarrow(!Self.hasContent(p, name: name))
            return
        }
        info = p
        header.isHidden = false
        nameLabel.stringValue = name
        var bits = [FilesPaths.formatSize(Double(p.size))]
        if p.kind == .zip, let c = p.count { bits.append("\(Int(c)) \(Int(c) == 1 ? "entry" : "entries")") }
        bits.append(Self.dateText(p.mtime))
        metaLabel.stringValue = bits.joined(separator: " · ")
        downloadButton.isHidden = p.kind == .other
        let isMD = p.kind == .text && FilesPaths.isMarkdownName(name)
        viewToggle.isHidden = !isMD
        let scrollTop = same ? scroll.contentView.bounds.origin : .zero
        clearBody()
        switch p.kind {
        case .image:
            setNarrow(false)
            loadImage()
        case .text where isMD:
            setNarrow(false)
            viewToggle.selectedSegment = markdownSource ? 1 : 0
            if markdownSource || (p.content ?? "").isEmpty {
                showText(p.content ?? "", truncated: p.truncated, mono: true)
                body = .markdown(source: true)
            } else {
                showMarkdown(p.content ?? "", truncated: p.truncated)
                body = .markdown(source: false)
            }
        case .text:
            setNarrow(false)
            showText(p.content ?? "", truncated: p.truncated, mono: true)
            body = .text
        case .zip:
            setNarrow(false)
            showZip(p.entries ?? [], truncated: p.truncated)
            body = .zip
        case .binary, .other, .unknown:
            if FilesPaths.fileExtension(name) == "pdf" {
                setNarrow(false)
                loadPDF()
            } else if p.kind == .binary {
                setNarrow(true)
                showMessage("binary file")
            } else {
                setNarrow(true)
                showMessage("no preview")
            }
        }
        if same, scrollTop != .zero {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scroll.contentView.scroll(to: scrollTop)
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        }
    }

    static func hasContent(_ p: FilePreview, name: String) -> Bool {
        switch p.kind {
        case .image, .text, .zip: return true
        default: return FilesPaths.fileExtension(name) == "pdf"
        }
    }

    static func dateText(_ mtime: Double) -> String {
        let d = Date(timeIntervalSince1970: mtime / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    private func setNarrow(_ narrow: Bool) {
        let changed = narrow != isNarrow
        isNarrow = narrow
        _ = changed
        delegate?.preview(self, loaded: narrow)
    }

    private func clearBody() {
        textView = nil
        imageView = nil
        outline = nil
        zipRoot = nil
        pdfView = nil
        scroll.documentView = nil
        scroll.isHidden = false
        message.isHidden = true
    }

    func showMessage(_ text: String) {
        clearBody()
        scroll.isHidden = true
        message.stringValue = text
        message.isHidden = false
        body = .message(text)
    }

    private func makeTextView(wrapping: Bool) -> PreviewTextView {
        let tv = PreviewTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = !wrapping
        tv.autoresizingMask = wrapping ? [.width] : []
        tv.textContainer?.widthTracksTextView = wrapping
        tv.textContainer?.containerSize = NSSize(width: wrapping ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.delegate = self
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        tv.onPlainClick = { [weak self] in
            guard let self, !self.isNarrow else { return }
            self.delegate?.previewClicked(self)
        }
        return tv
    }

    private func showText(_ content: String, truncated: Bool, mono: Bool) {
        let tv = makeTextView(wrapping: false)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.45
        para.lineBreakMode = .byClipping
        let s = NSMutableAttributedString(string: content.isEmpty ? "(empty file)" : content, attributes: [
            .font: Self.monoFont,
            .foregroundColor: content.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: para,
        ])
        if truncated { s.append(Self.trailer("(preview truncated)")) }
        tv.textStorage?.setAttributedString(s)
        textView = tv
        scroll.documentView = tv
        scroll.hasHorizontalScroller = true
    }

    private static func trailer(_ text: String) -> NSAttributedString {
        NSAttributedString(string: "\n" + text, attributes: [.font: FilesColumnView.italic(FilesColumnView.rowFont), .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func showMarkdown(_ content: String, truncated: Bool) {
        let tv = makeTextView(wrapping: true)
        let r = MarkdownRenderer.render(content, fileDir: FilesPaths.parent(path))
        let s = NSMutableAttributedString(attributedString: r.attributed)
        if truncated { s.append(Self.trailer("(preview truncated)")) }
        tv.textStorage?.setAttributedString(s)
        textView = tv
        scroll.documentView = tv
        scroll.hasHorizontalScroller = false
        if !r.localImagePaths.isEmpty { loadMarkdownImages(into: tv) }
    }

    /// Fetch local images (F-37) and swap them in for their alt text.
    private func loadMarkdownImages(into tv: PreviewTextView) {
        let g = generation
        guard let storage = tv.textStorage else { return }
        var targets: [(String, NSRange)] = []
        storage.enumerateAttribute(.webmuxImagePath, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
            if let p = v as? String { targets.append((p, range)) }
        }
        let api = host.files
        let width = max(100, Self.wideWidth - 40)
        for (p, _) in targets.prefix(24) {
            Task { @MainActor [weak self] in
                guard let data = try? await Self.fetchRaw(api, p), let img = NSImage(data: data) else { return }
                guard let self, g == self.generation, let storage = tv.textStorage else { return }
                var found: NSRange?
                storage.enumerateAttribute(.webmuxImagePath, in: NSRange(location: 0, length: storage.length)) { v, range, stop in
                    if (v as? String) == p { found = range; stop.pointee = true }
                }
                guard let range = found else { return }
                let size = img.size
                let scale = size.width > width ? width / size.width : 1
                let att = NSTextAttachment()
                let cell = NSTextAttachmentCell(imageCell: img)
                att.attachmentCell = cell
                att.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                let rep = NSMutableAttributedString(attachment: att)
                if let para = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) {
                    rep.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: rep.length))
                }
                storage.replaceCharacters(in: range, with: rep)
            }
        }
    }

    static func fetchRaw(_ api: FilesAPI, _ path: String) async throws -> Data {
        let s = try await api.raw(path: path)
        defer { s.close() }
        return try await s.readAll(maxBody: imageLimit)
    }

    private func loadImage() {
        let g = generation
        let p = path
        let api = host.files
        showMessage("…")
        Task { @MainActor [weak self] in
            do {
                let data = try await Self.fetchRaw(api, p)
                guard let self, g == self.generation else { return }
                guard let img = NSImage(data: data) else { self.showMessage("preview failed"); return }
                let iv = NSImageView()
                iv.image = img
                iv.imageScaling = .scaleProportionallyDown
                iv.imageAlignment = .alignTopLeft
                iv.translatesAutoresizingMaskIntoConstraints = false
                let w = max(50, self.scroll.contentSize.width - 16)
                let scale = img.size.width > w ? w / img.size.width : 1
                let h = max(20, img.size.height * scale)
                iv.frame = NSRect(x: 0, y: 0, width: w + 16, height: h + 16)
                let doc = NSView(frame: iv.frame)
                doc.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
                    iv.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
                    iv.widthAnchor.constraint(equalToConstant: w),
                    iv.heightAnchor.constraint(equalToConstant: h),
                ])
                self.clearBody()
                self.imageView = iv
                self.scroll.documentView = doc
                self.body = .image
            } catch {
                guard let self, g == self.generation else { return }
                self.showMessage("preview failed")
            }
        }
    }

    private func loadPDF() {
        let g = generation
        let p = path
        let api = host.files
        showMessage("…")
        Task { @MainActor [weak self] in
            do {
                let data = try await Self.fetchRaw(api, p)
                guard let self, g == self.generation else { return }
                guard let doc = PDFDocument(data: data) else {
                    self.setNarrow(true)
                    self.showMessage("binary file")
                    return
                }
                self.clearBody()
                self.scroll.isHidden = true
                let pv = PDFView(frame: self.bounds)
                pv.document = doc
                pv.autoScales = true
                pv.translatesAutoresizingMaskIntoConstraints = false
                self.addSubview(pv)
                NSLayoutConstraint.activate([
                    pv.topAnchor.constraint(equalTo: self.header.bottomAnchor, constant: 4),
                    pv.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                    pv.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                    pv.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                ])
                self.pdfView = pv
                self.body = .pdf
            } catch {
                guard let self, g == self.generation else { return }
                self.showMessage("preview failed")
            }
        }
    }

    private func showZip(_ entries: [ZipEntry], truncated: Bool) {
        if entries.isEmpty {
            showMessage("(empty archive)")
            body = .zip
            return
        }
        let root = ZipTree.build(entries)
        zipRoot = root
        let ov = NSOutlineView()
        ov.headerView = nil
        ov.rowHeight = 18
        ov.style = .plain
        ov.indentationPerLevel = 14
        ov.backgroundColor = .clear
        ov.selectionHighlightStyle = .none
        ov.usesAlternatingRowBackgroundColors = false
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.width = Self.wideWidth - 120
        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.width = 80
        ov.addTableColumn(nameCol)
        ov.addTableColumn(sizeCol)
        ov.outlineTableColumn = nameCol
        ov.dataSource = self
        ov.delegate = self
        ov.target = self
        ov.action = #selector(outlineClicked(_:))
        ov.autoresizesOutlineColumn = true
        outline = ov
        scroll.documentView = ov
        scroll.hasHorizontalScroller = false
        ov.reloadData()
        ov.expandItem(nil, expandChildren: true)
        if truncated {
            // The footer rides inside the outline as a last, flat note.
            message.stringValue = "(list truncated)"
        }
    }

    // MARK: - outline (zip)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? ZipNode) ?? zipRoot)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? ZipNode) ?? zipRoot)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ZipNode)?.isDir ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ZipNode else { return nil }
        let isSize = tableColumn?.identifier.rawValue == "size"
        let id = NSUserInterfaceItemIdentifier(isSize ? "zsize" : "zname")
        let label = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = id
            l.font = Self.monoFont
            l.lineBreakMode = .byTruncatingMiddle
            return l
        }()
        if isSize {
            label.stringValue = node.isDir ? "" : FilesPaths.formatSize(node.size)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = node.isDir ? node.name + "/" : node.name
            label.textColor = node.isDir ? .secondaryLabelColor : .labelColor
        }
        return label
    }

    @objc private func outlineClicked(_ sender: Any?) {
        if !isNarrow { delegate?.previewClicked(self) }
    }

    // MARK: - header actions

    @objc private func downloadClicked(_ sender: Any?) { delegate?.previewRequestsDownload(self) }

    @objc private func toggleChanged(_ sender: Any?) {
        let source = viewToggle.selectedSegment == 1
        setMarkdownSource(source)
        delegate?.preview(self, markdownSourceChanged: source)
    }

    /// Switch the markdown body between rendered and source (F-35).
    func setMarkdownSource(_ source: Bool) {
        markdownSource = source
        guard let p = info, case .markdown = body else { return }
        viewToggle.selectedSegment = source ? 1 : 0
        clearBody()
        if source || (p.content ?? "").isEmpty {
            showText(p.content ?? "", truncated: p.truncated, mono: true)
            body = .markdown(source: true)
        } else {
            showMarkdown(p.content ?? "", truncated: p.truncated)
            body = .markdown(source: false)
        }
    }

    // MARK: - text view delegate (links, F-38)

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let href: String
        if let s = link as? String { href = s } else if let u = link as? URL { href = u.relativeString.isEmpty ? u.absoluteString : u.relativeString } else { return false }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        delegate?.preview(self, clickedLink: href, shift: shift)
        return true
    }

    // MARK: - scrolling (F-44)

    func scrollBy(_ dy: CGFloat) {
        let clip = scroll.contentView
        var o = clip.bounds.origin
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        o.y = min(maxY, max(0, o.y + dy))
        clip.scroll(to: o)
        scroll.reflectScrolledClipView(clip)
    }

    func pageBy(_ fraction: CGFloat) {
        scrollBy(scroll.contentView.bounds.height * fraction)
    }

    func scrollToTop() { scrollBy(-1e9) }
    func scrollToEnd() { scrollBy(1e9) }

    var scrollOffset: CGFloat { scroll.contentView.bounds.origin.y }

    // MARK: - click to drill (F-43)

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if !isNarrow { delegate?.previewClicked(self) }
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

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender) ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        delegate?.preview(self, dropped: urls)
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
