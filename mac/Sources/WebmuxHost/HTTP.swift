// HTTP/1.1 client over a unix stream socket (the webmux host's HTTP server,
// reached directly or through the ssh tunnel's local socket). No TCP, no
// TLS, no auth, one connection per request (`Connection: close`). Port of
// the fork's `src/webmux/net/http.zig`.
//
// Three ways to make a request:
//   - `fetch`: buffer the whole response body (JSON API calls).
//   - `download`: stream the body into a file; it is never held in memory.
//   - `open`: read the response head, then pull the body incrementally from
//     the returned `HTTPBodyStream` (SSE, custom streaming).
//
// Request bodies are bytes, a file, or an `AsyncThrowingStream` of chunks
// (sent with Content-Length when the length is known, chunked otherwise).
//
// Timeouts: `timeout` is one deadline covering connect, sending the request
// and receiving the response head; for `fetch` it also covers the body.
// Streamed bodies (`download`, `open`) use `idleTimeout`, a limit on each
// wait for more body bytes (nil: wait indefinitely).
import Foundation

public enum HTTPMethod: String, Sendable {
    case GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
}

public struct HTTPHeader: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public enum HTTPRequestBody: Sendable {
    case none
    case bytes(Data)
    /// Streamed from the file with Content-Length = its size.
    case file(URL)
    /// Streamed from `chunks` until it ends. With `length` set, exactly that
    /// many bytes are sent (Content-Length); otherwise chunked encoding.
    case stream(AsyncThrowingStream<Data, Error>, length: Int64?)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    /// Request target: path plus query, e.g. "/api/fs/list?path=%7E".
    public var target: String
    public var headers: [HTTPHeader]
    /// Sets Content-Type when there is a body.
    public var contentType: String?
    public var body: HTTPRequestBody
    /// Deadline for connect + request + response head (and the body, for
    /// `fetch`). nil: no limit.
    public var timeout: Duration?
    /// For streamed bodies: limit on each wait for more bytes. nil: none.
    public var idleTimeout: Duration?
    /// `fetch` only: refuse bodies larger than this.
    public var maxBody: Int

    public init(
        _ method: HTTPMethod = .GET,
        _ target: String,
        headers: [HTTPHeader] = [],
        contentType: String? = nil,
        body: HTTPRequestBody = .none,
        timeout: Duration? = .seconds(30),
        idleTimeout: Duration? = nil,
        maxBody: Int = 64 * 1024 * 1024
    ) {
        self.method = method
        self.target = target
        self.headers = headers
        self.contentType = contentType
        self.body = body
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.maxBody = maxBody
    }

    /// A JSON request: the body is `value` encoded, Content-Type set.
    public static func json<T: Encodable>(_ method: HTTPMethod, _ target: String, _ value: T, timeout: Duration? = .seconds(30)) throws -> HTTPRequest {
        let data = try JSONEncoder().encode(value)
        return HTTPRequest(method, target, contentType: "application/json", body: .bytes(data), timeout: timeout)
    }
}

/// A parsed response head.
public struct HTTPResponseHead: Sendable, Equatable {
    public var status: Int
    public var reason: String
    public var headers: [HTTPHeader]

    public init(status: Int, reason: String = "", headers: [HTTPHeader] = []) {
        self.status = status
        self.reason = reason
        self.headers = headers
    }

    public var isSuccess: Bool { status >= 200 && status < 300 }

    /// First header with this name (case-insensitive).
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Whether a comma-separated header contains `token` (case-insensitive).
    public func headerHasToken(_ name: String, _ token: String) -> Bool {
        for h in headers where h.name.caseInsensitiveCompare(name) == .orderedSame {
            for part in h.value.split(separator: ",") {
                if part.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame { return true }
            }
        }
        return false
    }

