// Typed helpers for the host's JSON API (host/internal/server/http.go,
// fs.go, paste.go, watch.go), extending the fork's `src/webmux/net/api.zig`
// (sessions) with the file-browser routes the Electron client uses
// (electron/ui/files-widget.js):
//
//   GET    /                       → {ok, server, payloadHash, ptyhost}
//   GET    /api/sessions           → [{id, cols, rows, title, createdAt, clients, pid}]
//   POST   /api/sessions           {cols, rows} → 201 {id}
//   DELETE /api/sessions/<id>      → {ok:true} | 404 {error}
//   POST   /api/paste              {mime, data} → {path}
//   GET    /api/fs/list?path=      → {path, entries:[{name,type,symlink?}], truncated}
//   GET    /api/fs/preview?path=   → {size, mtime, kind, …}
//   GET    /api/fs/raw?path=[&download=1] → the file
//   GET    /api/fs/watch?path=     → text/event-stream (ready | change | gone)
//   POST   /api/fs/upload?dir=&name= (raw body) → {name}
//   POST   /api/fs/rename          {path, name} → {ok, name}
//   POST   /api/fs/delete          {path} → {ok}
//
// Failures from the host come back as `HostError.httpStatus` with the
// status and the host's `{"error": …}` message.
import Foundation

public struct HostHealth: Sendable, Equatable, Decodable {
    public var ok: Bool = false
    public var server: String = ""
    public var payloadHash: String = ""
    public var ptyhost: String = ""

    private enum Keys: String, CodingKey { case ok, server, payloadHash, ptyhost }

    public init(ok: Bool = false, server: String = "", payloadHash: String = "", ptyhost: String = "") {
        self.ok = ok
        self.server = server
        self.payloadHash = payloadHash
        self.ptyhost = ptyhost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        server = c.string(.server) ?? ""
        payloadHash = c.string(.payloadHash) ?? ""
        ptyhost = c.string(.ptyhost) ?? ""
    }
}

public struct SessionInfo: Sendable, Equatable, Decodable {
    public var id: String
    public var cols: Int64 = 0
    public var rows: Int64 = 0
    public var title: String = ""
    /// Epoch milliseconds.
    public var createdAt: Int64 = 0
    /// Attached client count.
    public var clients: Int64 = 0
    public var pid: Int64 = 0

    private enum Keys: String, CodingKey { case id, cols, rows, title, createdAt, clients, pid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        cols = c.integer(.cols) ?? 0
        rows = c.integer(.rows) ?? 0
        title = c.string(.title) ?? ""
        createdAt = c.integer(.createdAt) ?? 0
        clients = c.integer(.clients) ?? 0
        pid = c.integer(.pid) ?? 0
    }
}

public struct DirectoryEntry: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable { case dir, file }
    public var name: String
    public var kind: Kind
    public var symlink: Bool

    private enum Keys: String, CodingKey { case name, type, symlink }

    public init(name: String, kind: Kind, symlink: Bool = false) {
        self.name = name
        self.kind = kind
        self.symlink = symlink
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = Kind(rawValue: c.string(.type) ?? "") ?? .file
        symlink = (try? c.decodeIfPresent(Bool.self, forKey: .symlink)) ?? false
    }
}

public struct DirectoryListing: Sendable, Equatable, Decodable {
    /// The absolute path listed.
    public var path: String
    /// Directories first, then base-collation order; at most 2000.
    public var entries: [DirectoryEntry]
    public var truncated: Bool

    private enum Keys: String, CodingKey { case path, entries, truncated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = c.string(.path) ?? ""
        entries = (try? c.decodeIfPresent([DirectoryEntry].self, forKey: .entries)) ?? []
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }
}

public struct ZipEntry: Sendable, Equatable, Decodable {
    public var name: String
    public var size: Double
    public var dir: Bool
}

