// Server-sent events reader (the host's `GET /api/fs/watch`: `ready`,
// `change` and `gone` events, a `: ping` comment every 25 s). Port of the
// fork's `src/webmux/net/sse.zig`.
//
// `SSEParser` is the pure line-level state machine (WHATWG "event stream
// interpretation"); `EventStream` runs it over an `HTTPBodyStream`.
// Comments count as activity for the idle timeout but are not returned.
import Foundation

public struct ServerSentEvent: Sendable, Equatable {
    /// "message" when the event had no `event:` field.
    public var event: String
    /// `data:` lines joined with "\n".
    public var data: String
    /// Last `id:` seen on the stream (persists across events, per spec).
    public var id: String?

    public init(event: String, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

struct SSEParser {
    private var event = ""
    private var data = ""
    private var hasData = false
    private var lastID: String?
    /// Reconnection time requested by the server (`retry:`), in ms.
    private(set) var retryMilliseconds: UInt32?

    init() {}

    /// Feed one line (without its line terminator). Returns an event when
    /// the line completes one.
    mutating func line(_ l: String) -> ServerSentEvent? {
        if l.isEmpty { return dispatch() }
        if l.hasPrefix(":") { return nil } // comment
        let field: Substring
        var value: Substring
        if let colon = l.firstIndex(of: ":") {
            field = l[..<colon]
            value = l[l.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = l[...]
            value = ""
        }
        switch field {
        case "event":
            event = String(value)
        case "data":
            if hasData { data += "\n" }
            data += value
            hasData = true
        case "id":
            if !value.utf8.contains(0) { lastID = String(value) }
        case "retry":
            if let n = UInt32(value) { retryMilliseconds = n }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            event = ""
            data = ""
            hasData = false
        }
        if !hasData { return nil }
        return ServerSentEvent(event: event.isEmpty ? "message" : event, data: data, id: lastID)
    }
}

public struct SSEOptions: Sendable {
    /// Deadline for connect + response head.
    public var timeout: Duration? = .seconds(10)
    /// Fail with `.timeout` when nothing (not even a comment) arrives for
    /// this long. The host sends a comment every 25 s.
    public var idleTimeout: Duration? = .seconds(60)
    public var headers: [HTTPHeader] = []

    public init(timeout: Duration? = .seconds(10), idleTimeout: Duration? = .seconds(60), headers: [HTTPHeader] = []) {
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.headers = headers
    }
}

/// An open event stream.
public final class EventStream: @unchecked Sendable {
    public let head: HTTPResponseHead
    private let stream: HTTPBodyStream
    private var parser = SSEParser()
    private var lines = Data()
    private var pos = 0
    private var eof = false

    /// Limit on each wait for more bytes (nil: none). May be changed
    /// between `next` calls; a timed-out stream stays usable.
    public var idleTimeout: Duration? {
        get { stream.idleTimeout }
        set { stream.idleTimeout = newValue }
    }

    /// GET `target` with `Accept: text/event-stream`. Fails with
    /// `.protocolViolation(.notAnEventStream)` unless the server answers
    /// 200 text/event-stream.
    public static func open(_ client: UnixHTTPClient, _ target: String, options: SSEOptions = SSEOptions()) async throws -> EventStream {
        var headers = [HTTPHeader("Accept", "text/event-stream"), HTTPHeader("Cache-Control", "no-cache")]
        headers.append(contentsOf: options.headers)
        let s = try await client.open(HTTPRequest(.GET, target, headers: headers, timeout: options.timeout, idleTimeout: options.idleTimeout))
        let ct = s.head.header("content-type") ?? ""
        if s.head.status != 200 || !ct.hasPrefix("text/event-stream") {
            s.close()
            throw HostError.protocolViolation(.notAnEventStream(status: s.head.status))
        }
        return EventStream(stream: s)
    }

    init(stream: HTTPBodyStream) {
        self.stream = stream
        self.head = stream.head
    }

    public func close() { stream.close() }

    /// Make a blocked `next` fail with `.cancelled`. Thread-safe.
    public func interrupt() { stream.interrupt() }

    /// The next event, or nil when the server ended the stream.
    public func next() async throws -> ServerSentEvent? {
        while true {
            while let l = nextLine() {
                if let ev = parser.line(String(decoding: l, as: UTF8.self)) { return ev }
            }
            if eof {
                // Unterminated last line, then end of stream (the spec
                // discards an incomplete event at EOF).
                return nil
            }
            if pos > 0 {
                lines.removeSubrange(0..<pos)
                pos = 0
            }
            if lines.count > 16 * 1024 * 1024 { throw HostError.protocolViolation(.lineTooLong) }
            let d = try await stream.read(max: 8192)
            if d.isEmpty { eof = true } else { lines.append(d) }
        }
    }

    /// The events as a stream; finishes when the server ends it.
    public var events: AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let ev = try await self.next() { continuation.yield(ev) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextLine() -> Data? {
        let buf = lines[pos...]
        // Lines end in "\n", "\r\n" or a lone "\r".
        var i = buf.startIndex
        while i < buf.endIndex {
            let c = buf[i]
            if c == 0x0a {
                defer { pos = i + 1 }
                return lines[buf.startIndex..<i]
            }
            if c == 0x0d {
                if i + 1 < buf.endIndex {
                    pos = i + 1 + (buf[i + 1] == 0x0a ? 1 : 0)
                    return lines[buf.startIndex..<i]
                }
                if eof {
                    pos = i + 1
                    return lines[buf.startIndex..<i]
                }
                return nil // need the next byte to know if "\n" follows
            }
            i += 1
        }
        return nil
    }
}
