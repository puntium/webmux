// The file-browser pane (PARITY § 6; reference: files/browser.zig and
// electron/ui/files-widget.js). Miller columns in a horizontal scroll view:
// one listing column per directory from `/` down to the cursor's
// directory, then the cursor entry's listing (a folder) or its preview (a
// file). The pane is the keyboard responder (F-20…F-26); columns and the
// preview report clicks, drops and button presses back to it. Listings
// come from a 4 s cache (F-12) refreshed by the host's watch streams
// (F-59), focus (F-61) and mutations.
//
// The adapter embeds the view in a pane frame, supplies the pane id, shows
// `title` (fitting it with `FilesPaths.fitPath`), persists `persistedState`
// on `onStateChange`, routes `onStatus` to the HUD, `onLog` to the
// connection log, `onOpenURL` / `onMailto` to the link handling, and stores
// the folder from `onDownloadDirChosen` on the profile.
import AppKit
import UniformTypeIdentifiers
import WebmuxHost

@MainActor
public final class FilesPaneView: NSView, FilesColumnDelegate, FilesPreviewDelegate {
    // MARK: - public surface

    public let host: HostAPI
    /// The folder downloads were last saved to for this profile (F-55).
    public var profileDownloadDir: URL?
    /// Ask with a save panel (F-55); false saves straight into the
    /// remembered folder (else ~/Downloads) under a free name.
    public var askWhereToSave = true

    public var onTitleChange: ((String) -> Void)?
    /// A toast (`renamed a → b`, `upload failed: …`, …).
    public var onStatus: ((String) -> Void)?
    /// Connection-log lines (`download started` {file}, …).
    public var onLog: ((String, [String: String]) -> Void)?
    public var onDownloadDirChosen: ((URL) -> Void)?
    public var onRequestClose: (() -> Void)?
    /// An http(s) link in rendered markdown: open, or copy when `copy`.
    public var onOpenURL: ((String, _ copy: Bool) -> Void)?
    /// A mailto: link (the open/copy chooser, M-04).
    public var onMailto: ((String) -> Void)?
    /// The persisted state changed (after a render that moved dir/cursor).
    public var onStateChange: ((String) -> Void)?
    /// The pane took the keyboard focus (so the workspace can focus the pane).
    public var onFocusEntered: (() -> Void)?
    /// Replaces the save panel: `(suggested name, initial directory) → destination or nil`.
    public var saveDestinationProvider: ((String, URL) async -> URL?)?

    public private(set) var title = ""
    public private(set) var state: FilesPaneState
    public private(set) var lastStatus: String?

    public var persistedState: String { state.json }