    /// Content-Length, if present and numeric.
    public var contentLength: Int64? {
        header("content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// A fully buffered response.
public struct HTTPResponse: Sendable {
    public var head: HTTPResponseHead
    public var body: Data

    public var status: Int { head.status }
    public var isSuccess: Bool { head.isSuccess }

    /// Decode the body as JSON.
    public func json<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }
}

/// Body framing state (`Transfer-Encoding: chunked`, `Content-Length`, or
/// read-to-EOF). Each step consumes whole lines, so a timeout never loses
/// framing state.
struct BodyFraming {
    enum Mode {
        case none
        case length(remaining: UInt64)
        case chunked(left: UInt64, done: Bool, crlfPending: Bool)
        case eof
    }
    var mode: Mode

    static func of(method: HTTPMethod, head: HTTPResponseHead) -> BodyFraming {
        if method == .HEAD || head.status == 204 || head.status == 304 || (head.status >= 100 && head.status < 200) {
            return BodyFraming(mode: .none)
        }
        if head.headerHasToken("transfer-encoding", "chunked") {
            return BodyFraming(mode: .chunked(left: 0, done: false, crlfPending: false))
        }
        if let v = head.header("content-length") {
            guard let n = UInt64(v.trimmingCharacters(in: .whitespaces)) else { return BodyFraming(mode: .eof) }
            return BodyFraming(mode: .length(remaining: n))
        }
        return BodyFraming(mode: .eof)
    }

    /// Known total length, when framed by Content-Length.
    var declaredLength: UInt64? {
        if case .length(let n) = mode { return n }
        return nil
    }

    /// Up to `max` body bytes; empty at the end of the body.
    mutating func read(_ conn: SocketConnection, max: Int, deadline: Deadline) async throws -> Data {
        if max <= 0 { return Data() }
        switch mode {
        case .none:
            return Data()
        case .length(let left):
            if left == 0 { return Data() }
            let want = Int(min(left, UInt64(max)))
            let d = try await conn.readSome(max: want, deadline: deadline)
            if d.isEmpty { throw HostError.endOfStream }
            mode = .length(remaining: left - UInt64(d.count))
            return d
        case .eof:
            return try await conn.readSome(max: max, deadline: deadline)
        case .chunked(var left, var done, var crlfPending):
            defer { mode = .chunked(left: left, done: done, crlfPending: crlfPending) }
            while left == 0 {
                if done { return Data() }
                if crlfPending {
                    guard let crlf = try await conn.readLine(max: 16, deadline: deadline) else { throw HostError.endOfStream }
                    if !crlf.isEmpty { throw HostError.protocolViolation(.invalidResponse) }
                    crlfPending = false
                }
                guard let line = try await conn.readLine(max: 1024, deadline: deadline) else { throw HostError.endOfStream }
                let text = String(decoding: line, as: UTF8.self)
                let sizeText = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
                guard let size = UInt64(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw HostError.protocolViolation(.invalidResponse)
                }
                if size == 0 {
                    // Trailers, up to the empty line.
                    while let t = try await conn.readLine(max: 8192, deadline: deadline), !t.isEmpty {}
                    done = true
                    return Data()
                }
                left = size
            }
            let want = Int(min(left, UInt64(max)))
            let d = try await conn.readSome(max: want, deadline: deadline)
            if d.isEmpty { throw HostError.endOfStream }
            left -= UInt64(d.count)
            if left == 0 { crlfPending = true }
            return d
        }
    }
}

/// A response whose body is read incrementally.
public final class HTTPBodyStream: @unchecked Sendable {
    public let head: HTTPResponseHead
    /// Limit on each wait for more body bytes (nil: none). May be changed
    /// between reads.
    public var idleTimeout: Duration?

    private let conn: SocketConnection
    private var framing: BodyFraming

    init(conn: SocketConnection, head: HTTPResponseHead, framing: BodyFraming, idleTimeout: Duration?) {
        self.conn = conn
        self.head = head
        self.framing = framing
        self.idleTimeout = idleTimeout
    }

    /// Up to `max` body bytes; empty at the end of the body.
    public func read(max: Int = 64 * 1024) async throws -> Data {
        try await framing.read(conn, max: max, deadline: .after(idleTimeout))
    }

    /// The rest of the body, refusing more than `maxBody` bytes.
    public func readAll(maxBody: Int = 64 * 1024 * 1024) async throws -> Data {
        var out = Data()
        if let n = framing.declaredLength {
            if n > UInt64(maxBody) { throw HostError.bodyTooLarge }
            out.reserveCapacity(Int(n))
        }
        while true {
            let d = try await read(max: 32 * 1024)
            if d.isEmpty { return out }
            if out.count + d.count > maxBody { throw HostError.bodyTooLarge }
            out.append(d)
        }
    }

    /// The rest of the body as chunks. Consume this or `read`, not both.
    public var chunks: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while true {
                        let d = try await self.read()
                        if d.isEmpty { break }
                        continuation.yield(d)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Write the rest of the body to `url` (created or truncated). Returns
    /// the byte count.
    public func write(to url: URL) async throws -> Int64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HostError.writeFailed(url.path)
        }
        let fh: FileHandle
        do { fh = try FileHandle(forWritingTo: url) } catch { throw HostError.writeFailed(url.path) }
        defer { try? fh.close() }
        var total: Int64 = 0
        while true {
            let d = try await read(max: 64 * 1024)
            if d.isEmpty { break }
            do { try fh.write(contentsOf: d) } catch { throw HostError.writeFailed(url.path) }
            total += Int64(d.count)
        }
        return total
    }

    /// Make a blocked `read` (in another task) fail with `.cancelled`.
    public func interrupt() { conn.interrupt() }

    /// Close the connection. Call once, when done reading.
    public func close() { conn.close() }
}

/// Talks to one host over its unix socket.
public struct UnixHTTPClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Make a request and buffer the whole response body.
    public func fetch(_ req: HTTPRequest) async throws -> HTTPResponse {
        let deadline = Deadline.after(req.timeout)
        let conn = try SocketConnection.connect(path: socketPath)
        defer { conn.close() }
        try await sendRequest(conn, req, deadline: deadline)
        let head = try await readHead(conn, deadline: deadline)
        var framing = BodyFraming.of(method: req.method, head: head)
        var body = Data()
        if let n = framing.declaredLength {
            if n > UInt64(req.maxBody) { throw HostError.bodyTooLarge }
            body.reserveCapacity(Int(n))
        }
        while true {
            let d = try await framing.read(conn, max: 32 * 1024, deadline: deadline)
            if d.isEmpty { break }
            if body.count + d.count > req.maxBody { throw HostError.bodyTooLarge }
            body.append(d)
        }
        return HTTPResponse(head: head, body: body)
    }

