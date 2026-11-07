// Tests against a real, isolated webmux host (see TestHost.swift). Skipped
// when the host binary cannot be found. Port of the fork's test_live.zig.
import XCTest
@testable import WebmuxHost

final class LiveTests: XCTestCase {
    override class func tearDown() {
        TestHost.stop()
        super.tearDown()
    }

    private func host() throws -> (api: HostAPI, socket: String) {
        let sock = try TestHost.socketPath()
        return (HostAPI(socketPath: sock, timeout: .seconds(10)), sock)
    }

    private func tempDir(_ name: String) throws -> String {
        let p = "\(TestHost.home)/\(name)-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testHealthCreateListDelete() async throws {
        let (api, _) = try host()
        let h = try await api.health(timeout: .seconds(2))
        XCTAssertTrue(h.ok)
        XCTAssertEqual(h.server, "webmux")
        XCTAssertEqual(h.ptyhost, TestHost.name)

        let id = try await api.sessions.create(cols: 100, rows: 30)
        let list = try await api.sessions.list()
        let mine = list.first { $0.id == id }
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.cols, 100)
        XCTAssertEqual(mine?.rows, 30)
        XCTAssertEqual(mine?.clients, 0)
        XCTAssert((mine?.pid ?? 0) > 0)
        XCTAssert((mine?.createdAt ?? 0) > 1_600_000_000_000)

        try await api.sessions.delete(id: id)
        do {
            try await api.sessions.delete(id: id)
            XCTFail("expected 404")
        } catch let HostError.httpStatus(status, message) {
            XCTAssertEqual(status, 404)
            XCTAssertFalse(message.isEmpty)
        }

        // 404 route, buffered.
        let r = try await api.client.fetch(HTTPRequest(.GET, "/nope"))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.head.header("Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"error\":\"not found\"}")

