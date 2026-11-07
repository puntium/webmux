import XCTest
@testable import WebmuxHost

final class SSETests: XCTestCase {
    func testParserEventsCommentsMultiLineDataIdDefaultName() {
        var p = SSEParser()
        XCTAssertNil(p.line(": ping"))
        XCTAssertNil(p.line("event: ready"))
        XCTAssertNil(p.line("data: {\"path\":\"/x\"}"))
        XCTAssertEqual(p.line(""), ServerSentEvent(event: "ready", data: "{\"path\":\"/x\"}", id: nil))

        XCTAssertNil(p.line("id: 7"))
        XCTAssertNil(p.line("data:a"))
        XCTAssertNil(p.line("data: b"))
        XCTAssertEqual(p.line(""), ServerSentEvent(event: "message", data: "a\nb", id: "7"))

        // An event with no data is not dispatched.
        XCTAssertNil(p.line("event: nothing"))
        XCTAssertNil(p.line(""))
        XCTAssertNil(p.line("retry: 1500"))
        XCTAssertEqual(p.retryMilliseconds, 1500)
        // A field without a colon is a field with an empty value.
        XCTAssertNil(p.line("data"))
        XCTAssertEqual(p.line(""), ServerSentEvent(event: "message", data: "", id: "7"))
    }

    func testEventStreamOverHTTPWithMixedLineEndings() async throws {
        let server = FakeServer { peer in
            let head = readRequestHead(peer)
            XCTAssertTrue(head.contains("Accept: text/event-stream\r\n"), head)
            peer.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n")
            peer.write(": hello\n\nevent: ready\r\ndata: {\"path\":\"/w\"}\r\n\r")
            Thread.sleep(forTimeInterval: 0.1)
            peer.write("\nevent: change\rdata: 1\r\r")
            Thread.sleep(forTimeInterval: 0.1)
            peer.write("data: tail-without-blank-line")
            peer.close()
        }
        defer { server.stop() }
        let s = try await EventStream.open(UnixHTTPClient(socketPath: server.path), "/api/fs/watch?path=%2Fw", options: SSEOptions(timeout: .seconds(5), idleTimeout: .seconds(5)))
        defer { s.close() }
        await XCTAssertEqualAsync(try await s.next(), ServerSentEvent(event: "ready", data: "{\"path\":\"/w\"}"))
        await XCTAssertEqualAsync(try await s.next(), ServerSentEvent(event: "change", data: "1"))
        await XCTAssertNilAsync(try await s.next())
        XCTAssertEqual(WatchEvent(ServerSentEvent(event: "gone", data: "{\"path\":\"/w\",\"error\":\"ENOENT\"}")), WatchEvent(kind: .gone, path: "/w", error: "ENOENT"))
    }

    func testEventStreamRejectsNonEventStreams() async throws {
        let server = FakeServer { peer in
            _ = readRequestHead(peer)
            peer.write("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"error\":\"ENOENT\"}")
            peer.close()
        }
        defer { server.stop() }
        await assertThrows(.protocolViolation(.notAnEventStream(status: 400))) {
            try await EventStream.open(UnixHTTPClient(socketPath: server.path), "/api/fs/watch", options: SSEOptions(timeout: .seconds(5)))
        }
    }

    func testEventStreamIdleTimeoutThenReusableAndAsStream() async throws {
        let server = FakeServer { peer in
            _ = readRequestHead(peer)
            peer.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
            Thread.sleep(forTimeInterval: 0.4)
            peer.write("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")
            peer.close()
        }
        defer { server.stop() }
        let s = try await EventStream.open(UnixHTTPClient(socketPath: server.path), "/w", options: SSEOptions(timeout: .seconds(5), idleTimeout: .milliseconds(100)))
        defer { s.close() }
        await assertThrows(.timeout) { try await s.next() }
        s.idleTimeout = .seconds(5)
        var names: [String] = []
        for try await ev in s.events { names.append(ev.event) }
        XCTAssertEqual(names, ["a", "b"])
    }
}