public struct FilePreview: Sendable, Equatable, Decodable {
    public enum Kind: Sendable, Equatable {
        /// Not a regular file.
        case other
        /// By extension.
        case image
        case zip
        /// A NUL in the first 64 KiB.
        case binary
        case text
        case unknown(String)
    }
    public var size: Int64
    /// Fractional epoch milliseconds.
    public var mtime: Double
    public var kind: Kind
    /// `text`: the first 64 KiB, invalid UTF-8 as U+FFFD.
    public var content: String?
    /// `text`: content was cut; `zip`: entries were cut.
    public var truncated: Bool
    /// `zip`: archive entries (at most 2000) and the total count.
    public var entries: [ZipEntry]?
    public var count: Double?

    private enum Keys: String, CodingKey { case size, mtime, kind, content, truncated, entries, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        size = c.integer(.size) ?? 0
        mtime = (try? c.decodeIfPresent(Double.self, forKey: .mtime)) ?? 0
        switch c.string(.kind) ?? "" {
        case "other": kind = .other
        case "image": kind = .image
        case "zip": kind = .zip
        case "binary": kind = .binary
        case "text": kind = .text
        case let k: kind = .unknown(k)
        }
        content = c.string(.content)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        entries = try? c.decodeIfPresent([ZipEntry].self, forKey: .entries)
        count = try? c.decodeIfPresent(Double.self, forKey: .count)
    }
}

/// One event of `GET /api/fs/watch`.
public struct WatchEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The watch is in place.
        case ready
        /// Something in the directory changed (coalesced over 100 ms).
        case change
        /// The directory cannot be watched or vanished; the stream ends.
        case gone
        case other(String)
    }
    public var kind: Kind
    /// The watched directory.
    public var path: String
    /// `gone`: the errno code (e.g. "ENOENT").
    public var error: String?

    public init(kind: Kind, path: String, error: String? = nil) {
        self.kind = kind
        self.path = path
        self.error = error
    }

    /// Decode an event of the watch stream.
    public init(_ sse: ServerSentEvent) {
        switch sse.event {
        case "ready": kind = .ready
        case "change": kind = .change
        case "gone": kind = .gone
        case let e: kind = .other(e)
        }
        struct Payload: Decodable { var path: String?; var error: String? }
        let p = try? JSONDecoder().decode(Payload.self, from: Data(sse.data.utf8))
        path = p?.path ?? ""
        error = p?.error
    }
}

/// One entry of `POST /log` (the Electron client's connection-log relay:
/// `{level, msg, data}`; `data` is shallow and must hold nothing secret).
public struct LogEntry: Sendable, Equatable, Encodable {
    public var level: String
    public var msg: String
    public var data: [String: String]?

    public init(level: String, msg: String, data: [String: String]? = nil) {
        self.level = level
        self.msg = msg
        self.data = data
    }
}

// MARK: - Calling

/// Shared call plumbing: a 2xx JSON answer decoded as T, anything else
/// `.httpStatus` / `.invalidBody`.
struct APICaller: Sendable {
    let client: UnixHTTPClient
    let timeout: Duration?

    func call<T: Decodable>(_ req: HTTPRequest, as type: T.Type) async throws -> T {
        var r = req
        r.timeout = timeout
        let resp = try await client.fetch(r)
        guard resp.isSuccess else { throw HostError.httpStatus(status: resp.status, message: errorMessage(resp.body)) }
        do {
            return try resp.json(T.self)
        } catch {
            throw HostError.invalidBody(status: resp.status)
        }
    }

    /// The host's `{"error": …}` message, truncated; empty if none.
    func errorMessage(_ body: Data) -> String {
        struct E: Decodable { var error: String? }
        let m = (try? JSONDecoder().decode(E.self, from: body))?.error ?? ""
        return String(decoding: Array(m.utf8.prefix(256)), as: UTF8.self)
    }
}

private struct OK: Decodable { var ok: Bool? }

/// The host's identity, paste slot and page-log routes, plus the sessions
/// and files sub-APIs.
public struct HostAPI: Sendable {
    public let client: UnixHTTPClient
    /// Deadline for each call (connect through body).
    public var timeout: Duration?
    public var sessions: SessionsAPI { SessionsAPI(client: client, timeout: timeout) }
    public var files: FilesAPI { FilesAPI(client: client, timeout: timeout) }

    public init(client: UnixHTTPClient, timeout: Duration? = .seconds(10)) {
        self.client = client
        self.timeout = timeout
    }

