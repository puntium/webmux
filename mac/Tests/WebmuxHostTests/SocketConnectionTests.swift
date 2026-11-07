import Darwin
import XCTest
@testable import WebmuxHost

final class SocketConnectionTests: XCTestCase {
    func testConnectWriteReadInterrupt() async throws {
        // A tiny echo peer on a listening unix socket.
        let server = FakeServer { peer in
            let d = peer.read(exactly: 5)
            peer.write(d)
            peer.write("world\n")
            peer.shutdownWrite()
            Thread.sleep(forTimeInterval: 0.3)
            peer.close()
        }
        defer { server.stop() }
        let c = try SocketConnection.connect(path: server.path)
        defer { c.close() }
        try await c.writeAll(Data("hello".utf8), deadline: .after(.seconds(2)))
        await XCTAssertEqualAsync(try await c.readExact(5, deadline: .after(.seconds(2))), Data("hello".utf8))
        await XCTAssertEqualAsync(try await c.readLine(max: 100, deadline: .after(.seconds(2))), Data("world".utf8))
        // The peer has closed: a read returns EOF, and after interrupt()
        // every operation fails with cancelled.
        await XCTAssertEqualAsync(try await c.readSome(max: 10, deadline: .after(.seconds(2))), Data())
        c.interrupt()
        await assertThrows(.cancelled) { try await c.readSome(max: 10, deadline: .after(.seconds(2))) }
        await assertThrows(.cancelled) { try await c.writeAll(Data("x".utf8), deadline: .after(.seconds(2))) }
    }

    func testReadDeadlineThenReusable() async throws {
        let (c, peer) = Peer.pair()
        defer { c.close(); peer.close() }
        let t0 = DispatchTime.now()
        await assertThrows(.timeout) { try await c.readSome(max: 10, deadline: .after(.milliseconds(100))) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssert(ms >= 90 && ms < 1000, "took \(ms) ms")
        // A timed-out connection is still usable.
        peer.write("later\n")
        await XCTAssertEqualAsync(try await c.readLine(max: 100, deadline: .after(.seconds(2))), Data("later".utf8))
        // readLine: a partial last line at EOF is returned as is; then nil.
        peer.write("tail")
        peer.shutdownWrite()
        await XCTAssertEqualAsync(try await c.readLine(max: 100, deadline: .after(.seconds(2))), Data("tail".utf8))
        await XCTAssertEqualAsync(try await c.readLine(max: 100, deadline: .after(.seconds(2))), nil)
    }

    func testInterruptWakesABlockedReaderPromptly() async throws {
        let (c, peer) = Peer.pair()
        defer { c.close(); peer.close() }
        let reader = Task { () -> HostError? in
            do {
                _ = try await c.readExact(1, deadline: .never)
                return nil
            } catch let e as HostError {
                return e
            } catch { return nil }
        }
        try await Task.sleep(for: .milliseconds(50))
        let t0 = DispatchTime.now()
        c.interrupt()
        let result = await reader.value
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssertEqual(result, .cancelled)
        XCTAssert(ms < 500, "took \(ms) ms")
    }

    func testTaskCancellationWakesABlockedReader() async throws {
        let (c, peer) = Peer.pair()
        defer { c.close(); peer.close() }
        let reader = Task { () -> HostError? in
            do {
                _ = try await c.readExact(1, deadline: .never)
                return nil
            } catch let e as HostError {
                return e
            } catch { return nil }
        }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        let result = await reader.value
        XCTAssertEqual(result, .cancelled)
        // The connection itself is still usable after a Task cancellation.
        peer.write("x")
        await XCTAssertEqualAsync(try await c.readExact(1, deadline: .after(.seconds(1))), Data("x".utf8))
    }

    func testLineTooLongAndLongLinesAcrossFills() async throws {
        let (c, peer) = Peer.pair()
        defer { c.close(); peer.close() }
        peer.write(String(repeating: "a", count: 200) + "\n")
        await assertThrows(.protocolViolation(.lineTooLong)) { try await c.readLine(max: 100, deadline: .after(.seconds(1))) }
        // A line longer than one read but shorter than the buffer.
        let (c2, peer2) = Peer.pair()
        defer { c2.close(); peer2.close() }
        let long = String(repeating: "b", count: 50_000)
        Thread.detachNewThread { peer2.write(long + "\r\nnext\n") }
        await XCTAssertEqualAsync(try await c2.readLine(max: 60_000, deadline: .after(.seconds(2))), Data(long.utf8))
        await XCTAssertEqualAsync(try await c2.readLine(max: 60_000, deadline: .after(.seconds(2))), Data("next".utf8))
    }

    func testConnectErrors() async throws {
        await assertThrows(.socketNotFound(path: "/tmp/wm-mac/does-not-exist.sock")) {
            try SocketConnection.connect(path: "/tmp/wm-mac/does-not-exist.sock")
        }
        let long = "/tmp/" + String(repeating: "x", count: 120)
        await assertThrows(.nameTooLong(path: long)) { try SocketConnection.connect(path: long) }
        // A bound but not listening socket refuses.
        let dir = "/tmp/wm-mac/t-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/refused.sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        defer { close(fd); unlink(path) }
        await assertThrows(.connectionRefused(path: path)) { try SocketConnection.connect(path: path) }
    }

    func testWriteBackpressureAndBrokenPipe() async throws {
        let (c, peer) = Peer.pair()
        defer { c.close(); peer.close() }
        // 4 MiB: far more than the socket buffer; the peer drains slowly.
        let big = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let drained = Thread {
            var got = 0
            while got < big.count {
                let d = peer.readSome(timeout: 5)
                if d.isEmpty { break }
                got += d.count
            }
            XCTAssertEqual(got, big.count)
        }
        drained.start()
        try await c.writeAll(big, deadline: .after(.seconds(10)))
        while !drained.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        peer.close()
        // Writes into a closed peer: EPIPE (no SIGPIPE), or a reset.
        do {
            for _ in 0..<64 { try await c.writeAll(Data(repeating: 0, count: 65536), deadline: .after(.seconds(2))) }
            XCTFail("expected a failure")
        } catch let e as HostError {
            XCTAssert(e == .brokenPipe || e == .connectionReset, "\(e)")
        }
    }
}
