// Errors of the WebmuxHost package: one enum covering the socket, HTTP,
// WebSocket, SSE and API layers (the union of Conn.zig's ConnectError and
// Error, http.zig's Error, websocket.zig's HandshakeError/ProtocolError,
// sse.zig's BadResponse and api.zig's HttpStatus/InvalidBody).
import Foundation

public enum HostError: Error, Equatable, Sendable {
    // -- connecting (Conn.ConnectError) --
    /// The socket path does not exist.
    case socketNotFound(path: String)
    /// Nothing is listening on the path (or its backlog is full).
    case connectionRefused(path: String)
    case accessDenied(path: String)
    /// Unix socket paths are limited to 103 bytes on Darwin.
    case nameTooLong(path: String)

    // -- while connected (Conn.Error) --
    /// The deadline passed.
    case timeout
    /// `interrupt()` was called, the connection was closed under the
    /// operation, or the Task was cancelled.
    case cancelled
    /// The peer closed the connection before the expected data arrived.
    case endOfStream
    case connectionReset
    case brokenPipe
    /// An unexpected errno.
    case system(errno: Int32)

    // -- HTTP (http.Error) --
    /// The response was not valid HTTP/1.x, or violated the WebSocket or
    /// event-stream protocol.
    case protocolViolation(ProtocolFailure)
    /// `fetch`: the body exceeded `maxBody`.
    case bodyTooLarge
    /// A request body stream produced a different number of bytes than the
    /// declared length.
    case bodyLengthMismatch
    /// Reading the request body (file or stream) failed.
    case readFailed(String)
    /// Writing the downloaded body to its destination failed.
    case writeFailed(String)

    // -- API (api.Error) --
    /// Non-2xx answer; `message` is the host's `{"error": …}` (truncated,
    /// empty if none).
    case httpStatus(status: Int, message: String)
    /// 2xx answer whose body was not the expected JSON.
    case invalidBody(status: Int)

    // -- WebSocket (websocket.Error) --
    /// A message exceeded `maxMessage`.
    case messageTooLarge
    /// The WebSocket was already closed (a close frame was received, or
    /// sent and acknowledged).
    case closed
}

/// The ways a peer can speak the wrong protocol.
public enum ProtocolFailure: Equatable, Sendable {
    /// Not an HTTP/1.x status line, a header without a colon, a bad chunk
    /// size, or a missing CRLF after chunk data.
    case invalidResponse
    /// The response head exceeded 64 KiB.
    case headTooLarge
    /// A line (SSE) exceeded the limit.
    case lineTooLong
    /// WebSocket upgrade: the server answered with something other than
    /// 101 + Upgrade/Connection headers.
    case upgradeRejected(status: Int)
    /// 101, but Sec-WebSocket-Accept did not match our key.
    case badAccept
    /// A WebSocket frame violated RFC 6455 (masked server frame, reserved
    /// bits or opcodes, fragmented or oversized control frame, bad
    /// continuation, 1-byte close payload).
    case websocketViolation
    /// A WebSocket text message was not valid UTF-8.
    case invalidUTF8
    /// `GET /api/fs/watch` did not answer 200 text/event-stream.
    case notAnEventStream(status: Int)
    /// A session frame was not a JSON object with a string `type`.
    case invalidFrame
}

extension HostError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .socketNotFound(let p): return "socket not found: \(p)"
        case .connectionRefused(let p): return "connection refused: \(p)"
        case .accessDenied(let p): return "access denied: \(p)"
        case .nameTooLong(let p): return "socket path too long: \(p)"
        case .timeout: return "timed out"
        case .cancelled: return "cancelled"
        case .endOfStream: return "connection closed before the expected data"
        case .connectionReset: return "connection reset"
        case .brokenPipe: return "broken pipe"
        case .system(let e): return "system error \(e): \(String(cString: strerror(e)))"
        case .protocolViolation(let f): return "protocol violation: \(f)"
        case .bodyTooLarge: return "response body too large"
        case .bodyLengthMismatch: return "request body length mismatch"
        case .readFailed(let s): return "read failed: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        case .httpStatus(let s, let m): return m.isEmpty ? "HTTP \(s)" : "HTTP \(s): \(m)"
        case .invalidBody(let s): return "HTTP \(s): unexpected body"
        case .messageTooLarge: return "WebSocket message too large"
        case .closed: return "WebSocket closed"
        }
    }
}