        // POST /log is the Electron client's own route; the host has none.
        await assertThrows(.httpStatus(status: 404, message: "not found")) {
            try await api.log([LogEntry(level: "info", msg: "hello")])
        }
    }

    /// Read frames until the accumulated output contains `needle`.
    private func readUntil(_ it: inout AsyncThrowingStream<WebSocketMessage, Error>.Iterator, _ acc: inout String, _ needle: String) async throws {
        while !acc.contains(needle) {
            guard let m = try await it.next() else { throw HostError.endOfStream }
            guard case .text(let t) = m else { continue }
            if case .output(let d) = try ServerFrame(json: t) { acc += d }
        }
    }

    func testWebSocketAttachInputOutputResizeExit() async throws {
        let (api, _) = try host()
        let id = try await api.sessions.create(cols: 80, rows: 24)
        let ws = try await api.sessions.attach(id: id)
        defer { Task { await ws.shutdown() } }
        var it = ws.messages.makeAsyncIterator()

        guard case .text(let first) = try await it.next() else { return XCTFail("no snapshot") }
        guard case .snapshot(let snap) = try ServerFrame(json: first) else { return XCTFail("first frame is not a snapshot: \(first)") }
        XCTAssertEqual(snap.cols, 80)
        XCTAssertEqual(snap.rows, 24)
        XCTAssert((snap.pid ?? 0) > 0)

        var acc = ""
        try await ws.sendText(ClientFrame.input("echo wm-$((6*7)) é\n").wire)
        try await readUntil(&it, &acc, "wm-42 é")

        try await ws.sendText(ClientFrame.resize(cols: 132, rows: 40).wire)
        try await ws.sendText(ClientFrame.input("stty size\n").wire)
        try await readUntil(&it, &acc, "40 132")
        let listed = try await api.sessions.list().first { $0.id == id }
        XCTAssertEqual(listed?.cols, 132)
        XCTAssertEqual(listed?.clients, 1)

        try await ws.ping(Data("x".utf8))
        try await ws.sendText(ClientFrame.input("exit 7\n").wire)
        var sawExit = false
        var ending: String?
        do {
            while let m = try await it.next() {
                switch m {
                case .text(let t):
                    if case .exit(let code) = try ServerFrame(json: t) {
                        XCTAssertEqual(code, 7)
                        sawExit = true
                    }
                case .binary:
                    XCTFail("unexpected binary frame")
                case .close(let code, _):
                    // The host closes the socket with 1000 after the exit frame (P-22).
                    XCTAssertEqual(code, 1000)
                    ending = "close"
                }
            }
        } catch let e as HostError {
            XCTAssert(e == .endOfStream || e == .connectionReset, "\(e)")
            ending = "eof"
        }
        XCTAssertTrue(sawExit)
        XCTAssertEqual(ending, "close")
    }

    func testMissingSessionGetsAnErrorFrame() async throws {
        let (_, sock) = try host()
        let ws = try await WebSocketClient.connect(socketPath: sock, target: "/ws?session=nope")
        defer { Task { await ws.shutdown() } }
        var it = ws.messages.makeAsyncIterator()
        guard case .text(let t) = try await it.next() else { return XCTFail("no frame") }
        XCTAssertEqual(try ServerFrame(json: t), .error(message: "no such session"))
    }

    func testUpgradeOnAWrongPathIsRejected() async throws {
        let (_, sock) = try host()
        await assertThrows(.protocolViolation(.upgradeRejected(status: 400))) {
            try await WebSocketClient.connect(socketPath: sock, target: "/nope")
        }
    }

    func testInterruptWakesABlockedReaderPromptly() async throws {
        let (api, _) = try host()
        let id = try await api.sessions.create(cols: 80, rows: 24)
        defer { Task { try? await api.sessions.delete(id: id) } }
        for _ in 0..<5 {
            let ws = try await api.sessions.attach(id: id)
            var it = ws.messages.makeAsyncIterator()
            _ = try await it.next() // snapshot
            let reader = Task { () -> HostError? in
                do {
                    while try await it.next() != nil {}
                    return nil
                } catch let e as HostError { return e } catch { return nil }
            }
            try await Task.sleep(for: .milliseconds(50))
            let t0 = DispatchTime.now()
            ws.interrupt()
            let result = await reader.value
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            XCTAssertEqual(result, .cancelled)
            XCTAssert(ms < 500, "took \(ms) ms")
            // Sends after interrupt fail cleanly.
            await assertThrows(.cancelled) { try await ws.sendText("{}") }
            await ws.shutdown()
        }
    }

    func testFilesListPreviewUploadRawRenameDelete() async throws {
        let (api, _) = try host()
        let dir = try tempDir("fs")
        try "hello\n".write(toFile: "\(dir)/b.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(dir)/sub", withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: "\(dir)/a.bin"))

        // List: directories first, then names; `~` is the host's HOME.
        let listing = try await api.files.list(path: dir)
        XCTAssertEqual(listing.path, dir)
        XCTAssertEqual(listing.entries.map(\.name), ["sub", "a.bin", "b.txt"])
        XCTAssertEqual(listing.entries.map(\.kind), [.dir, .file, .file])
        XCTAssertFalse(listing.truncated)
        await XCTAssertEqualAsync(try await api.files.list(path: "~").path, TestHost.home)
        await XCTAssertEqualAsync(try await api.files.list().path, TestHost.home)
        await assertThrows(.httpStatus(status: 400, message: "ENOENT")) { try await api.files.list(path: "\(dir)/nope") }
        await assertThrows(.httpStatus(status: 400, message: "ENOTDIR")) { try await api.files.list(path: "\(dir)/b.txt") }

        // Preview: text, binary, other.
        let text = try await api.files.preview(path: "\(dir)/b.txt")
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.content, "hello\n")
        XCTAssertEqual(text.size, 6)
        XCTAssertFalse(text.truncated)
        XCTAssert(text.mtime > 1.6e12)
        await XCTAssertEqualAsync(try await api.files.preview(path: "\(dir)/a.bin").kind, .binary)
        await XCTAssertEqualAsync(try await api.files.preview(path: "\(dir)/sub").kind, .other)

        // Upload (raw body: bytes, chunked stream, file) + raw round trip.
        var big = Data(count: 3 * 1024 * 1024 + 17)
        for i in 0..<big.count { big[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 13)) }
        await XCTAssertEqualAsync(try await api.files.upload(dir: dir, name: "up-len.bin", body: .bytes(big)), "up-len.bin")
        let chunks = AsyncThrowingStream<Data, Error> { c in
            var off = 0
            while off < big.count { let n = min(65_536, big.count - off); c.yield(big[off..<off + n]); off += n }
            c.finish()
        }
        await XCTAssertEqualAsync(try await api.files.upload(dir: dir, name: "up-chunked.bin", body: .stream(chunks, length: nil)), "up-chunked.bin")
        let local = URL(fileURLWithPath: "\(dir)/local.bin")
        try big.write(to: local)
        // Dedupe: the basename gets " (1)"; intermediate directories are created.
        await XCTAssertEqualAsync(try await api.files.upload(file: local, toDir: dir, name: "up-len.bin"), "up-len (1).bin")
        await XCTAssertEqualAsync(try await api.files.upload(file: local, toDir: dir, name: "deep/er/x.bin"), "deep/er/x.bin")
        await assertThrows(.httpStatus(status: 400, message: "invalid name")) {
            try await api.files.upload(dir: dir, name: "../x", body: .bytes(Data()))
        }
        for name in ["up-len.bin", "up-chunked.bin", "up-len (1).bin", "deep/er/x.bin"] {
            let s = try await api.files.raw(path: "\(dir)/\(name)")
            XCTAssertEqual(s.head.header("content-type"), "application/octet-stream")
            XCTAssertEqual(s.head.contentLength, Int64(big.count))
            var got = Data()
            for try await chunk in s.chunks { got.append(chunk) }
            s.close()
            XCTAssertEqual(got, big, name)
        }
        let dl = URL(fileURLWithPath: "\(dir)/downloaded.bin")
        await XCTAssertEqualAsync(try await api.files.download(path: "\(dir)/up-len.bin", to: dl), Int64(big.count))
        XCTAssertEqual(try Data(contentsOf: dl), big)
        let att = try await api.files.raw(path: "\(dir)/b.txt", download: true)
        XCTAssertEqual(att.head.header("content-disposition"), "attachment; filename=\"b.txt\"; filename*=UTF-8''b.txt")
        await XCTAssertEqualAsync(try await att.readAll(), Data("hello\n".utf8))
        att.close()
        await assertThrows(.httpStatus(status: 400, message: "not a file")) { try await api.files.raw(path: "\(dir)/sub") }
        await assertThrows(.httpStatus(status: 400, message: "ENOENT")) { try await api.files.raw(path: "\(dir)/nope") }

        // Rename and delete.
        await XCTAssertEqualAsync(try await api.files.rename(path: "\(dir)/b.txt", name: "c.txt"), "c.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/c.txt"))
        await assertThrows(.httpStatus(status: 400, message: "name already taken")) { try await api.files.rename(path: "\(dir)/c.txt", name: "a.bin") }
        await assertThrows(.httpStatus(status: 400, message: "invalid name")) { try await api.files.rename(path: "\(dir)/c.txt", name: "x/y") }
        try await api.files.delete(path: "\(dir)/deep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/deep"))
        await assertThrows(.httpStatus(status: 400, message: "ENOENT")) { try await api.files.delete(path: "\(dir)/deep") }
        await assertThrows(.httpStatus(status: 400, message: "refusing to delete that")) { try await api.files.delete(path: "~") }
        try await api.files.delete(path: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testWatchSeesCreatedFileThenGoneAndIdleTimeout() async throws {
        let (api, _) = try host()
        let wdir = try tempDir("w")
        // SSE: ready, idle timeout while nothing happens, change on a new
        // file, gone when the directory vanishes, then the stream ends.
        let watch = try await api.files.watch(path: wdir, idleTimeout: .milliseconds(300))
        defer { watch.close() }
        await XCTAssertEqualAsync(try await watch.next().map(WatchEvent.init), WatchEvent(kind: .ready, path: wdir))
        await assertThrows(.timeout) { try await watch.next() }
        // A timed-out reader is still usable with a longer deadline.
        watch.idleTimeout = .seconds(5)
        try "x".write(toFile: "\(wdir)/x", atomically: true, encoding: .utf8)
        await XCTAssertEqualAsync(try await watch.next().map(WatchEvent.init), WatchEvent(kind: .change, path: wdir))
        try FileManager.default.removeItem(atPath: wdir)
        var gone = false
        while let ev = try await watch.next() {
            if WatchEvent(ev).kind == .gone { gone = true; break }
        }
        XCTAssertTrue(gone)
        await XCTAssertNilAsync(try await watch.next())

        // The decoded stream form.
        let wdir2 = try tempDir("w2")
        let watch2 = try await api.files.watch(path: wdir2)
        var kinds: [WatchEvent.Kind] = []
        for try await ev in watch2.watchEvents {
            kinds.append(ev.kind)
            if ev.kind == .ready { try "y".write(toFile: "\(wdir2)/y", atomically: true, encoding: .utf8) }
            if ev.kind == .change { try FileManager.default.removeItem(atPath: wdir2) }
        }
        XCTAssertEqual(kinds.prefix(2), [.ready, .change])
        XCTAssertEqual(kinds.last, .gone)
        watch2.close()

        // A request timeout: the watch stream never ends, so a buffered
        // fetch of it must time out at its deadline.
        let t0 = DispatchTime.now()
        await assertThrows(.timeout) { try await api.client.fetch(HTTPRequest(.GET, "/api/fs/watch?path=%7E", timeout: .milliseconds(300))) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssert(ms >= 290 && ms < 1500, "took \(ms) ms")

        // A socket that does not exist.
        await assertThrows(.socketNotFound(path: "/tmp/wm-does-not-exist/h.sock")) {
            try await HostAPI(socketPath: "/tmp/wm-does-not-exist/h.sock", timeout: .seconds(2)).health()
        }
    }

    func testPasteWritesAFile() async throws {
        let (api, _) = try host()
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let path = try await api.paste(mime: "image/png", data: png)
        XCTAssertTrue(path.hasSuffix(".png"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        await assertThrows(.httpStatus(status: 400, message: "expected { mime: image/*, data: base64 }")) {
            try await api.paste(mime: "text/plain", data: Data())
        }
    }
}
