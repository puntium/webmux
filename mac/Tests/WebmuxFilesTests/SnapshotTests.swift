// A visual check, not an assertion: with WEBMUX_FILES_SNAPSHOT_DIR set, the
// pane is rendered to PNGs there (markdown preview, the delete
// confirmation, a directory cursor) for a look at the real layout.
import AppKit
import XCTest
import WebmuxHost
@testable import WebmuxFiles

final class SnapshotTests: XCTestCase {
    @MainActor
    func testRenderSnapshots() async throws {
        guard let out = ProcessInfo.processInfo.environment["WEBMUX_FILES_SNAPSHOT_DIR"], !out.isEmpty else {
            throw XCTSkip("set WEBMUX_FILES_SNAPSHOT_DIR to render the pane to PNGs")
        }
        let sock = try await Task.detached { try FilesTestHost.socketPath() }.value
        let api = HostAPI(socketPath: sock, timeout: .seconds(10))
        let dir = "\(FilesTestHost.home)/snap"
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(dir)/src/deep", withIntermediateDirectories: true)
        try "hello world\nline 2\n".write(toFile: "\(dir)/notes.txt", atomically: true, encoding: .utf8)
        try """
        # Project title

        Some *emphasis*, **strong**, `inline code` and a [link](https://example.com).

        - [ ] task one
        - [x] task two
        - plain bullet

        ```swift
        let x = 1
        ```

        | col a | col b |
        |---|---|
        | 1 | 2 |

        > A quote here.
        """.write(toFile: "\(dir)/README.md", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(dir)/.hidden", atomically: true, encoding: .utf8)
        try "deep".write(toFile: "\(dir)/src/deep/d.txt", atomically: true, encoding: .utf8)
        let h = PaneHarness(api: api, dir: dir, cursor: "README.md")
        defer { h.close() }
        h.window.setContentSize(NSSize(width: 1200, height: 500))
        try await h.wait("md") { h.pane.isIdle && (h.pane.previewBodyText?.hasPrefix("Project title") ?? false) }
        try await Task.sleep(for: .milliseconds(600))
        try snapshot(h.pane, to: "\(out)/files-markdown.png")
        h.key("d")
        try await Task.sleep(for: .milliseconds(200))
        try snapshot(h.pane, to: "\(out)/files-confirm.png")
        h.escape()
        h.key("k"); h.key("k"); h.key("k")
        try await h.wait("src") { h.pane.isIdle && h.pane.cursor == "src" }
        try await Task.sleep(for: .milliseconds(600))
        try snapshot(h.pane, to: "\(out)/files-directory.png")
    }

    private func snapshot(_ v: NSView, to path: String) throws {
        v.window?.layoutIfNeeded()
        v.window?.displayIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