    /// Make a request and stream the response body into the file at `url`
    /// (whatever the status; check the returned head).
    public func download(_ req: HTTPRequest, to url: URL) async throws -> HTTPResponseHead {
        let s = try await open(req)
        defer { s.close() }
        _ = try await s.write(to: url)
        return s.head
    }

    /// Make a request, read the response head, and return a stream for the
    /// body. Close it with `HTTPBodyStream.close`.
    public func open(_ req: HTTPRequest) async throws -> HTTPBodyStream {
        let deadline = Deadline.after(req.timeout)
        let conn = try SocketConnection.connect(path: socketPath)
        do {
            try await sendRequest(conn, req, deadline: deadline)
            let head = try await readHead(conn, deadline: deadline)
            return HTTPBodyStream(conn: conn, head: head, framing: .of(method: req.method, head: head), idleTimeout: req.idleTimeout)
        } catch {
            conn.close()
            throw error
        }
    }
}

// MARK: - Request writing

/// Write the request line, headers and body.
func sendRequest(_ conn: SocketConnection, _ req: HTTPRequest, deadline: Deadline) async throws {
    var head = "\(req.method.rawValue) \(req.target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    for h in req.headers { head += "\(h.name): \(h.value)\r\n" }
    var fileLength: Int64 = 0
    switch req.body {
    case .none:
        if req.method == .POST || req.method == .PUT || req.method == .PATCH { head += "Content-Length: 0\r\n" }
    case .bytes(let b):
        head += "Content-Length: \(b.count)\r\n"
    case .file(let url):
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value
        else { throw HostError.readFailed(url.path) }
        fileLength = size
        head += "Content-Length: \(size)\r\n"
    case .stream(_, let length):
        if let length { head += "Content-Length: \(length)\r\n" } else { head += "Transfer-Encoding: chunked\r\n" }
    }
    if !req.body.isNone, let ct = req.contentType { head += "Content-Type: \(ct)\r\n" }
    head += "\r\n"
    try await conn.writeAll(Data(head.utf8), deadline: deadline)

    switch req.body {
    case .none:
        break
    case .bytes(let b):
        try await conn.writeAll(b, deadline: deadline)
    case .file(let url):
        let fh: FileHandle
        do { fh = try FileHandle(forReadingFrom: url) } catch { throw HostError.readFailed(url.path) }
        defer { try? fh.close() }
        var sent: Int64 = 0
        while sent < fileLength {
            let want = Int(min(Int64(64 * 1024), fileLength - sent))
            let chunk: Data
            do { chunk = try fh.read(upToCount: want) ?? Data() } catch { throw HostError.readFailed(url.path) }
            if chunk.isEmpty { throw HostError.bodyLengthMismatch }
            try await conn.writeAll(chunk, deadline: deadline)
            sent += Int64(chunk.count)
        }
    case .stream(let chunks, let length):
        var sent: Int64 = 0
        do {
            for try await chunk in chunks {
                if chunk.isEmpty { continue }
                if let length {
                    if sent + Int64(chunk.count) > length { throw HostError.bodyLengthMismatch }
                    try await conn.writeAll(chunk, deadline: deadline)
                } else {
                    var framed = Data(String(chunk.count, radix: 16).utf8)
                    framed.append(contentsOf: [0x0d, 0x0a])
                    framed.append(chunk)
                    framed.append(contentsOf: [0x0d, 0x0a])
                    try await conn.writeAll(framed, deadline: deadline)
                }
                sent += Int64(chunk.count)
            }
        } catch let e as HostError {
            throw e
        } catch {
            throw HostError.readFailed(String(describing: error))
        }
        if let length {
            if sent != length { throw HostError.bodyLengthMismatch }
        } else {
            try await conn.writeAll(Data("0\r\n\r\n".utf8), deadline: deadline)
        }
    }
}

