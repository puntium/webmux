// The pane against a real, isolated webmux host (FilesTestHost), driven
// programmatically in an offscreen window: key events through
// `NSWindow.sendEvent`, the rename field, the confirmation overlay, uploads
// and downloads. Skipped when the host binary is missing.
import AppKit
import XCTest
import WebmuxHost
@testable import WebmuxFiles

@MainActor
final class PaneHarness {
    let window: NSWindow
    let pane: FilesPaneView
    var statuses: [String] = []
    var titles: [String] = []
    var logs: [(String, [String: String])] = []
    var states: [String] = []
    var downloadDirs: [URL] = []

    init(api: HostAPI, dir: String, cursor: String? = nil, downloadDir: URL? = nil) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        pane = FilesPaneView(host: api, profileDownloadDir: downloadDir, state: FilesPaneState(dir: dir, cursor: cursor).json)
        pane.onStatus = { [unowned self] in statuses.append($0) }
        pane.onTitleChange = { [unowned self] in titles.append($0) }
        pane.onLog = { [unowned self] m, d in logs.append((m, d)) }
        pane.onStateChange = { [unowned self] in states.append($0) }
        pane.onDownloadDirChosen = { [unowned self] in downloadDirs.append($0) }
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.makeFirstResponder(pane)
        window.layoutIfNeeded()
    }

    func close() {
        pane.close()
        window.close()
    }

    /// Poll `cond` until it holds (or fail after `timeout`).
    func wait(_ what: String, timeout: Double = 8, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                let diag = "dir \(pane.currentDirectory), cursor \(pane.cursor ?? "nil"), opened \(pane.isOpened), openError \(pane.openError ?? "-"), idle \(pane.isIdle), status \(pane.lastStatus ?? "-"), columns \(pane.columnDirectories), preview \(pane.previewPath ?? "-") body \(pane.previewBodyText ?? "-")"
                // XCTest renders a thrown NSError poorly; record the text first.
                XCTFail("timed out waiting for \(what): \(diag)")
                throw NSError(domain: "PaneHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(what): \(diag)"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitIdle() async throws {
        try await wait("idle") { pane.isIdle }
    }

    /// A key press through the window, as the app would deliver it.
    func key(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.sendEvent(down)
    }

    func key(_ chars: String) { key(chars, code: 0) }
    func down() { key("", code: 125) }
    func up() { key("", code: 126) }
    func left() { key("", code: 123) }
    func right() { key("", code: 124) }
    func enter() { key("\r", code: 36) }
    func escape() { key("\u{1b}", code: 53) }
}

final class FilesPaneLiveTests: XCTestCase {
    override class func tearDown() {
        FilesTestHost.stop()
        super.tearDown()
    }

    /// The host starts off the main thread: `Process.waitUntilExit` on the
    /// main thread would spin the run loop under the async test.
    private func api() async throws -> HostAPI {
        let sock = try await Task.detached { try FilesTestHost.socketPath() }.value
        return HostAPI(socketPath: sock, timeout: .seconds(10))
    }

    /// A directory under the host's HOME with sub/, .hidden, a.txt, b.md.
    private func fixture() throws -> String {
        let p = "\(FilesTestHost.home)/t-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(p)/sub/inner", withIntermediateDirectories: true)
        try "hello\n".write(toFile: "\(p)/a.txt", atomically: true, encoding: .utf8)
        try "# Hi\n\nSome *text* and [a.txt](a.txt).\n".write(toFile: "\(p)/b.md", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(p)/.hidden", atomically: true, encoding: .utf8)
        try "deep".write(toFile: "\(p)/sub/inner/d.txt", atomically: true, encoding: .utf8)
        return p
    }

    @MainActor
    func testOpenListsDirectoryTitleAndState() async throws {
        let a = try await api() // first: starting the host empties its HOME
        let dir = try fixture()
        let h = PaneHarness(api: a, dir: dir)
        defer { h.close() }
        try await h.waitIdle()
        XCTAssertEqual(h.pane.currentDirectory, dir)
        XCTAssertNil(h.pane.cursor)
        XCTAssertEqual(h.pane.columnDirectories, FilesPaths.chain(dir))
        XCTAssertEqual(Set(h.pane.listedNames(in: dir) ?? []), ["sub", ".hidden", "a.txt", "b.md"])
        XCTAssertEqual(h.pane.listedNames(in: dir)?.first, "sub") // directories first
        XCTAssertEqual(h.pane.homeDirectory, FilesTestHost.home)
        XCTAssertEqual(h.pane.title, "~/" + FilesPaths.base(dir))
        XCTAssertEqual(h.titles.last, h.pane.title)
        XCTAssertEqual(h.pane.persistedState, "{\"type\":\"files\",\"dir\":\"\(dir)\",\"cursor\":null}")
        XCTAssertEqual(h.states.last, h.pane.persistedState)
        XCTAssertEqual(h.pane.watchedDirectories, [dir])
        XCTAssertNil(h.pane.previewPath)

        // A saved directory that no longer exists: cursor cleared, ~ listed (F-03).
        h.pane.restore(state: "{\"type\":\"files\",\"dir\":\"\(dir)/nope\",\"cursor\":\"x\"}")
        try await h.wait("fallback to ~") { h.pane.isIdle && h.pane.currentDirectory == FilesTestHost.home }
        XCTAssertNil(h.pane.cursor)
        XCTAssertEqual(h.pane.title, "~")

        // Hidden panes hold no watch streams.
        h.pane.setShown(false)
        XCTAssertEqual(h.pane.watchedDirectories, [])
        h.pane.setShown(true)
        try await h.waitIdle()
        XCTAssertEqual(h.pane.watchedDirectories, [FilesTestHost.home])
    }

    @MainActor
    func testKeyboardNavigationPreviewAndDrill() async throws {
        let a = try await api() // first: starting the host empties its HOME
        let dir = try fixture()
        let h = PaneHarness(api: a, dir: dir)
        defer { h.close() }
        try await h.waitIdle()

        h.down() // first entry: sub (a directory → its listing column appears)
        XCTAssertEqual(h.pane.cursor, "sub")
        try await h.wait("sub listed") { h.pane.isIdle && h.pane.columnDirectories.last == "\(dir)/sub" }
        XCTAssertEqual(h.pane.listedNames(in: "\(dir)/sub"), ["inner"])
        XCTAssertEqual(h.pane.title, "~/\(FilesPaths.base(dir))/sub")
        XCTAssertEqual(Set(h.pane.watchedDirectories), [dir, "\(dir)/sub"])

        h.key("j"); h.key("j") // .hidden, a.txt
        XCTAssertEqual(h.pane.cursor, "a.txt")
        try await h.wait("preview of a.txt") { h.pane.isIdle && h.pane.previewPath == "\(dir)/a.txt" && h.pane.previewBodyText == "hello\n" }
        XCTAssertEqual(h.pane.previewIsNarrow, false)
        XCTAssertTrue(h.pane.previewMetaText?.hasPrefix("6 B · ") ?? false, h.pane.previewMetaText ?? "nil")
        XCTAssertEqual(h.pane.columnDirectories.last, dir)

        // → drills into the preview; Escape leaves; ↑ at the top clamps (F-20).
        h.right()
        XCTAssertTrue(h.pane.isDrilled)
        h.up() // scrolls the preview, cursor stays
        XCTAssertEqual(h.pane.cursor, "a.txt")
        h.escape()
        XCTAssertFalse(h.pane.isDrilled)
        h.key("k"); h.key("k"); h.key("k"); h.key("k")
        XCTAssertEqual(h.pane.cursor, "sub")

        // Enter a directory, cursor memory on the way back (F-13, F-22).
        h.enter()
        try await h.wait("entered sub") { h.pane.isIdle && h.pane.currentDirectory == "\(dir)/sub" && h.pane.cursor == "inner" }
        h.key("l")
        try await h.wait("entered inner") { h.pane.isIdle && h.pane.currentDirectory == "\(dir)/sub/inner" && h.pane.cursor == "d.txt" }
        try await h.wait("preview d.txt") { h.pane.previewBodyText == "deep" }
        h.key("h")
        XCTAssertEqual(h.pane.currentDirectory, "\(dir)/sub")
        XCTAssertEqual(h.pane.cursor, "inner")
        h.left()
        XCTAssertEqual(h.pane.currentDirectory, dir)
        XCTAssertEqual(h.pane.cursor, "sub")
        try await h.waitIdle()
        h.key("j"); h.key("j"); h.key("j") // b.md
        XCTAssertEqual(h.pane.cursor, "b.md")
        try await h.wait("markdown rendered") { h.pane.isIdle && h.pane.previewBodyText == "Hi\nSome text and a.txt." }
        h.pane.setMarkdownSource(true)
        XCTAssertEqual(h.pane.previewBodyText, "# Hi\n\nSome *text* and [a.txt](a.txt).\n")
        XCTAssertTrue(h.pane.markdownShowsSource)
        h.pane.setMarkdownSource(false)
        XCTAssertEqual(h.pane.previewBodyText, "Hi\nSome text and a.txt.")

        // Keys with ⌘ held pass through (F-26).
        h.key("j", code: 0, mods: [.command])
        XCTAssertEqual(h.pane.cursor, "b.md")
        XCTAssertEqual(h.pane.persistedState, "{\"type\":\"files\",\"dir\":\"\(dir)\",\"cursor\":\"b.md\"}")
    }

    @MainActor
    func testRenameAndDeleteWithConfirmation() async throws {
        let a = try await api() // first: starting the host empties its HOME
        let dir = try fixture()
        let h = PaneHarness(api: a, dir: dir, cursor: "a.txt")
        defer { h.close() }
        try await h.wait("opened on a.txt") { h.pane.isIdle && h.pane.cursor == "a.txt" }

        h.key("r")
        XCTAssertTrue(h.pane.isRenaming)
        h.pane.commitRename("c.txt")
        try await h.wait("renamed") { h.statuses.contains("renamed a.txt → c.txt") && h.pane.isIdle }
        XCTAssertEqual(h.pane.cursor, "c.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/c.txt"))
        XCTAssertTrue(h.pane.window?.firstResponder === h.pane)

        // Rename to a taken name fails with the host's message.
        h.key("r")
        h.pane.commitRename("b.md")
        try await h.wait("rename failed") { h.statuses.last == "rename failed: name already taken" }

        // A cancelled rename changes nothing.
        h.key("r")
        XCTAssertTrue(h.pane.isRenaming)
        h.escape()
        if h.pane.isRenaming { h.pane.window?.makeFirstResponder(h.pane) }
        try await h.wait("rename cancelled") { !h.pane.isRenaming }
        XCTAssertEqual(h.pane.cursor, "c.txt")

        // Delete asks first (F-52); Escape cancels.
        h.key("d")
        XCTAssertEqual(h.pane.confirmationText, "Delete “c.txt”?")
        h.escape()
        XCTAssertNil(h.pane.confirmationText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/c.txt"))

        // Return confirms; the cursor moves to the entry that took its index (F-53).
        h.key("d")
        XCTAssertEqual(h.pane.confirmationText, "Delete “c.txt”?")
        h.enter()
        try await h.wait("deleted") { h.statuses.contains("deleted c.txt") && h.pane.isIdle }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/c.txt"))
        XCTAssertEqual(h.pane.cursor, "b.md")

        // Folders get the longer question.
        h.key("k"); h.key("k"); h.key("k")
        XCTAssertEqual(h.pane.cursor, "sub")
        h.key("d")
        XCTAssertEqual(h.pane.confirmationText, "Delete folder “sub” and everything in it?")
        h.escape()
    }

    @MainActor
    func testWatchStreamAndUpload() async throws {
        let a = try await api() // first: starting the host empties its HOME
        let dir = try fixture()
        let h = PaneHarness(api: a, dir: dir)
        defer { h.close() }
        try await h.waitIdle()

        // An external change arrives through the watch stream (F-59).
        try await h.wait("watch ready") { h.pane.readyWatches.contains(dir) }
        try "new".write(toFile: "\(dir)/z.txt", atomically: true, encoding: .utf8)
        try await h.wait("watch delivered z.txt") { h.pane.listedNames(in: dir)?.contains("z.txt") ?? false }

        // Upload a local file and a folder (F-54/F-57).
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("wm-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local.appendingPathComponent("folder/in"), withIntermediateDirectories: true)
        try "payload".write(to: local.appendingPathComponent("up.bin"), atomically: true, encoding: .utf8)
        try "nested".write(to: local.appendingPathComponent("folder/in/n.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        h.pane.upload(urls: [local.appendingPathComponent("up.bin"), local.appendingPathComponent("folder")])
        XCTAssertEqual(h.statuses.last, "uploading 2 file(s)…")
        try await h.wait("uploaded") { h.statuses.contains("uploaded 2 file(s) → \(dir)") && h.pane.isIdle }
        XCTAssertEqual(h.pane.cursor, "folder") // the last upload's top-level entry
        XCTAssertEqual(try String(contentsOfFile: "\(dir)/up.bin", encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOfFile: "\(dir)/folder/in/n.txt", encoding: .utf8), "nested")
        XCTAssertTrue(h.pane.listedNames(in: dir)?.contains("up.bin") ?? false)

        // A collision is renamed Finder-style by the host.
        h.pane.upload(urls: [local.appendingPathComponent("up.bin")], toDir: dir)
        try await h.wait("second upload") { h.pane.cursor == "up (1).bin" && h.pane.isIdle }

        h.pane.upload(urls: [], toDir: dir)
        XCTAssertEqual(h.statuses.last, "nothing to upload")
    }

    @MainActor
    func testDownloadToATempFolder() async throws {
        let a = try await api()
        let dir = try fixture()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("wm-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let h = PaneHarness(api: a, dir: dir, cursor: "a.txt", downloadDir: out)
        defer { h.close() }
        try await h.wait("opened on a.txt") { h.pane.isIdle && h.pane.cursor == "a.txt" }

        // The save panel is replaced by a provider; it is offered the remembered folder.
        var offered: (String, URL)?
        h.pane.saveDestinationProvider = { name, initial in
            offered = (name, initial)
            return out.appendingPathComponent("saved-" + name)
        }
        h.key("D")
        XCTAssertEqual(h.statuses.last, "downloading a.txt")
        try await h.wait("saved") { h.logs.contains { $0.0 == "download saved" } && h.pane.isIdle }
        XCTAssertEqual(offered?.0, "a.txt")
        XCTAssertEqual(offered?.1.path, out.path)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("saved-a.txt"), encoding: .utf8), "hello\n")
        XCTAssertEqual(h.downloadDirs.last?.path, out.path)
        XCTAssertEqual(h.logs.first?.0, "download started")
        XCTAssertEqual(h.logs.last?.1["file"], "a.txt")
        XCTAssertEqual(h.logs.last?.1["bytes"], "6")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: out.path).contains { $0.contains(".webmux-part") })

        // Cancelled: nothing written, logged as cancelled.
        h.pane.saveDestinationProvider = { _, _ in nil }
        h.pane.download("\(dir)/b.md")
        try await h.wait("cancelled") { h.logs.contains { $0.0 == "download cancelled" } }

        // Shift+D on a directory: the toast.
        h.key("k"); h.key("k")
        XCTAssertEqual(h.pane.cursor, "sub")
        h.key("D")
        XCTAssertEqual(h.statuses.last, "select a file to download")

        // Without a dialog: straight into the remembered folder under a free name.
        h.pane.saveDestinationProvider = nil
        h.pane.askWhereToSave = false
        h.pane.download("\(dir)/a.txt")
        try await h.wait("saved twice") { h.logs.filter { $0.0 == "download saved" }.count == 2 && h.pane.isIdle }
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "hello\n")
    }

    @MainActor
    func testZipPreviewAndTruncatedColumnMessages() async throws {
        let a = try await api()
        let dir = try fixture()
        let zipStatus = try await Task.detached {
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = URL(fileURLWithPath: dir)
            zip.arguments = ["-q", "-r", "x.zip", "sub", "a.txt"]
            try zip.run()
            zip.waitUntilExit()
            return zip.terminationStatus
        }.value
        try XCTSkipUnless(zipStatus == 0, "zip not available")
        let h = PaneHarness(api: a, dir: dir, cursor: "x.zip")
        defer { h.close() }
        try await h.wait("zip preview") { h.pane.isIdle && h.pane.previewPath == "\(dir)/x.zip" && !h.pane.previewZipRows.isEmpty }
        let rows = h.pane.previewZipRows
        XCTAssertEqual(rows.map(\.name), ["sub/", "inner/", "d.txt", "a.txt"])
        XCTAssertEqual(rows.map(\.prefix), ["├── ", "│   └── ", "│       └── ", "└── "])
        XCTAssertTrue(h.pane.previewMetaText?.contains(" · 4 entries · ") ?? false, h.pane.previewMetaText ?? "nil")

        // A binary file: narrow column, the message.
        try await h.wait("watch ready") { h.pane.readyWatches.contains(dir) }
        try Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: "\(dir)/bin.dat"))
        try await h.wait("bin listed") { h.pane.listedNames(in: dir)?.contains("bin.dat") ?? false }
        h.key("k"); h.key("k") // from x.zip: bin.dat is before it (b.md, bin.dat, x.zip)? select by position
        try await h.waitIdle()
        var guardCount = 0
        while h.pane.cursor != "bin.dat", guardCount < 8 { h.key(h.pane.cursor.map { $0 < "bin.dat" } ?? true ? "j" : "k"); guardCount += 1 }
        XCTAssertEqual(h.pane.cursor, "bin.dat")
        try await h.wait("binary preview") { h.pane.isIdle && h.pane.previewBodyText == "binary file" }
        XCTAssertEqual(h.pane.previewIsNarrow, true)
        h.right()
        XCTAssertFalse(h.pane.isDrilled) // nothing to drill into (F-21)

        // An unreadable directory shows the host's error code (F-09).
        try FileManager.default.createDirectory(atPath: "\(dir)/locked", withIntermediateDirectories: true, attributes: [.posixPermissions: 0])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(dir)/locked") }
        try await h.wait("locked listed") { h.pane.listedNames(in: dir)?.contains("locked") ?? false }
        for _ in 0..<12 where h.pane.cursor != "locked" { h.key("k") }
        XCTAssertEqual(h.pane.cursor, "locked")
        try await h.wait("EACCES") { h.pane.columnMessage(for: "\(dir)/locked") == "EACCES" }
        XCTAssertEqual(h.pane.watchedDirectories, [dir]) // failed listings are not watched
    }

    @MainActor
    func testUnreachableHostShowsTransportErrorName() async throws {
        _ = try await api() // skip without the binary, like the others
        let h = PaneHarness(api: HostAPI(socketPath: "/tmp/wm-mac/none/h.sock", timeout: .seconds(2)), dir: "~")
        defer { h.close() }
        try await h.wait("open error") { h.pane.openError != nil }
        XCTAssertEqual(h.pane.openError, "socketNotFound")
        XCTAssertEqual(h.pane.columnMessage(for: "~"), "socketNotFound")
        XCTAssertFalse(h.pane.isOpened)
    }
}