    public init(host: HostAPI, profileDownloadDir: URL?, state: String? = nil) {
        self.host = host
        self.profileDownloadDir = profileDownloadDir
        self.state = FilesPaneState(json: state)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Replace the state (dir + cursor) and re-open.
    public func restore(state json: String) {
        state = FilesPaneState(json: json)
        opened = false
        openFailed = nil
        cache.removeAll()
        drilled = nil
        open()
    }

    public func focus() {
        window?.makeFirstResponder(self)
    }

    /// Hidden panes keep no watch streams (F-59); showing refreshes.
    public func setShown(_ shown: Bool) {
        if self.shown == shown { return }
        self.shown = shown
        if !shown {
            closeWatchers()
            if confirm != nil { finishConfirm(false, refocus: false) }
        } else {
            refreshAll()
        }
    }

    /// The pane closes: streams, timers, nothing else (F-60).
    public func close() {
        closed = true
        closeWatchers()
        watchTimer?.cancel()
        followTimer?.cancel()
        followTimer = nil
        generation += 1
    }

    // MARK: - state read-outs (tests, control socket)

    public var currentDirectory: String { state.dir }
    public var cursor: String? { state.cursor }
    public var isDrilled: Bool { drilled != nil }
    public var isOpened: Bool { opened }
    public var openError: String? { openFailed }
    public var isRenaming: Bool { columns.values.contains { $0.isRenaming } }
    public var confirmationText: String? { confirm?.text }
    public var columnDirectories: [String] { orderedColumns.map(\.dir) }
    public var previewPath: String? { preview?.path }
    public var previewBodyText: String? { preview?.bodyText }
    public var previewMetaText: String? { preview?.metaText }
    public var previewIsNarrow: Bool? { preview?.isNarrow }
    public var previewZipRows: [ZipRow] { preview?.zipRows ?? [] }
    public var markdownShowsSource: Bool { mdSource }
    public var watchedDirectories: [String] { Array(watchers.keys).sorted() }
    /// Watched directories whose stream has delivered `ready`.
    public var readyWatches: [String] { watchers.filter { $0.value.ready }.map(\.key).sorted() }
    public var homeDirectory: String? { home }
    public var isUploading: Bool { uploading }
    public var activeDownloads: Int { downloads }
    /// The strip's horizontal scroll offset and total width (F-63).
    public var horizontalScroll: (offset: CGFloat, total: CGFloat, visible: CGFloat) {
        (scroll.contentView.bounds.origin.x, strip.frame.width, scroll.contentView.bounds.width)
    }

    /// Cached entry names of `dir` (nil: not listed or failed).
    public func listedNames(in dir: String) -> [String]? {
        if case .listing(let l)? = cache[dir]?.content { return l.entries.map(\.name) }
        return nil
    }

    /// The message shown in the column for `dir` (`(empty)`, an error code).
    public func columnMessage(for dir: String) -> String? {
        if let e = openErrorColumn, e.dir == dir { return e.messageText }
        return columns[dir]?.messageText
    }

    /// Nothing pending: no listing in flight, no render waiting, preview loaded.
    public var isIdle: Bool {
        if !opened && openFailed == nil { return false }
        if !inflight.isEmpty || renderPending || watchTimer != nil || uploading || downloads > 0 { return false }
        if let pv = preview, pv.body == .pending || pv.body == .message("…") { return false }
        return true
    }

    /// Switch markdown previews between Rendered and Source (F-35).
    public func setMarkdownSource(_ source: Bool) {
        mdSource = source
        preview?.setMarkdownSource(source)
    }

    /// While a rename field is open: set its text and commit (tests).
    public func commitRename(_ newName: String) {
        guard let col = columns.values.first(where: { $0.isRenaming }) else { return }
        col.renameFieldForTests?.stringValue = newName
        col.endRename(commit: true)
    }

    // MARK: - private state

    private var home: String?
    private var opened = false
    private var openFailed: String?
    private var closed = false
    private var shown = true
    private var renderedOnce = false
    private var renderPending = false
    private var generation = 0

    private struct CacheEntry {
        var time: Date
        var content: ColumnContent
    }
    private static let listTTL: TimeInterval = 4
    private var cache: [String: CacheEntry] = [:]
    private var inflight: Set<String> = []
    private var memory: [String: String] = [:] // F-13
    private var drilled: String?
    private var rightmostDir: String?
    private var mdSource = false // F-35
    private var lastPersisted: String?

    private let scroll = NSScrollView()
    private let strip = StripView()
    private var columns: [String: FilesColumnView] = [:]
    private var orderedColumns: [FilesColumnView] = []
    private var preview: FilesPreviewView?
    private var openErrorColumn: FilesColumnView?
    private var confirm: FilesConfirmView?
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    private final class Watcher {
        var task: Task<Void, Never>?
        var stream: EventStream?
        var ready = false
        func cancel() {
            task?.cancel()
            stream?.interrupt()
            stream?.close()
        }
    }
    private var watchers: [String: Watcher] = [:]
    private var watchTimer: DispatchWorkItem?
    private var uploading = false
    private var downloads = 0
    private var internalFocusMove = false
    private var keyObserver: NSObjectProtocol?

    private func setup() {
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = strip
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        guard let w = window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                self.refreshAll()
            }
        }
        if !opened && openFailed == nil && !closed { open() }
        // Re-attached after a layout change: back to the scrolled-to-the-right view (F-65).
        else if opened { DispatchQueue.main.async { [weak self] in self?.follow(animated: false) } }
    }

    // MARK: - opening (F-03)

    /// List the saved directory (and `~`, to learn the home); fall back to
    /// `~` if it fails; then render.
    public func open() {
        guard !closed, inflight.isEmpty || !opened else { return }
        let api = host.files
        let dir = state.dir
        generation += 1
        let g = generation
        Task { @MainActor [weak self] in
            var homeListing: DirectoryListing?
            var homeErr: Error?
            do { homeListing = try await api.list(path: "~") } catch { homeErr = error }
            var listing: DirectoryListing? = dir == "~" ? homeListing : nil
            var failedFirst = false
            var err: Error? = dir == "~" ? homeErr : nil
            if dir != "~" {
                do { listing = try await api.list(path: dir) } catch {
                    if let h = homeListing { failedFirst = true; listing = h } else { err = error }
                }
            }
            guard let self, g == self.generation else { return }
            if let h = homeListing?.path, h != "/", !h.isEmpty { self.home = h }
            if failedFirst || listing == nil { self.state.cursor = nil }
            guard let l = listing else {
                let e = Self.errorText(err ?? HostError.cancelled)
                log.warning("file browser: cannot open \(dir, privacy: .public): \(e, privacy: .public)")
                self.openFailed = e
                self.opened = false
                self.showOpenError(e)
                return
            }
            self.openFailed = nil
            self.state.dir = l.path.isEmpty ? "/" : l.path
            self.cache[self.state.dir] = CacheEntry(time: Date(), content: .listing(l))
            self.opened = true
            self.rerender()
        }
    }

    private func showOpenError(_ text: String) {
        for c in orderedColumns { c.removeFromSuperview() }
        columns.removeAll()
        orderedColumns.removeAll()
        preview?.removeFromSuperview()
        preview = nil
        let col = openErrorColumn ?? FilesColumnView(dir: state.dir)
        col.delegate = self
        col.update(content: .error(text), highlight: nil, isCursorColumn: false)
        openErrorColumn = col
        strip.addSubview(col)
        layoutColumns(animated: false)
        updateTitle()
    }

    /// The text a failed call shows in a column: the host's error code
    /// (`ENOENT`, `EACCES`), or the transport error's name (deviation 28).
    static func errorText(_ error: Error) -> String {
        if let h = error as? HostError {
            if case .httpStatus(let status, let message) = h { return message.isEmpty ? "HTTP \(status)" : message }
            if let label = Mirror(reflecting: h).children.first?.label { return label }
            switch h {
            case .timeout: return "timeout"
            case .cancelled: return "cancelled"
            case .endOfStream: return "endOfStream"
            case .connectionReset: return "connectionReset"
            case .brokenPipe: return "brokenPipe"
            case .closed: return "closed"
            default: return String(describing: h)
            }
        }
        return String(describing: type(of: error))
    }

    // MARK: - listings (F-12)

    private func listing(_ dir: String) -> ColumnContent {
        if let e = cache[dir], Date().timeIntervalSince(e.time) < Self.listTTL { return e.content }
        fetch(dir)
        return cache[dir]?.content ?? .loading
    }

    private func fetch(_ dir: String) {
        guard !inflight.contains(dir), !closed else { return }
        inflight.insert(dir)
        let api = host.files
        Task { @MainActor [weak self] in
            let content: ColumnContent
            do { content = .listing(try await api.list(path: dir)) } catch { content = .error(Self.errorText(error)) }
            guard let self else { return }
            self.inflight.remove(dir)
            self.cache[dir] = CacheEntry(time: Date(), content: content)
            if self.opened, self.isRelevant(dir) { self.scheduleRender() }
        }
    }

    private func isRelevant(_ dir: String) -> Bool {
        FilesPaths.chain(state.dir).contains(dir) || rightmostDir == dir
    }

    private func invalidate(_ dir: String) { cache.removeValue(forKey: dir) }

    /// The cursor directory's entries as known now.
    private var cursorEntries: [DirectoryEntry] { cache[state.dir]?.content.entries ?? [] }

    private var cursorEntry: DirectoryEntry? {
        guard let c = state.cursor else { return nil }
        return cursorEntries.first { $0.name == c }
    }

    // MARK: - rendering (F-04)

    private func scheduleRender() {
        if renderPending { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.rerender()
        }
    }

    private func rerender() {
        guard opened, !closed else { return }
        if let e = openErrorColumn { e.removeFromSuperview(); openErrorColumn = nil }
        let chain = FilesPaths.chain(state.dir)
        var contents = chain.map { listing($0) }
        if case .listing = contents[contents.count - 1] {
            if state.cursor != nil, cursorEntry == nil { state.cursor = nil }
        }
        if let c = cursorEntry { memory[state.dir] = c.name }
        let previewPath = cursorEntry.flatMap { $0.kind == .dir ? nil : FilesPaths.join(state.dir, $0.name) }
        if let d = drilled, d != previewPath { drilled = nil }
        rightmostDir = cursorEntry?.kind == .dir ? FilesPaths.join(state.dir, cursorEntry!.name) : state.dir

        struct Want { var dir: String; var highlight: String?; var isCursor: Bool }
        var wants: [Want] = []
        for (i, dir) in chain.enumerated() {
            let last = i == chain.count - 1
            wants.append(Want(dir: dir, highlight: last ? state.cursor : FilesPaths.base(chain[i + 1]), isCursor: last))
        }
        if let c = cursorEntry, c.kind == .dir, let sub = rightmostDir {
            contents.append(listing(sub))
            wants.append(Want(dir: sub, highlight: nil, isCursor: false))
        }

        // Reuse surviving columns, create new ones, drop the rest.
        var newOrdered: [FilesColumnView] = []
        var newMap: [String: FilesColumnView] = [:]
        var created: [NSView] = []
        for (i, w) in wants.enumerated() {
            let col: FilesColumnView
            if let existing = columns[w.dir] {
                col = existing
            } else {
                col = FilesColumnView(dir: w.dir)
                col.delegate = self
                strip.addSubview(col)
                created.append(col)
            }
            col.update(content: contents[i], highlight: w.highlight, isCursorColumn: w.isCursor)
            newOrdered.append(col)
            newMap[w.dir] = col
        }
        for (dir, col) in columns where newMap[dir] == nil { col.removeFromSuperview() }
        columns = newMap
        orderedColumns = newOrdered

        if let p = previewPath {
            let pv = preview ?? {
                let v = FilesPreviewView(host: host)
                v.delegate = self
                v.markdownSource = mdSource
                strip.addSubview(v)
                created.append(v)
                return v
            }()
            preview = pv
            pv.isDrilled = drilled != nil
            pv.load(path: p)
        } else if let pv = preview {
            pv.removeFromSuperview()
            preview = nil
        }

        let animate = renderedOnce
        if animate {
            for c in created {
                c.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    c.animator().alphaValue = 1
                }
            }
        }
        layoutColumns(animated: animate)
        renderedOnce = true
        updateTitle()
        persist()
        syncWatchers()
        for c in orderedColumns { c.revealCursorRow() }
        follow(animated: animate)
    }

    private func updateTitle() {
        let full = FilesPaths.tilde(home: home, state.cursor.map { FilesPaths.join(state.dir, $0) } ?? state.dir)
        if full != title {
            title = full
            onTitleChange?(full)
        }
    }

    private func persist() {
        let j = state.json
        if j != lastPersisted {
            lastPersisted = j
            onStateChange?(j)
        }
    }

    // MARK: - layout and horizontal follow (F-08, F-62, F-63)

    public override func layout() {
        super.layout()
        layoutColumns(animated: false)
    }

    private func layoutColumns(animated: Bool) {
        let h = scroll.contentSize.height
        var x: CGFloat = 0
        var frames: [(NSView, NSRect)] = []
        var views: [NSView] = orderedColumns
        if let e = openErrorColumn { views = [e] }
        for c in views {
            let w = (c as? FilesColumnView)?.preferredWidth ?? FilesColumnView.minWidth
            frames.append((c, NSRect(x: x, y: 0, width: w, height: h)))
            x += w + 1
        }
        if let pv = preview {
            frames.append((pv, NSRect(x: x, y: 0, width: pv.preferredWidth, height: h)))
            x += pv.preferredWidth + 1
        }
        let total = max(x - 1, 0)
        let placed = Set(frames.filter { !($0.0.frame.isEmpty) && $0.0.superview === strip && placedViews.contains(ObjectIdentifier($0.0)) }.map { ObjectIdentifier($0.0) })
        placedViews = Set(frames.map { ObjectIdentifier($0.0) })
        strip.separators = frames.dropFirst().map { $0.1.minX - 1 }
        strip.frame = NSRect(x: 0, y: 0, width: max(total, scroll.contentSize.width), height: h)
        // Surviving columns ease to their new place; new ones (and every
        // column of an offscreen window, where animator proxies never run)
        // take their frame at once.
        if animated, window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (v, f) in frames {
                    if placed.contains(ObjectIdentifier(v)) { v.animator().frame = f } else { v.frame = f }
                }
            }
        } else {
            for (v, f) in frames { v.frame = f }
        }
        preview?.needsLayout = true
        strip.needsDisplay = true
    }

    /// Scroll so the rightmost column sits at the right edge without pushing
    /// the cursor's column off the left edge (the whole preview when
    /// drilled). Eased like the Electron client (25% of the remaining
    /// distance per frame, settling exactly at 300 ms); a wheel gesture
    /// cancels it. The first render jumps.
    private func followTarget() -> CGFloat {
        let clip = scroll.contentView
        var target = max(0, strip.frame.width - clip.bounds.width)
        if drilled == nil, let cur = columns[state.dir] {
            target = min(target, cur.frame.minX)
        }
        return max(0, target)
    }

    private var followTimer: DispatchSourceTimer?
    /// Views that already had a frame from a previous layout pass.
    private var placedViews: Set<ObjectIdentifier> = []

    private func follow(animated: Bool) {
        followTimer?.cancel()
        followTimer = nil
        let clip = scroll.contentView
        if !animated {
            clip.setBoundsOrigin(NSPoint(x: followTarget(), y: 0))
            scroll.reflectScrolledClipView(clip)
            return
        }
        let t0 = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let clip = self.scroll.contentView
            let target = self.followTarget()
            var x = clip.bounds.origin.x
            if Date().timeIntervalSince(t0) >= 0.3 {
                x = target
                self.followTimer?.cancel()
                self.followTimer = nil
            } else {
                x += (target - x) * 0.25
            }
            clip.setBoundsOrigin(NSPoint(x: x, y: 0))
            self.scroll.reflectScrolledClipView(clip)
        }
        followTimer = timer
        timer.resume()
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 {
            followTimer?.cancel()
            followTimer = nil
        }
        super.scrollWheel(with: event)
    }

    // MARK: - watchers (F-59)

    private func syncWatchers() {
        var want = Set<String>()
        for d in [state.dir, rightmostDir].compactMap({ $0 }) {
            if case .error? = cache[d]?.content { continue }
            want.insert(d)
        }
        if !shown || closed { want.removeAll() }
        for (dir, w) in watchers where !want.contains(dir) {
            w.cancel()
            watchers.removeValue(forKey: dir)
        }
        for dir in want where watchers[dir] == nil { startWatch(dir) }
    }

    private func startWatch(_ dir: String) {
        let w = Watcher()
        watchers[dir] = w
        let api = host.files
        w.task = Task { @MainActor [weak self, weak w] in
            var hadReady = false
            while !Task.isCancelled {
                do {
                    let s = try await api.watch(path: dir, idleTimeout: nil)
                    guard let w, !Task.isCancelled else { s.close(); return }
                    w.stream = s
                    while let ev = try await s.next() {
                        guard let self, !Task.isCancelled else { s.close(); return }
                        let e = WatchEvent(ev)
                        switch e.kind {
                        case .ready:
                            if hadReady { self.changed(dir) } // reconnected: events may have been missed
                            hadReady = true
                            w.ready = true
                        case .change:
                            self.changed(dir)
                        case .gone:
                            s.close()
                            self.watchers.removeValue(forKey: dir)
                            self.changed(dir)
                            return
                        case .other:
                            break
                        }
                    }
                    s.close()
                } catch {
                    if Task.isCancelled { return }
                }
                // Dropped (the tunnel blinked): retry after a moment.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func closeWatchers() {
        for (_, w) in watchers { w.cancel() }
        watchers.removeAll()
    }

    private func changed(_ dir: String) {
        invalidate(dir)
        if isRenaming { return } // F-51
        watchTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchTimer = nil
            self.rerender()
        }
        watchTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: item)
    }

    /// Focus refresh (F-61): drop cache entries older than 1 s and re-list
    /// every column shown.
    public func refreshAll() {
        if closed { return }
        if openFailed != nil { open(); return }
        guard opened, shown else { return }
        let now = Date()
        for (dir, e) in cache where now.timeIntervalSince(e.time) > 1 { cache.removeValue(forKey: dir) }
        if isRenaming { return }
        rerender()
    }

    // MARK: - focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let fromOutside = !internalFocusMove
        internalFocusMove = false
        for c in orderedColumns { c.refreshSelectionAppearance() }
        if fromOutside {
            onFocusEntered?()
            refreshAll()
        }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.orderedColumns.forEach { $0.refreshSelectionAppearance() }
        }
        return true
    }

    var paneHasFocus: Bool { window?.firstResponder === self }

    private func refocus() {
        internalFocusMove = true
        window?.makeFirstResponder(self)
        internalFocusMove = false
    }

    public override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { focus() }
        super.mouseDown(with: event)
    }

    // MARK: - keyboard (F-20…F-26, F-44)

    public override func keyDown(with event: NSEvent) {
        if confirm != nil { confirm?.keyDown(with: event); return }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            super.keyDown(with: event)
            return
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        let code = event.keyCode
        enum K { case up, down, left, right, enter, escape, pageUp, pageDown, home, end, space, rename, delete, download, none }
        var k: K = .none
        switch code {
        case 126: k = .up
        case 125: k = .down
        case 123: k = .left
        case 124: k = .right
        case 36, 76: k = .enter
        case 53: k = .escape
        case 116: k = .pageUp
        case 121: k = .pageDown
        case 115: k = .home
        case 119: k = .end
        case 49: k = .space
        case 120: k = .rename // F2
        case 51, 117: k = .delete // Backspace, Forward Delete
        default:
            switch chars {
            case "k": k = .up
            case "j": k = .down
            case "h": k = .left
            case "l": k = .right
            case "r": k = .rename
            case "d": k = .delete
            case "D": k = .download
            default: k = .none
            }
        }
        if drilled != nil, let pv = preview {
            switch k {
            case .up: pv.scrollBy(-48); return
            case .down: pv.scrollBy(48); return
            case .pageUp: pv.pageBy(-0.9); return
            case .pageDown, .space: pv.pageBy(0.9); return
            case .home: pv.scrollToTop(); return
            case .end: pv.scrollToEnd(); return
            case .left, .escape: setDrilled(nil); return
            case .right, .enter: return
            default: break
            }
        }
        switch k {
        case .up: moveCursor(-1)
        case .down: moveCursor(1)
        case .right, .enter: enterOrDrill()
        case .left: goToParent()
        case .rename: startRename()
        case .delete: deleteCursor()
        case .download: downloadCursor()
        default: super.keyDown(with: event)
        }
    }

    private func moveCursor(_ step: Int) {
        let entries = cursorEntries
        guard !entries.isEmpty else { return }
        let i = entries.firstIndex { $0.name == state.cursor }
        let next: Int
        if let i { next = max(0, min(entries.count - 1, i + step)) } else { next = step > 0 ? 0 : entries.count - 1 }
        state.cursor = entries[next].name
        rerender()
    }

    private func enterOrDrill() {
        guard let cur = cursorEntry else { return }
        if cur.kind != .dir {
            if let pv = preview, !pv.isNarrow, pv.body != .pending, pv.body != .message("…") {
                setDrilled(FilesPaths.join(state.dir, cur.name))
            }
            return
        }
        enter(FilesPaths.join(state.dir, cur.name))
    }

    private func enter(_ dir: String) {
        state.dir = dir
        let sub = cache[dir]?.content.entries ?? []
        let remembered = memory[dir]
        if case .listing? = cache[dir]?.content {
            state.cursor = (sub.first { $0.name == remembered } ?? sub.first)?.name
        } else {
            // Not listed yet: pick once the listing arrives.
            state.cursor = remembered
            pendingPick = true
        }
        rerender()
    }

    private var pendingPick = false {
        didSet { if pendingPick { schedulePick() } }
    }

    private func schedulePick() {
        // Resolve the cursor as soon as the listing is in the cache.
        let dir = state.dir
        Task { @MainActor [weak self] in
            for _ in 0..<400 {
                guard let self, self.pendingPick, self.state.dir == dir else { return }
                if case .listing(let l)? = self.cache[dir]?.content {
                    self.pendingPick = false
                    let remembered = self.memory[dir]
                    self.state.cursor = (l.entries.first { $0.name == remembered } ?? l.entries.first)?.name
                    self.rerender()
                    return
                }
                if case .error? = self.cache[dir]?.content { self.pendingPick = false; return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func goToParent() {
        if state.dir == "/" { return }
        state.cursor = FilesPaths.base(state.dir)
        state.dir = FilesPaths.parent(state.dir)
        rerender()
    }

    private func setDrilled(_ path: String?) {
        if drilled == path { return }
        drilled = path
        preview?.isDrilled = path != nil
        for c in orderedColumns { c.refreshSelectionAppearance() }
        follow(animated: renderedOnce)
    }

    // MARK: - column delegate

    func column(_ col: FilesColumnView, clicked name: String) {
        state.dir = col.dir
        state.cursor = name
        setDrilled(nil)
        rerender()
        focus()
    }

    func columnRequestsRename(_ col: FilesColumnView) { startRename() }
    func columnRequestsDelete(_ col: FilesColumnView) { deleteCursor() }

    func column(_ col: FilesColumnView, renameFinished old: String, newName: String?) {
        let dir = col.dir
        guard let new = newName else {
            refocus()
            return
        }
        let api = host.files
        Task { @MainActor [weak self] in
            var result: Result<String, Error>
            do { result = .success(try await api.rename(path: FilesPaths.join(dir, old), name: new)) } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success(let n):
                if self.state.dir == dir { self.state.cursor = n }
                self.status("renamed \(old) → \(n)")
            case .failure(let error):
                self.status("rename failed: \(Self.errorText(error))")
            }
            self.invalidate(dir)
            self.rerender()
            self.refocus()
        }
    }

    func column(_ col: FilesColumnView, dropped urls: [URL]) {
        uploadTo(col.dir, LocalUploads.collect(urls))
    }

    // MARK: - preview delegate

    func previewRequestsDownload(_ pv: FilesPreviewView) {
        download(pv.path)
        refocus()
    }

    func preview(_ pv: FilesPreviewView, markdownSourceChanged source: Bool) {
        mdSource = source
        refocus()
    }

    func preview(_ pv: FilesPreviewView, clickedLink href: String, shift: Bool) {
        if href.isEmpty || href.hasPrefix("#") { return }
        let lower = href.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            if let cb = onOpenURL { cb(href, shift) } else if !shift, let u = URL(string: href) { NSWorkspace.shared.open(u) }
            return
        }
        if lower.hasPrefix("mailto:") {
            onMailto?(href)
            return
        }
        let bare = href.firstIndex(where: { $0 == "#" || $0 == "?" }).map { String(href[..<$0]) } ?? href
        guard let local = FilesPaths.resolveRelative(baseDir: FilesPaths.parent(pv.path), href: FilesPaths.percentDecode(bare)), local != "/" else {
            status("can't open \(href)")
            return
        }
        state.dir = FilesPaths.parent(local)
        state.cursor = FilesPaths.base(local)
        setDrilled(nil)
        invalidate(state.dir)
        rerender()
    }

    func previewClicked(_ pv: FilesPreviewView) {
        focus()
        if !pv.isNarrow { setDrilled(pv.path) }
    }

    func preview(_ pv: FilesPreviewView, dropped urls: [URL]) {
        uploadTo(FilesPaths.parent(pv.path), LocalUploads.collect(urls))
    }

    func preview(_ pv: FilesPreviewView, loaded narrow: Bool) {
        if narrow, drilled == pv.path { setDrilled(nil) }
        let wanted = pv.preferredWidth
        if pv.frame.width != wanted {
            layoutColumns(animated: renderedOnce)
            follow(animated: renderedOnce)
        }
    }

    // MARK: - rename (F-50)

    public func startRename() {
        guard state.cursor != nil, let col = columns[state.dir] else { return }
        internalFocusMove = true
        if !col.beginRename() { internalFocusMove = false }
    }

    // MARK: - delete (F-52, F-53)

    public func deleteCursor() {
        guard let name = state.cursor, confirm == nil else { return }
        let entries = cursorEntries
        guard let entry = entries.first(where: { $0.name == name }) else { return }
        let text = entry.kind == .dir ? "Delete folder “\(name)” and everything in it?" : "Delete “\(name)”?"
        let dir = state.dir
        let v = FilesConfirmView(text: text) { [weak self] ok in
            guard let self else { return }
            self.finishConfirm(ok, refocus: true)
            guard ok else { return }
            self.performDelete(dir: dir, name: name, entries: entries)
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        confirm = v
        internalFocusMove = true
        v.takeFocus()
        internalFocusMove = false
    }

    private func finishConfirm(_ ok: Bool, refocus: Bool) {
        guard let v = confirm else { return }
        confirm = nil
        v.removeFromSuperview()
        if refocus { self.refocus() }
    }

    private func performDelete(dir: String, name: String, entries: [DirectoryEntry]) {
        let api = host.files
        Task { @MainActor [weak self] in
            do {
                try await api.delete(path: FilesPaths.join(dir, name))
            } catch {
                self?.status("delete failed: \(Self.errorText(error))")
                return
            }
            guard let self else { return }
            self.status("deleted \(name)")
            if self.state.dir == dir {
                let i = entries.firstIndex { $0.name == name } ?? 0
                let rest = entries.filter { $0.name != name }
                self.state.cursor = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].name
            }
            self.invalidate(dir)
            self.rerender()
        }
    }

    // MARK: - uploads (F-54, F-56, F-57)

    /// Upload local files or folders into `dir` (nil: the rightmost directory shown).
    public func upload(urls: [URL], toDir dir: String? = nil) {
        uploadTo(dir ?? rightmostDir ?? state.dir, LocalUploads.collect(urls))
    }

    /// Choose files or folders with an open panel and upload them into the
    /// rightmost directory shown.
    public func uploadViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        let target = rightmostDir ?? state.dir
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let self else { return }
            self.uploadTo(target, LocalUploads.collect(panel.urls))
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    private func uploadTo(_ dir: String, _ files: [LocalUpload]) {
        guard !files.isEmpty else { status("nothing to upload"); return }
        uploading = true
        status("uploading \(files.count) file(s)…")
        let api = host.files
        Task { @MainActor [weak self] in
            var lastName: String?
            for f in files {
                do {
                    let written = try await api.upload(file: f.url, toDir: dir, name: f.name, timeout: .seconds(600))
                    lastName = written.split(separator: "/").first.map(String.init) ?? written
                } catch {
                    guard let self else { return }
                    self.uploading = false
                    self.status("upload failed: \(Self.errorText(error))")
                    self.invalidate(dir)
                    self.rerender()
                    return
                }
            }
            guard let self else { return }
            self.uploading = false
            self.status("uploaded \(files.count) file(s) → \(dir)")
            self.invalidate(dir)
            self.state.dir = dir
            self.state.cursor = lastName
            self.setDrilled(nil)
            self.rerender()
        }
    }

    /// Files or images on the clipboard upload into the rightmost directory
    /// shown; text is ignored (F-56).
    @objc public func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            upload(urls: urls)
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("webmux-paste-\(UUID().uuidString).\(ext)")
                do { try data.write(to: tmp) } catch { status("upload failed: \(error.localizedDescription)"); return }
                uploadTo(rightmostDir ?? state.dir, [LocalUpload(url: tmp, name: "pasted.\(ext)", size: Int64(data.count))])
                return
            }
        }
    }

    // MARK: - download (F-25, F-32, F-55)

    public func downloadCursor() {
        guard let cur = cursorEntry else { return }
        if cur.kind == .dir { status("select a file to download"); return }
        download(FilesPaths.join(state.dir, cur.name))
    }

    /// The folder the save panel opens in: the profile's remembered folder
    /// if it still exists, else ~/Downloads, else home.
    public var defaultDownloadDirectory: URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if let d = profileDownloadDir, fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue { return d }
        if let d = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, fm.fileExists(atPath: d.path) { return d }
        return fm.homeDirectoryForCurrentUser
    }

    public func download(_ path: String) {
        let name = FilesPaths.base(path)
        status("downloading \(name)")
        onLog?("download started", ["file": name])
        downloads += 1
        let api = host.files
        let initial = defaultDownloadDirectory
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloads -= 1 }
            let dest: URL?
            if let provider = self.saveDestinationProvider {
                dest = await provider(name, initial)
            } else if self.askWhereToSave {
                dest = await self.runSavePanel(name: name, directory: initial)
            } else {
                dest = SaveFile.freeName(in: initial, name)
            }
            guard let dest else {
                self.onLog?("download cancelled", ["file": name])
                return
            }
            do {
                let temp = try SaveFile(destination: dest)
                let s = try await api.raw(path: path, download: true)
                defer { s.close() }
                let bytes = try await s.write(to: temp.temporaryURL)
                try temp.commit()
                self.onLog?("download saved", ["file": name, "path": dest.path, "bytes": String(bytes)])
                self.status("saved \(name)")
                let dir = dest.deletingLastPathComponent()
                self.profileDownloadDir = dir
                self.onDownloadDirChosen?(dir)
            } catch let e as SaveFileError {
                self.status("download failed: \(e.description)")
                self.onLog?("download interrupted", ["file": name, "error": e.description])
            } catch {
                self.status("download failed: \(Self.errorText(error))")
                self.onLog?("download interrupted", ["file": name, "error": Self.errorText(error)])
            }
        }
    }

    private func runSavePanel(name: String, directory: URL) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return await withCheckedContinuation { cont in
            let done: (NSApplication.ModalResponse) -> Void = { r in cont.resume(returning: r == .OK ? panel.url : nil) }
            if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
        }
    }

    // MARK: - status

    private func status(_ text: String) {
        lastStatus = text
        log.info("\(text, privacy: .public)")
        onStatus?(text)
    }

    // MARK: - drop anywhere else in the pane (F-54)

    private func hasFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        dropHighlighted = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { hasFiles(sender) ? .copy : [] }
    public override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    public override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        upload(urls: urls)
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
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

/// The columns' container: draws the 1 px separators between them.
final class StripView: NSView {
    var separators: [CGFloat] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for x in separators { NSRect(x: x, y: 0, width: 1, height: bounds.height).fill() }
    }
}