// MARK: - Response head parsing

let maxHead = 64 * 1024

/// Read and parse a response head ("HTTP/1.1 200 OK" + headers + blank
/// line). Leaves any following bytes buffered in `conn`.
func readHead(_ conn: SocketConnection, deadline: Deadline) async throws -> HTTPResponseHead {
    var lines: [String] = []
    var total = 0
    while true {
        let line: Data?
        do {
            line = try await conn.readLine(max: maxHead, deadline: deadline)
        } catch HostError.protocolViolation(.lineTooLong) {
            throw HostError.protocolViolation(.headTooLarge)
        }
        guard let line else { throw HostError.endOfStream }
        if line.isEmpty {
            if lines.isEmpty { continue } // tolerate a leading blank line
            break
        }
        total += line.count
        if total > maxHead { throw HostError.protocolViolation(.headTooLarge) }
        lines.append(String(decoding: line, as: UTF8.self))
    }
    return try parseHead(lines)
}

/// Parse a status line and header lines.
func parseHead(_ lines: [String]) throws -> HTTPResponseHead {
    guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.") else {
        throw HostError.protocolViolation(.invalidResponse)
    }
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2, let status = Int(parts[1]) else { throw HostError.protocolViolation(.invalidResponse) }
    let reason = parts.count > 2 ? String(parts[2]) : ""
    var headers: [HTTPHeader] = []
    headers.reserveCapacity(lines.count - 1)
    for text in lines.dropFirst() {
        guard let colon = text.firstIndex(of: ":") else { throw HostError.protocolViolation(.invalidResponse) }
        headers.append(HTTPHeader(
            text[..<colon].trimmingCharacters(in: .whitespaces),
            text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        ))
    }
    return HTTPResponseHead(status: status, reason: reason, headers: headers)
}

// MARK: - Targets

/// Percent-encode `s` for use as one path segment or query value
/// (everything but unreserved characters is escaped).
public func percentEncode(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    let hex = Array("0123456789ABCDEF".utf8)
    for c in s.utf8 {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            out.unicodeScalars.append(Unicode.Scalar(c))
        default:
            out.append("%")
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(c >> 4)]))
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(c & 0xf)]))
        }
    }
    return out
}

/// `path` plus a query string built from `query` (values percent-encoded).
public func httpTarget(_ path: String, query: [(String, String)] = []) -> String {
    if query.isEmpty { return path }
    return path + "?" + query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
}
