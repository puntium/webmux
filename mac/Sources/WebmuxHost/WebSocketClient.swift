// RFC 6455 WebSocket client over a unix stream socket. Port of the fork's
// `src/webmux/net/websocket.zig`.
//
// Built for the session socket's usage pattern:
//   - a reader task owned by the actor turns incoming frames into
//     `messages` (pings are answered there, fragmented messages
//     reassembled, close frames replied to);
//   - any task may `sendText` / `sendBinary` / `ping` / `close` (serialized
//     by the actor; a frame is never interleaved);
//   - any task may call `interrupt` to make the reader (and any blocked
//     send) fail with `.cancelled` promptly, e.g. at shutdown.
//
// No extensions (permessage-deflate is not offered), no subprotocols.
// `NWProtocolWebSocket` does not come up over an `NWEndpoint.unix`, hence
// the hand-rolled framing (as the reference does).
import CryptoKit
import Foundation

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
    /// The server closed the connection (our reply has been sent). `code`
    /// is nil when the close frame carried no status. `messages` ends after
    /// this.
    case close(code: UInt16?, reason: String)
}

public struct WebSocketOptions: Sendable {
    /// Deadline for connect + upgrade handshake.
    public var timeout: Duration? = .seconds(10)
    /// Largest message accepted from the server (the host's own limit is
    /// 100 MiB).
    public var maxMessage: Int = WebSocketClient.defaultMaxMessage
    public var headers: [HTTPHeader] = []

    public init(timeout: Duration? = .seconds(10), maxMessage: Int = WebSocketClient.defaultMaxMessage, headers: [HTTPHeader] = []) {
        self.timeout = timeout
        self.maxMessage = maxMessage
        self.headers = headers
    }
}

enum WebSocketOpcode: UInt8 {
    case continuation = 0
    case text = 1
    case binary = 2
    case close = 8
    case ping = 9
    case pong = 10
}

/// A decoded frame header (RFC 6455 §5.2).
struct WebSocketFrameHeader: Equatable {
    var fin: Bool
    var rsv: UInt8
    var opcode: UInt8
    var masked: Bool
    var length: UInt64
    var mask: [UInt8]?

    /// Bytes of header for a first-two-bytes prefix: 2 + extended length
    /// + 4 if masked.
    static func size(afterPrefix b: (UInt8, UInt8)) -> Int {
        let len = b.1 & 0x7f
        return 2 + (len == 126 ? 2 : len == 127 ? 8 : 0) + (b.1 & 0x80 != 0 ? 4 : 0)
    }

}

extension WebSocketFrameHeader {
    /// Parse a complete header (`bytes.count == size(afterPrefix:)`).
    init(_ bytes: [UInt8]) {
        fin = bytes[0] & 0x80 != 0
        rsv = (bytes[0] & 0x70) >> 4
        opcode = bytes[0] & 0x0f
        masked = bytes[1] & 0x80 != 0
        var n = 2
        let l = bytes[1] & 0x7f
        if l == 126 {
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            n = 4
        } else if l == 127 {
            var v: UInt64 = 0
            for i in 2..<10 { v = v << 8 | UInt64(bytes[i]) }
            length = v
            n = 10
        } else {
            length = UInt64(l)
        }
        mask = masked ? Array(bytes[n..<n + 4]) : nil
    }
}

/// One complete (unfragmented) frame, masked with `mask` (a client frame).
func encodeWebSocketFrame(opcode: WebSocketOpcode, payload: Data, mask: (UInt8, UInt8, UInt8, UInt8)) -> Data {
    var out = Data(capacity: payload.count + 14)
    out.append(0x80 | opcode.rawValue)
    let n = payload.count
    if n < 126 {
        out.append(0x80 | UInt8(n))
    } else if n <= 0xffff {
        out.append(0x80 | 126)
        out.append(UInt8(n >> 8))
        out.append(UInt8(n & 0xff))
    } else {
        out.append(0x80 | 127)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xff)) }
    }
    let m = [mask.0, mask.1, mask.2, mask.3]
    out.append(contentsOf: m)
    var masked = [UInt8](repeating: 0, count: n)
    payload.withUnsafeBytes { src in
        for i in 0..<n { masked[i] = src[i] ^ m[i & 3] }
    }
    out.append(contentsOf: masked)
    return out
}

