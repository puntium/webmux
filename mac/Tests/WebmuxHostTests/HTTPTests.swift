import XCTest
@testable import WebmuxHost

final class HTTPTests: XCTestCase {
    func testPercentEncode() {
        XCTAssertEqual(percentEncode("a b/~é?"), "a%20b%2F~%C3%A9%3F")
        XCTAssertEqual(httpTarget("/api/fs/list", query: [("path", "~")]), "/api/fs/list?path=~")
        XCTAssertEqual(httpTarget("/api/fs/upload", query: [("dir", "/a b"), ("name", "x&y")]), "/api/fs/upload?dir=%2Fa%20b&name=x%26y")
        XCTAssertEqual(httpTarget("/x"), "/x")
    }

    func testParseHead() throws {
        let h = try parseHead(["HTTP/1.1 404 Not Found", "Content-Type: application/json", "X-A:  b  ", "Connection: keep-alive, Upgrade"])
        XCTAssertEqual(h.status, 404)
        XCTAssertEqual(h.reason, "Not Found")
        XCTAssertEqual(h.header("content-type"), "application/json")
        XCTAssertEqual(h.header("x-a"), "b")
        XCTAssertTrue(h.headerHasToken("connection", "upgrade"))
        XCTAssertFalse(h.headerHasToken("connection", "close"))
        XCTAssertFalse(h.isSuccess)
        XCTAssertEqual(try parseHead(["HTTP/1.0 200"]).reason, "")
        XCTAssertThrowsError(try parseHead(["HTTX/1.1 200 OK"]))
        XCTAssertThrowsError(try parseHead(["HTTP/1.1 abc OK"]))
        XCTAssertThrowsError(try parseHead(["HTTP/1.1 200 OK", "no colon"]))
    }

    private func fetch(_ response: String, method: HTTPMethod = .GET, maxBody: Int = 64 * 1024 * 1024) async throws -> (HTTPResponse, String) {
        let seen = Locked("")
        let server = FakeServer { peer in
            seen.value = readRequestHead(peer)
            peer.write(response)
            peer.close()
        }
        defer { server.stop() }
        var req = HTTPRequest(method, "/x?y=1", timeout: .seconds(5))
        req.maxBody = maxBody
        let r = try await UnixHTTPClient(socketPath: server.path).fetch(req)
        return (r, seen.value)
    }

    func testFetchContentLengthBody() async throws {
        let (r, req) = try await fetch("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"ok\":true}")
        XCTAssertTrue(req.hasPrefix("GET /x?y=1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"))
        struct T: Decodable { var ok: Bool }
        XCTAssertEqual(try r.json(T.self).ok, true)
    }

    func testFetchChunkedBodyWithExtensionsAndTrailers() async throws {
        let (r, _) = try await fetch("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n7\r\n, world\r\n0\r\nX-Trailer: 1\r\n\r\n")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello, world")
    }

