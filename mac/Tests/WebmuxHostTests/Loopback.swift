// Test helpers: a socketpair peer and a tiny unix-socket server, so the
// HTTP, SSE and WebSocket layers can be exercised without a host.
import Darwin
import Foundation
import XCTest
@testable import WebmuxHost

/// The other end of a `socketpair`, or an accepted connection: blocking reads
/// and writes from the test.
final class Peer: @unchecked Sendable {
    let fd: Int32
    private var closed = false
    /// The socket was already fully shut down when adopted (the client closed
    /// before `accept` dequeued it). XNU then refuses every setsockopt and
    /// fcntl with EINVAL, so SIGPIPE cannot be suppressed on it: never write.
    private let dead: Bool

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        dead = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) != 0
    }

    /// A connected (SocketConnection, Peer) pair.
    static func pair() -> (SocketConnection, Peer) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (SocketConnection(fd: fds[0]), Peer(fd: fds[1]))
    }

    /// Write everything; false when the other side is gone.
    @discardableResult
    func write(_ data: Data) -> Bool {
        if dead { return false }
        var off = 0
        return data.withUnsafeBytes { raw in
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    @discardableResult
    func write(_ s: String) -> Bool { write(Data(s.utf8)) }

    /// Exactly `count` bytes (blocking), or fewer at EOF.
    func read(exactly count: Int) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, count - out.count) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Whatever arrives within `timeout` (a single read), empty on EOF or timeout.
    func readSome(timeout: Double = 2) -> Data {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return Data() }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 65536) }
        return n > 0 ? Data(buf[0..<n]) : Data()
    }

    func shutdownWrite() { _ = Darwin.shutdown(fd, SHUT_WR) }

    func close() {
        if !closed { closed = true; Darwin.close(fd) }
    }

    deinit { close() }
}

/// A unix-socket server on a short path under /tmp/wm-mac/, serving one
/// connection at a time with `handler` (the full request bytes until the
/// blank line, or until EOF for bodies → the bytes to answer; nil keeps the
/// connection open silently until the client gives up).
///
/// The accept thread owns the listening descriptor and closes it when it
/// exits: on Darwin `close()` does not wake a thread blocked in `accept()`,
/// so a server closed from the test would keep accepting on a descriptor
/// number the next test's server reuses (stealing its connections), and a
/// second close from `deinit` would hit whatever socket got that number
/// (then written without SO_NOSIGPIPE → SIGPIPE). The loop polls with a
/// short timeout and leaves when `stop()` has been called.
final class FakeServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let thread: Thread
    private let handler: @Sendable (Peer) -> Void
    private let stopped = Locked(false)

    init(_ handler: @escaping @Sendable (Peer) -> Void) {
        let dir = "/tmp/wm-mac/t-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = "\(dir)/\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        listenFD = fd
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(rc == 0, "bind failed: \(errno)")
        precondition(listen(fd, 8) == 0)
        self.handler = handler
        let stopped = self.stopped
        thread = Thread {
            defer { Darwin.close(fd) }
            while !stopped.value {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 50)
                if ready < 0 && errno != EINTR { return }
                if ready <= 0 { continue }
                let c = accept(fd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return
                }
                handler(Peer(fd: c))
            }
        }
        thread.start()
    }

    /// Ask the accept thread to leave (it closes the socket itself) and
    /// remove the path. Idempotent: `defer { server.stop() }` and `deinit`
    /// both call it.
    func stop() {
        if stopped.value { return }
        stopped.value = true
        unlink(path)
    }

    deinit { stop() }
}

/// Read an HTTP request head from `peer` (blocking); the bytes before and
/// including the blank line.
func readRequestHead(_ peer: Peer) -> String {
    var buf = Data()
    while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
        let d = peer.readSome(timeout: 5)
        if d.isEmpty { break }
        buf.append(d)
    }
    return String(decoding: buf, as: UTF8.self)
}

/// `XCTAssertEqual` for async expressions.
func XCTAssertEqualAsync<T: Equatable>(_ e1: @autoclosure () async throws -> T, _ e2: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let a = try await e1()
        let b = try await e2()
        XCTAssertEqual(a, b, message, file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message)", file: file, line: line)
    }
}

func XCTAssertNilAsync<T>(_ e: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let a = try await e()
        XCTAssertNil(a, message, file: file, line: line)
    } catch {
        XCTFail("threw \(error) \(message)", file: file, line: line)
    }
}

/// Read a whole HTTP request from `peer`: the head, and the body framed by
/// Content-Length or chunked encoding (the client never half-closes).
func readRequest(_ peer: Peer) -> (head: String, body: Data) {
    var buf = Data()
    var headEnd: Range<Data.Index>?
    while headEnd == nil {
        let d = peer.readSome(timeout: 5)
        if d.isEmpty { return (String(decoding: buf, as: UTF8.self), Data()) }
        buf.append(d)
        headEnd = buf.range(of: Data("\r\n\r\n".utf8))
    }
    let head = String(decoding: buf[..<headEnd!.upperBound], as: UTF8.self)
    var body = Data(buf[headEnd!.upperBound...])
    let lower = head.lowercased()
    if let r = lower.range(of: "content-length:") {
        let n = Int(lower[r.upperBound...].split(separator: "\r\n")[0].trimmingCharacters(in: .whitespaces)) ?? 0
        while body.count < n {
            let d = peer.readSome(timeout: 5)
            if d.isEmpty { break }
            body.append(d)
        }
    } else if lower.contains("transfer-encoding: chunked") {
        while body.range(of: Data("\r\n0\r\n\r\n".utf8)) == nil && body != Data("0\r\n\r\n".utf8) {
            let d = peer.readSome(timeout: 5)
            if d.isEmpty { break }
            body.append(d)
        }
    }
    return (head, body)
}

extension XCTestCase {
    /// `body` must throw exactly `expected`.
    func assertThrows<T>(_ expected: HostError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected), got no error", file: file, line: line)
        } catch let e as HostError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