    public init(socketPath: String, timeout: Duration? = .seconds(10)) {
        self.init(client: UnixHTTPClient(socketPath: socketPath), timeout: timeout)
    }

    /// GET / — the liveness/identity probe (the connection supervisor polls
    /// it with a 2 s timeout).
    public func health(timeout: Duration? = nil) async throws -> HostHealth {
        try await APICaller(client: client, timeout: timeout ?? self.timeout).call(HTTPRequest(.GET, "/"), as: HostHealth.self)
    }

    /// POST /api/paste with `{mime, data: base64}`: writes a paste file in
    /// the host's paste dir and returns its path. `mime` must be one of the
    /// image types the host accepts (png, jpeg, gif, webp, bmp).
    public func paste(mime: String, data: Data) async throws -> String {
        struct Body: Encodable { var mime: String; var data: String }
        struct Out: Decodable { var path: String }
        let req = try HTTPRequest.json(.POST, "/api/paste", Body(mime: mime, data: data.base64EncodedString()))
        return try await APICaller(client: client, timeout: timeout).call(req, as: Out.self).path
    }

    /// POST /log with a batch of entries. This is the route the Electron
    /// client serves on its own origin for the host pages' connection log;
    /// the Go host has no such route and answers 404 (`.httpStatus`).
    public func log(_ entries: [LogEntry]) async throws {
        let req = try HTTPRequest.json(.POST, "/log", entries)
        _ = try await APICaller(client: client, timeout: timeout).call(req, as: OK.self)
    }
}

public struct SessionsAPI: Sendable {
    public let client: UnixHTTPClient
    public var timeout: Duration?

    public init(client: UnixHTTPClient, timeout: Duration? = .seconds(10)) {
        self.client = client
        self.timeout = timeout
    }

    private var caller: APICaller { APICaller(client: client, timeout: timeout) }

    /// GET /api/sessions, in creation order.
    public func list() async throws -> [SessionInfo] {
        try await caller.call(HTTPRequest(.GET, "/api/sessions"), as: [SessionInfo].self)
    }

    /// POST /api/sessions. Returns the new session id.
    public func create(cols: UInt16, rows: UInt16) async throws -> String {
        struct Out: Decodable { var id: String }
        let body = Data("{\"cols\":\(cols),\"rows\":\(rows)}".utf8)
        let req = HTTPRequest(.POST, "/api/sessions", contentType: "application/json", body: .bytes(body))
        return try await caller.call(req, as: Out.self).id
    }

    /// DELETE /api/sessions/<id> (kills the session's shell). A missing
    /// session is `.httpStatus` with status 404.
    public func delete(id: String) async throws {
        _ = try await caller.call(HTTPRequest(.DELETE, "/api/sessions/\(percentEncode(id))"), as: OK.self)
    }

    /// The session WebSocket's request target: "/ws?session=<id>".
    public static func webSocketTarget(sessionID: String) -> String {
        "/ws?session=\(percentEncode(sessionID))"
    }

    /// Attach to a session's WebSocket.
    public func attach(id: String, options: WebSocketOptions = WebSocketOptions()) async throws -> WebSocketClient {
        try await WebSocketClient.connect(socketPath: client.socketPath, target: Self.webSocketTarget(sessionID: id), options: options)
    }
}

public struct FilesAPI: Sendable {
    public let client: UnixHTTPClient
    public var timeout: Duration?

    public init(client: UnixHTTPClient, timeout: Duration? = .seconds(10)) {
        self.client = client
        self.timeout = timeout
    }

    private var caller: APICaller { APICaller(client: client, timeout: timeout) }

    /// Query for a path parameter: nil (or "", "~") means $HOME on the host.
    private static func pathQuery(_ path: String?) -> [(String, String)] {
        path.map { [("path", $0)] } ?? []
    }

    /// GET /api/fs/list?path=. Errors are 400 with an errno code as the
    /// message (ENOENT, EACCES, ENOTDIR).
    public func list(path: String? = nil) async throws -> DirectoryListing {
        try await caller.call(HTTPRequest(.GET, httpTarget("/api/fs/list", query: Self.pathQuery(path))), as: DirectoryListing.self)
    }