/// Sec-WebSocket-Accept for a key: base64(sha1(key ++ guid)).
func webSocketAcceptKey(_ key: String) -> String {
    var h = Insecure.SHA1()
    h.update(data: Data(key.utf8))
    h.update(data: Data(WebSocketClient.guid.utf8))
    return Data(h.finalize()).base64EncodedString()
}

public actor WebSocketClient {
    public static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// The host's own limit (coder/websocket read limit, ws's maxPayload).
    public static let defaultMaxMessage = 100 * 1024 * 1024

    /// Incoming text/binary messages, then one `.close` (or an error) and
    /// the end of the stream.
    public nonisolated let messages: AsyncThrowingStream<WebSocketMessage, Error>

    private let conn: SocketConnection
    private let maxMessage: Int
    private let continuation: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    private var reader: Task<Void, Never>?
    private var sentClose = false
    private var recvClosed = false

    /// Connect to `socketPath` and upgrade `target` (e.g.
    /// "/ws?session=<id>").
    public static func connect(socketPath: String, target: String, options: WebSocketOptions = WebSocketOptions()) async throws -> WebSocketClient {
        let deadline = Deadline.after(options.timeout)
        let conn = try SocketConnection.connect(path: socketPath)
        do {
            try await handshake(conn, target: target, options: options, deadline: deadline)
        } catch {
            conn.close()
            throw error
        }
        return WebSocketClient(conn: conn, maxMessage: options.maxMessage)
    }

    private static func handshake(_ conn: SocketConnection, target: String, options: WebSocketOptions, deadline: Deadline) async throws {
        var raw = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in raw.indices { raw[i] = UInt8.random(in: .min ... .max, using: &rng) }
        let key = Data(raw).base64EncodedString()
        // `Connection: Upgrade` replaces http's default "close".
        var req = "GET \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
        req += "Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n"
        for h in options.headers { req += "\(h.name): \(h.value)\r\n" }
        req += "\r\n"
        try await conn.writeAll(Data(req.utf8), deadline: deadline)
        let head = try await readHead(conn, deadline: deadline)
        guard head.status == 101, head.headerHasToken("upgrade", "websocket"), head.headerHasToken("connection", "upgrade") else {
            throw HostError.protocolViolation(.upgradeRejected(status: head.status))
        }
        guard head.header("sec-websocket-accept") == webSocketAcceptKey(key) else {
            throw HostError.protocolViolation(.badAccept)
        }
    }

    /// Wrap an already upgraded connection (tests).
    init(conn: SocketConnection, maxMessage: Int) {
        self.conn = conn
        self.maxMessage = maxMessage
        var cont: AsyncThrowingStream<WebSocketMessage, Error>.Continuation!
        messages = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        Task { await self.startReader() }
    }

    private func startReader() {
        guard reader == nil else { return }
        reader = Task { await self.readLoop() }
    }

    /// Make the reader and any blocked send fail with `.cancelled`.
    /// Thread-safe, idempotent, sends nothing.
    public nonisolated func interrupt() { conn.interrupt() }

    /// Close the socket (without a close handshake; call `close` first for
    /// a clean one). `messages` ends.
    public func shutdown() {
        conn.close()
        continuation.finish()
    }

    // MARK: Sending

    /// Send one text message.
    public func sendText(_ text: String) async throws {
        try await writeFrame(.text, Data(text.utf8))
    }

    /// Send one binary message.
    public func sendBinary(_ data: Data) async throws {
        try await writeFrame(.binary, data)
    }

    /// Send a ping (payload at most 125 bytes).
    public func ping(_ payload: Data = Data()) async throws {
        if payload.count > 125 { throw HostError.protocolViolation(.websocketViolation) }
        try await writeFrame(.ping, payload)
    }

    /// Start the close handshake (status `code`, optional short reason).
    /// The server's reply arrives on `messages` as `.close`.
    public func close(code: UInt16 = 1000, reason: String = "") async throws {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xff)])
        payload.append(Data(reason.utf8).prefix(123))
        try await writeFrame(.close, payload)
    }

    private func writeFrame(_ op: WebSocketOpcode, _ payload: Data) async throws {
        if sentClose { throw HostError.closed }
        if op == .close { sentClose = true }
        var rng = SystemRandomNumberGenerator()
        let mask = (UInt8.random(in: .min ... .max, using: &rng), UInt8.random(in: .min ... .max, using: &rng),
                    UInt8.random(in: .min ... .max, using: &rng), UInt8.random(in: .min ... .max, using: &rng))
        try await conn.writeAll(encodeWebSocketFrame(opcode: op, payload: payload, mask: mask), deadline: .never)
    }

    // MARK: Receiving

    private func readLoop() async {
        do {
            while true {
                let m = try await readMessage()
                continuation.yield(m)
                if case .close = m {
                    continuation.finish()
                    return
                }
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Block until the next text/binary message or a close frame. Pings are
    /// answered and pongs ignored on the way.
    private func readMessage() async throws -> WebSocketMessage {
        if recvClosed { throw HostError.closed }
        var msg = Data()
        var msgOp: WebSocketOpcode?
        while true {
            let prefix = try await conn.readExact(2, deadline: .never)
            let b0 = prefix[prefix.startIndex], b1 = prefix[prefix.startIndex + 1]
            let size = WebSocketFrameHeader.size(afterPrefix: (b0, b1))
            var bytes = [b0, b1]
            if size > 2 { bytes.append(contentsOf: try await conn.readExact(size - 2, deadline: .never)) }
            let h = WebSocketFrameHeader(bytes)
            if h.rsv != 0 { throw HostError.protocolViolation(.websocketViolation) } // no extensions
            if h.masked { throw HostError.protocolViolation(.websocketViolation) } // server frames are unmasked
            if h.length >> 63 != 0 { throw HostError.protocolViolation(.websocketViolation) }
            guard let op = WebSocketOpcode(rawValue: h.opcode) else { throw HostError.protocolViolation(.websocketViolation) }

            switch op {
            case .ping, .pong, .close:
                if !h.fin || h.length > 125 { throw HostError.protocolViolation(.websocketViolation) }
                let payload = try await conn.readExact(Int(h.length), deadline: .never)
                switch op {
                case .ping:
                    do { try await writeFrame(.pong, payload) } catch HostError.closed {}
                case .pong:
                    break
                default:
                    recvClosed = true
                    var code: UInt16?
                    var reason = ""
                    if payload.count >= 2 {
                        code = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
                        reason = String(decoding: payload.dropFirst(2), as: UTF8.self)
                    } else if payload.count == 1 {
                        throw HostError.protocolViolation(.websocketViolation)
                    }
                    // Echo the status back, as RFC 6455 §5.5.1 asks.
                    try? await writeFrame(.close, payload.prefix(2))
                    return .close(code: code, reason: reason)
                }
            case .text, .binary, .continuation:
                if op == .continuation {
                    if msgOp == nil { throw HostError.protocolViolation(.websocketViolation) }
                } else {
                    if msgOp != nil { throw HostError.protocolViolation(.websocketViolation) }
                    msgOp = op
                }
                if UInt64(msg.count) + h.length > UInt64(maxMessage) { throw HostError.messageTooLarge }
                msg.append(try await conn.readExact(Int(h.length), deadline: .never))
                if h.fin {
                    if msgOp == .text {
                        guard let s = String(validatingUTF8Bytes: msg) else { throw HostError.protocolViolation(.invalidUTF8) }
                        return .text(s)
                    }
                    return .binary(msg)
                }
            }
        }
    }
}

extension String {
    /// `nil` unless `data` is valid UTF-8 (no replacement).
    init?(validatingUTF8Bytes data: Data) {
        var it = data.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&it) {
            case .scalarValue(let v): scalars.append(v)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}