    func testFetchReadToEOFAnd204() async throws {
        let (r, _) = try await fetch("HTTP/1.1 200 OK\r\n\r\nraw until close")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "raw until close")
        let (r2, req2) = try await fetch("HTTP/1.1 204 No Content\r\nContent-Length: 99\r\n\r\n", method: .POST)
        XCTAssertEqual(r2.status, 204)
        XCTAssertEqual(r2.body, Data())
        XCTAssertTrue(req2.contains("Content-Length: 0\r\n"), req2) // POST without a body
    }

    func testFetchErrors() async throws {
        await assertThrows(.endOfStream) { try await fetch("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort") }
        await assertThrows(.protocolViolation(.invalidResponse)) { try await fetch("SMTP 220 hi\r\n\r\n") }
        await assertThrows(.protocolViolation(.invalidResponse)) { try await fetch("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n") }
        await assertThrows(.bodyTooLarge) { try await fetch("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n" + String(repeating: "x", count: 100), maxBody: 10) }
        await assertThrows(.bodyTooLarge) { try await fetch("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 100), maxBody: 10) }
        await assertThrows(.protocolViolation(.headTooLarge)) { try await fetch("HTTP/1.1 200 OK\r\nX: " + String(repeating: "h", count: 70_000) + "\r\n\r\n") }
        await assertThrows(.endOfStream) { try await fetch("") }
    }

    func testFetchTimeoutCoversTheWholeExchange() async throws {
        // A server that answers the head and then stalls.
        let server = FakeServer { peer in
            _ = readRequestHead(peer)
            peer.write("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhal")
            Thread.sleep(forTimeInterval: 2)
            peer.close()
        }
        defer { server.stop() }
        let t0 = DispatchTime.now()
        await assertThrows(.timeout) {
            try await UnixHTTPClient(socketPath: server.path).fetch(HTTPRequest(.GET, "/", timeout: .milliseconds(300)))
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        XCTAssert(ms >= 290 && ms < 1500, "took \(ms) ms")
    }

    func testRequestBodiesBytesFileStreamAndChunked() async throws {
        let received = Locked((head: "", body: Data()))
        let server = FakeServer { peer in
            received.value = readRequest(peer)
            peer.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            peer.close()
        }
        defer { server.stop() }
        let client = UnixHTTPClient(socketPath: server.path)
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })

        // Bytes.
        var r = try await client.fetch(HTTPRequest(.POST, "/u", contentType: "application/octet-stream", body: .bytes(payload), timeout: .seconds(5)))
        XCTAssertEqual(r.status, 200)
        var text = received.value.head
        XCTAssertTrue(text.contains("Content-Length: 100000\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/octet-stream\r\n"), text)
        XCTAssertEqual(received.value.body, payload)

        // File.
        let url = URL(fileURLWithPath: "/tmp/wm-mac/t-\(getpid())/body.bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        r = try await client.fetch(HTTPRequest(.POST, "/u", body: .file(url), timeout: .seconds(5)))
        XCTAssertEqual(received.value.body, payload)
        XCTAssertTrue(received.value.head.contains("Content-Length: 100000\r\n"))

        // Stream with a length.
        let chunks = { () -> AsyncThrowingStream<Data, Error> in
            AsyncThrowingStream { c in
                var off = 0
                while off < payload.count {
                    let n = min(7777, payload.count - off)
                    c.yield(payload[off..<off + n])
                    off += n
                }
                c.finish()
            }
        }
        r = try await client.fetch(HTTPRequest(.POST, "/u", body: .stream(chunks(), length: Int64(payload.count)), timeout: .seconds(5)))
        XCTAssertEqual(received.value.body, payload)

        // Chunked stream: decode what the server saw.
        r = try await client.fetch(HTTPRequest(.POST, "/u", body: .stream(chunks(), length: nil), timeout: .seconds(5)))
        text = received.value.head
        XCTAssertTrue(text.contains("Transfer-Encoding: chunked\r\n"), text)
        XCTAssertEqual(try dechunk(received.value.body), payload)
        XCTAssertEqual(r.status, 200)

        // Length mismatch.
        await assertThrows(.bodyLengthMismatch) {
            try await client.fetch(HTTPRequest(.POST, "/u", body: .stream(chunks(), length: 5), timeout: .seconds(5)))
        }
        await assertThrows(.readFailed(url.path + "x")) {
            try await client.fetch(HTTPRequest(.POST, "/u", body: .file(URL(fileURLWithPath: url.path + "x")), timeout: .seconds(5)))
        }
    }

    /// Decode a chunked body (test-side).
    private func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var rest = data
        while true {
            guard let eol = rest.range(of: Data("\r\n".utf8)) else { throw HostError.protocolViolation(.invalidResponse) }
            let size = Int(String(decoding: rest[rest.startIndex..<eol.lowerBound], as: UTF8.self), radix: 16)!
            rest = rest[eol.upperBound...]
            if size == 0 { return out }
            out.append(rest.prefix(size))
            rest = rest.dropFirst(size + 2)
        }
    }

    func testOpenStreamsTheBodyAndDownloadWritesAFile() async throws {
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let server = FakeServer { peer in
            _ = readRequestHead(peer)
            peer.write("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nContent-Type: application/octet-stream\r\n\r\n")
            peer.write(payload)
            peer.close()
        }
        defer { server.stop() }
        let client = UnixHTTPClient(socketPath: server.path)

        let s = try await client.open(HTTPRequest(.GET, "/raw", timeout: .seconds(5), idleTimeout: .seconds(5)))
        XCTAssertEqual(s.head.status, 200)
        var got = Data()
        for try await chunk in s.chunks { got.append(chunk) }
        XCTAssertEqual(got, payload)
        s.close()

        let url = URL(fileURLWithPath: "/tmp/wm-mac/t-\(getpid())/dl.bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let head = try await client.download(HTTPRequest(.GET, "/raw", timeout: .seconds(5)), to: url)
        XCTAssertEqual(head.contentLength, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testOpenIdleTimeoutThenReusable() async throws {
        let server = FakeServer { peer in
            _ = readRequestHead(peer)
            peer.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            Thread.sleep(forTimeInterval: 0.5)
            peer.write("3\r\nabc\r\n0\r\n\r\n")
            peer.close()
        }
        defer { server.stop() }
        let s = try await UnixHTTPClient(socketPath: server.path).open(HTTPRequest(.GET, "/", timeout: .seconds(5), idleTimeout: .milliseconds(100)))
        defer { s.close() }
        await assertThrows(.timeout) { try await s.read() }
        s.idleTimeout = .seconds(5)
        await XCTAssertEqualAsync(try await s.read(), Data("abc".utf8))
        await XCTAssertEqualAsync(try await s.read(), Data())
        await XCTAssertEqualAsync(try await s.read(), Data())
    }

    func testConnectErrorsSurfaceFromTheClient() async throws {
        await assertThrows(.socketNotFound(path: "/tmp/wm-does-not-exist/h.sock")) {
            try await UnixHTTPClient(socketPath: "/tmp/wm-does-not-exist/h.sock").fetch(HTTPRequest(.GET, "/"))
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