    /// GET /api/fs/preview?path=.
    public func preview(path: String) async throws -> FilePreview {
        try await caller.call(HTTPRequest(.GET, httpTarget("/api/fs/preview", query: [("path", path)])), as: FilePreview.self)
    }

    /// GET /api/fs/raw?path=[&download=1]: the file's bytes as a stream.
    /// Non-2xx answers throw `.httpStatus` (400 `not a file` for
    /// directories). Close the stream when done.
    public func raw(path: String, download: Bool = false, idleTimeout: Duration? = .seconds(60)) async throws -> HTTPBodyStream {
        var q = [("path", path)]
        if download { q.append(("download", "1")) }
        let s = try await client.open(HTTPRequest(.GET, httpTarget("/api/fs/raw", query: q), timeout: timeout, idleTimeout: idleTimeout))
        guard s.head.isSuccess else {
            let body = (try? await s.readAll(maxBody: 64 * 1024)) ?? Data()
            s.close()
            throw HostError.httpStatus(status: s.head.status, message: caller.errorMessage(body))
        }
        return s
    }

    /// Download the file at `path` to `url`. Returns the byte count.
    public func download(path: String, to url: URL, idleTimeout: Duration? = .seconds(60)) async throws -> Int64 {
        let s = try await raw(path: path, idleTimeout: idleTimeout)
        defer { s.close() }
        return try await s.write(to: url)
    }

    /// GET /api/fs/watch?path= as an event stream (`ready`, `change`,
    /// `gone`). Decode events with `WatchEvent.init(_:)`; `events` gives
    /// them decoded. The client must reconnect on its own after a drop.
    public func watch(path: String? = nil, idleTimeout: Duration? = .seconds(60)) async throws -> EventStream {
        try await EventStream.open(client, httpTarget("/api/fs/watch", query: Self.pathQuery(path)), options: SSEOptions(timeout: timeout, idleTimeout: idleTimeout))
    }

    /// POST /api/fs/upload?dir=&name= with the raw file bytes (≤ 200 MiB).
    /// `name` may contain `/` (intermediate directories are created); only
    /// the basename is deduped (`stem (n).ext`). Returns the relative path
    /// as written.
    public func upload(dir: String, name: String, body: HTTPRequestBody, contentType: String = "application/octet-stream", timeout: Duration? = nil) async throws -> String {
        struct Out: Decodable { var name: String }
        var req = HTTPRequest(.POST, httpTarget("/api/fs/upload", query: [("dir", dir), ("name", name)]), contentType: contentType, body: body)
        req.timeout = timeout ?? self.timeout
        return try await APICaller(client: client, timeout: req.timeout).call(req, as: Out.self).name
    }

    /// Upload the local file at `url` into `dir` under `name` (default: its
    /// last path component).
    public func upload(file url: URL, toDir dir: String, name: String? = nil, timeout: Duration? = nil) async throws -> String {
        try await upload(dir: dir, name: name ?? url.lastPathComponent, body: .file(url), timeout: timeout)
    }

    /// POST /api/fs/rename with `{path, name}`; the rename stays within the
    /// entry's directory. Returns the new name. 400 `invalid name` / `name
    /// already taken` / errno code.
    public func rename(path: String, name: String) async throws -> String {
        struct Body: Encodable { var path: String; var name: String }
        struct Out: Decodable { var name: String? }
        let req = try HTTPRequest.json(.POST, "/api/fs/rename", Body(path: path, name: name))
        return try await caller.call(req, as: Out.self).name ?? name
    }

    /// POST /api/fs/delete with `{path}`: deletes recursively. 400
    /// `refusing to delete that` for `/` or $HOME.
    public func delete(path: String) async throws {
        struct Body: Encodable { var path: String }
        let req = try HTTPRequest.json(.POST, "/api/fs/delete", Body(path: path))
        _ = try await caller.call(req, as: OK.self)
    }
}

extension EventStream {
    /// The watch events, decoded.
    public var watchEvents: AsyncThrowingStream<WatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let ev = try await self.next() { continuation.yield(WatchEvent(ev)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
