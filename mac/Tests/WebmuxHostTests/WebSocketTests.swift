import XCTest
@testable import WebmuxHost

final class WebSocketTests: XCTestCase {
    func testAcceptKeyMatchesRFC6455Example() {
        XCTAssertEqual(webSocketAcceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testFrameEncoding() {
        // RFC 6455 §5.7: a single-frame masked text message "Hello".
        let f = encodeWebSocketFrame(opcode: .text, payload: Data("Hello".utf8), mask: (0x37, 0xfa, 0x21, 0x3d))
        XCTAssertEqual([UInt8](f), [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        // 16-bit and 64-bit lengths.
        let mid = encodeWebSocketFrame(opcode: .binary, payload: Data(repeating: 0, count: 256), mask: (0, 0, 0, 0))
        XCTAssertEqual([UInt8](mid.prefix(8)), [0x82, 0x80 | 126, 0x01, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(mid.count, 8 + 256)
        let big = encodeWebSocketFrame(opcode: .binary, payload: Data(repeating: 0, count: 70_000), mask: (0, 0, 0, 0))
        XCTAssertEqual([UInt8](big.prefix(14)), [0x82, 0x80 | 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70, 0, 0, 0, 0])
        XCTAssertEqual(big.count, 14 + 70_000)
        XCTAssertEqual([UInt8](encodeWebSocketFrame(opcode: .close, payload: Data(), mask: (1, 2, 3, 4))), [0x88, 0x80, 1, 2, 3, 4])
    }

    func testFrameHeaderDecoding() {
        XCTAssertEqual(WebSocketFrameHeader.size(afterPrefix: (0x81, 0x05)), 2)
        XCTAssertEqual(WebSocketFrameHeader.size(afterPrefix: (0x81, 0x85)), 6)
        XCTAssertEqual(WebSocketFrameHeader.size(afterPrefix: (0x81, 126)), 4)
        XCTAssertEqual(WebSocketFrameHeader.size(afterPrefix: (0x81, 127 | 0x80)), 14)
        let h = WebSocketFrameHeader([0x01, 126, 0x01, 0x00])
        XCTAssertEqual(h, WebSocketFrameHeader(fin: false, rsv: 0, opcode: 1, masked: false, length: 256, mask: nil))
        let m = WebSocketFrameHeader([0xc9, 0x83, 1, 2, 3, 4])
        XCTAssertEqual(m, WebSocketFrameHeader(fin: true, rsv: 4, opcode: 9, masked: true, length: 3, mask: [1, 2, 3, 4]))
        let big = WebSocketFrameHeader([0x82, 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70])
        XCTAssertEqual(big.length, 70_000)
    }

    /// An unmasked (server) frame.
    private func serverFrame(_ op: UInt8, _ payload: Data, fin: Bool = true, rsv: UInt8 = 0) -> Data {
        var d = Data([(fin ? 0x80 : 0) | (rsv << 4) | op])
        if payload.count < 126 {
            d.append(UInt8(payload.count))
        } else if payload.count <= 0xffff {
            d.append(126)
            d.append(UInt8(payload.count >> 8))
            d.append(UInt8(payload.count & 0xff))
        } else {
            d.append(127)
            for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((UInt64(payload.count) >> UInt64(s)) & 0xff)) }
        }
        d.append(payload)
        return d
    }

    /// Read one masked client frame from the peer and unmask it.
    private func readClientFrame(_ peer: Peer) -> (op: UInt8, payload: Data) {
        let prefix = peer.read(exactly: 2)
        let size = WebSocketFrameHeader.size(afterPrefix: (prefix[0], prefix[1]))
        var bytes = [UInt8](prefix)
        if size > 2 { bytes.append(contentsOf: peer.read(exactly: size - 2)) }
        let h = WebSocketFrameHeader(bytes)
        XCTAssertTrue(h.masked && h.fin)
        let masked = [UInt8](peer.read(exactly: Int(h.length)))
        let m = h.mask!
        return (h.opcode, Data(masked.enumerated().map { $0.element ^ m[$0.offset & 3] }))
    }

    func testReceiveFragmentsPingsAndCloseOverLoopback() async throws {
        let (c, peer) = Peer.pair()
        let ws = WebSocketClient(conn: c, maxMessage: 1000)
        var it = ws.messages.makeAsyncIterator()

        // A fragmented text message with a ping in between: the ping is
        // answered with a pong carrying the same payload.
        peer.write(serverFrame(1, Data("Hel".utf8), fin: false))
        peer.write(serverFrame(9, Data("pp".utf8)))
        peer.write(serverFrame(0, Data("lo".utf8)))
        await XCTAssertEqualAsync(try await it.next(), .text("Hello"))
        let pong = readClientFrame(peer)
        XCTAssertEqual(pong.op, 10)
        XCTAssertEqual(pong.payload, Data("pp".utf8))

        // Binary, a 16-bit length, a pong (ignored).
        peer.write(serverFrame(10, Data()))
        peer.write(serverFrame(2, Data(repeating: 7, count: 300)))
        await XCTAssertEqualAsync(try await it.next(), .binary(Data(repeating: 7, count: 300)))

        // Sends from the client are masked frames.
        try await ws.sendText("{\"type\":\"input\",\"data\":\"x\"}")
        let sent = readClientFrame(peer)
        XCTAssertEqual(sent.op, 1)
        XCTAssertEqual(String(decoding: sent.payload, as: UTF8.self), "{\"type\":\"input\",\"data\":\"x\"}")
        try await ws.ping(Data("q".utf8))
        XCTAssertEqual(readClientFrame(peer).op, 9)

        // Server close with code and reason: echoed back, surfaced, stream ends.
        peer.write(serverFrame(8, Data([0x03, 0xe8]) + Data("bye".utf8)))
        await XCTAssertEqualAsync(try await it.next(), .close(code: 1000, reason: "bye"))
        let echo = readClientFrame(peer)
        XCTAssertEqual(echo.op, 8)
        XCTAssertEqual(echo.payload, Data([0x03, 0xe8]))
        await XCTAssertNilAsync(try await it.next())
        await ws.shutdown()
        peer.close()
    }

    func testClientCloseHandshake() async throws {
        let (c, peer) = Peer.pair()
        let ws = WebSocketClient(conn: c, maxMessage: 1000)
        try await ws.close(code: 1001, reason: "going away")
        let f = readClientFrame(peer)
        XCTAssertEqual(f.op, 8)
        XCTAssertEqual(f.payload, Data([0x03, 0xe9]) + Data("going away".utf8))
        // After sending close, further sends fail with .closed.
        await assertThrows(.closed) { try await ws.sendText("x") }
        // The server's close reply (no status) ends the stream.
        peer.write(serverFrame(8, Data()))
        var it = ws.messages.makeAsyncIterator()
        await XCTAssertEqualAsync(try await it.next(), .close(code: nil, reason: ""))
        await ws.shutdown()
        peer.close()
    }

    func testProtocolViolationsAndLimits() async throws {
        func firstError(_ bytes: Data, maxMessage: Int = 1000) async -> HostError? {
            let (c, peer) = Peer.pair()
            let ws = WebSocketClient(conn: c, maxMessage: maxMessage)
            peer.write(bytes)
            var it = ws.messages.makeAsyncIterator()
            defer { Task { await ws.shutdown() }; peer.close() }
            do {
                _ = try await it.next()
                return nil
            } catch let e as HostError {
                return e
            } catch { return nil }
        }
        let v = HostError.protocolViolation(.websocketViolation)
        // RSV bits set.
        let rsv = await firstError(serverFrame(1, Data("x".utf8), rsv: 1))
        XCTAssertEqual(rsv, v)
        // A masked server frame.
        let masked = await firstError(Data([0x81, 0x81, 1, 2, 3, 4, 0x78]))
        XCTAssertEqual(masked, v)
        // Reserved opcode.
        let op = await firstError(serverFrame(3, Data()))
        XCTAssertEqual(op, v)
        // Fragmented control frame.
        let frag = await firstError(serverFrame(9, Data(), fin: false))
        XCTAssertEqual(frag, v)
        // Continuation without a start; a new start mid-message.
        let cont = await firstError(serverFrame(0, Data("x".utf8)))
        XCTAssertEqual(cont, v)
        let restart = await firstError(serverFrame(1, Data("a".utf8), fin: false) + serverFrame(1, Data("b".utf8)))
        XCTAssertEqual(restart, v)
        // One-byte close payload.
        let close1 = await firstError(serverFrame(8, Data([1])))
        XCTAssertEqual(close1, v)
        // Invalid UTF-8 in text.
        let utf8 = await firstError(serverFrame(1, Data([0xff, 0xfe])))
        XCTAssertEqual(utf8, .protocolViolation(.invalidUTF8))
        // Too large.
        let big = await firstError(serverFrame(2, Data(repeating: 0, count: 2000)), maxMessage: 1000)
        XCTAssertEqual(big, .messageTooLarge)
        // Peer closes mid-frame.
        let (c, peer) = Peer.pair()
        let ws = WebSocketClient(conn: c, maxMessage: 1000)
        peer.write(Data([0x81, 0x05, 0x48]))
        peer.close()
        var it = ws.messages.makeAsyncIterator()
        await assertThrows(.endOfStream) { try await it.next() }
        await ws.shutdown()
    }

    func testInterruptEndsTheMessageStream() async throws {
        let (c, peer) = Peer.pair()
        defer { peer.close() }
        let ws = WebSocketClient(conn: c, maxMessage: 1000)
        var it = ws.messages.makeAsyncIterator()
        let waiter = Task { () -> HostError? in
            do { _ = try await it.next(); return nil } catch let e as HostError { return e } catch { return nil }
        }
        try await Task.sleep(for: .milliseconds(50))
        ws.interrupt()
        let r = await waiter.value
        XCTAssertEqual(r, .cancelled)
        await assertThrows(.cancelled) { try await ws.sendText("{}") }
        await ws.shutdown()
    }

    func testHandshakeAgainstAFakeServer() async throws {
        // Accepts with the right key; rejects on another path.
        let server = FakeServer { peer in
            let head = readRequestHead(peer)
            let lines = head.split(separator: "\r\n")
            let path = lines[0].split(separator: " ")[1]
            let key = lines.first { $0.lowercased().hasPrefix("sec-websocket-key:") }.map { String($0.dropFirst("sec-websocket-key:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            XCTAssertTrue(head.contains("Connection: Upgrade\r\n") && head.contains("Upgrade: websocket\r\n") && head.contains("Sec-WebSocket-Version: 13\r\n"), head)
            if path == "/ws" {
                peer.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(webSocketAcceptKey(key))\r\n\r\n")
                peer.write(Data([0x81, 0x02]) + Data("hi".utf8))
                _ = peer.readSome(timeout: 2)
            } else if path == "/badaccept" {
                peer.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: nope\r\n\r\n")
            } else {
                peer.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            }
            peer.close()
        }
        defer { server.stop() }
        let ws = try await WebSocketClient.connect(socketPath: server.path, target: "/ws", options: WebSocketOptions(timeout: .seconds(5)))
        var it = ws.messages.makeAsyncIterator()
        await XCTAssertEqualAsync(try await it.next(), .text("hi"))
        await ws.shutdown()
        await assertThrows(.protocolViolation(.upgradeRejected(status: 400))) {
            try await WebSocketClient.connect(socketPath: server.path, target: "/nope", options: WebSocketOptions(timeout: .seconds(5)))
        }
        await assertThrows(.protocolViolation(.badAccept)) {
            try await WebSocketClient.connect(socketPath: server.path, target: "/badaccept", options: WebSocketOptions(timeout: .seconds(5)))
        }
    }
}
