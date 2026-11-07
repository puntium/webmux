// Connection log: the port of electron/log.js.
//
// Two sinks fed from one `push`: a bounded in-memory ring (3000 entries)
// that the log window renders and tails live, and an append-only file
// (`<Application Support>/logs/webmux.log`, rolled once to `.1` when it has
// grown past 1 MiB). Entries have the log.js shape
// `{ seq, t, level, src, conn, msg, data }` and the file gets one
// `<iso> LEVEL [conn] msg k=v…` line each, byte-for-byte the log.js format.
//
// Nothing here may ever see a secret: callers log ssh argument lists (the
// password travels in the child's environment, never argv) and never the
// spawn environment.
//
// Thread-safe. Subscribers are invoked on the thread that pushed the entry,
// after the log's lock is released, so a subscriber may call back in.
import Foundation

public enum LogLevel: String, Sendable, Comparable, CaseIterable {
    case debug, info, warn, error

    var upper: String { rawValue.uppercased() }

    /// log.js: `LEVELS.includes(level) ? level : 'info'`.
    public static func parse(_ s: String) -> LogLevel { LogLevel(rawValue: s) ?? .info }

    public static func < (a: LogLevel, b: LogLevel) -> Bool {
        LogLevel.allCases.firstIndex(of: a)! < LogLevel.allCases.firstIndex(of: b)!
    }
}

/// Who produced the entry: the client itself, or a host page reporting in
/// (in this client: the terminal/file panes, standing in for the Electron
/// page's `POST /log`).
public enum LogSource: String, Sendable { case main, page }

/// One `data` value. `json` is pre-serialized JSON text (an object or
/// array); like log.js it is kept as a (clipped) string and shown quoted.
public enum LogValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case json(String)

    var formatted: String {
        switch self {
        case .string(let s): return (!s.isEmpty && LogValue.isPlain(s)) ? s : Util.jsonString(s)
        case .int(let i): return String(i)
        case .double(let f): return Util.jsNumber(f)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        // log.js sanitizeData turns non-scalars into JSON *strings*, which
        // fmtValue then shows quoted.
        case .json(let j): return Util.jsonString(j)
        }
    }

    /// `^[\w./:@~-]+$`: printed bare.
    static func isPlain(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || "_./:@~-".unicodeScalars.contains(u)
        }
    }
}

public struct LogField: Sendable, Equatable {
    public var key: String
    public var value: LogValue
    public init(_ key: String, _ value: LogValue) {
        self.key = key
        self.value = value
    }
    public init(_ key: String, _ s: String) { self.init(key, .string(s)) }
    public init(_ key: String, _ i: Int) { self.init(key, .int(Int64(i))) }
    public init(_ key: String, _ i: Int64) { self.init(key, .int(i)) }
    public init(_ key: String, _ i: Int32) { self.init(key, .int(Int64(i))) }
    public init(_ key: String, _ i: pid_t?) { self.init(key, i.map { .int(Int64($0)) } ?? .null) }
    public init(_ key: String, optional s: String?) { self.init(key, s.map(LogValue.string) ?? .null) }
}

public struct LogEntry: Sendable, Equatable {
    public var seq: UInt64
    /// ISO-8601 UTC with milliseconds, as JS `Date.toISOString()`.
    public var t: String
    public var level: LogLevel
    public var src: LogSource
    public var conn: String?
    public var msg: String
    public var data: [LogField]

    /// The file-format line (no trailing newline): what log.js `formatLine`
    /// produces, and what the log window's copy buttons hand out.
    public var line: String {
        var s = t + " " + level.upper.padding(toLength: 5, withPad: " ", startingAt: 0) + " "
        if let c = conn { s += "[\(c)] " }
        if src == .page { s += "page: " }
        s += msg
        for f in data { s += " \(f.key)=\(f.value.formatted)" }
        return s
    }
}

public final class ConnectionLog: @unchecked Sendable {
    public static let maxEntries = 3000
    public static let logFileMax: UInt64 = 1024 * 1024
    public static let maxMsg = 500
    public static let maxDataString = 300
    public static let maxConn = 80
    public static let maxFields = 12

    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var head = 0
    private var seq: UInt64 = 0
    private var _filePath: String?
    private var fileSize: UInt64 = 0
    private var subs: [UInt64: @Sendable (LogEntry) -> Void] = [:]
    private var nextSub: UInt64 = 1
    /// Test hook: overrides the clock for `t` (ISO string).
    var fixedTime: String?
    /// Bytes before rolling; `logFileMax` except in tests.
    var fileMax: UInt64 = ConnectionLog.logFileMax

    public init() {
        ring.reserveCapacity(64)
    }

    /// Point the file sink at a directory (created if missing). Until called,
    /// entries only accumulate in memory.
    public func openFile(inDirectory dir: String) {
        try? Util.makePath(dir, mode: 0o700)
        let path = Util.join(dir, "webmux.log")
        lock.withLock {
            _filePath = path
            fileSize = Util.fileSize(path) ?? 0
        }
    }

    /// The log file path, or nil when there is no file sink.
    public var filePath: String? { lock.withLock { _filePath } }

    var currentFileSize: UInt64 { lock.withLock { fileSize } }

    /// The one write path. Returns the sequence number of the new entry.
    @discardableResult
    public func push(level: LogLevel = .info, src: LogSource = .main, conn: String? = nil, msg: String, data: [LogField] = []) -> UInt64 {
        var fields: [LogField] = []
        for f in data.prefix(ConnectionLog.maxFields) where ConnectionLog.validKey(f.key) {
            switch f.value {
            case .string(let s): fields.append(LogField(f.key, .string(ConnectionLog.clip(s))))
            case .json(let j): fields.append(LogField(f.key, .json(ConnectionLog.clip(j))))
            default: fields.append(f)
            }
        }
        var entry = LogEntry(seq: 0, t: "", level: level, src: src,
                             conn: conn.map { Util.clipChars($0, ConnectionLog.maxConn) },
                             msg: Util.clipChars(msg, ConnectionLog.maxMsg), data: fields)
        let subsCopy: [@Sendable (LogEntry) -> Void]
        lock.lock()
        seq += 1
        entry.seq = seq
        entry.t = fixedTime ?? Util.isoNow()
        appendFile(entry.line + "\n")
        if ring.count == ConnectionLog.maxEntries {
            ring[head] = entry
            head = (head + 1) % ConnectionLog.maxEntries
        } else {
            ring.append(entry)
        }
        subsCopy = Array(subs.values)
        let s = seq
        lock.unlock()
        for fn in subsCopy { fn(entry) }
        return s
    }

    /// log.js sanitizeData: plain keys (`^[A-Za-z_]\w{0,31}$`).
    static func validKey(_ k: String) -> Bool {
        guard let first = k.unicodeScalars.first, k.count <= 32 else { return false }
        guard ("a"..."z").contains(first) || ("A"..."Z").contains(first) || first == "_" else { return false }
        return k.unicodeScalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Clip to 300 characters, appending `…` when clipped (sanitizeData).
    static func clip(_ s: String) -> String {
        let c = Util.clipChars(s, maxDataString)
        return c.utf8.count == s.utf8.count ? s : c + "…"
    }

    /// Caller holds the lock. A full or read-only disk must never take the
    /// client down; the ring and the window still work.
    private func appendFile(_ line: String) {
        guard let path = _filePath else { return }
        if fileSize > fileMax {
            if rename(path, path + ".1") != 0 { return }
            fileSize = 0
        }
        let bytes = Array(line.utf8)
        do {
            try Util.appendToFile(path, bytes)
            fileSize += UInt64(bytes.count)
        } catch {}
    }

    public func debug(_ conn: String?, _ msg: String, _ data: [LogField] = []) { push(level: .debug, conn: conn, msg: msg, data: data) }
    public func info(_ conn: String?, _ msg: String, _ data: [LogField] = []) { push(level: .info, conn: conn, msg: msg, data: data) }
    public func warn(_ conn: String?, _ msg: String, _ data: [LogField] = []) { push(level: .warn, conn: conn, msg: msg, data: data) }
    public func error(_ conn: String?, _ msg: String, _ data: [LogField] = []) { push(level: .error, conn: conn, msg: msg, data: data) }
    public func at(_ level: LogLevel, _ conn: String?, _ msg: String, _ data: [LogField] = []) { push(level: level, conn: conn, msg: msg, data: data) }

    /// The ring entries with `seq > afterSeq` (all of them for 0), oldest first.
    public func since(_ afterSeq: UInt64 = 0) -> [LogEntry] {
        lock.withLock {
            var out: [LogEntry] = []
            out.reserveCapacity(ring.count)
            for i in 0..<ring.count {
                let e = ring[(head + i) % ring.count]
                if e.seq > afterSeq { out.append(e) }
            }
            return out
        }
    }

    /// Everything currently in memory as the text the file holds (log.js `text`).
    public func text() -> String {
        since(0).map { $0.line }.joined(separator: "\n")
    }

    /// Empty the ring (the file is untouched) and log that it happened.
    public func clear() {
        lock.withLock {
            ring.removeAll(keepingCapacity: true)
            head = 0
        }
        info(nil, "log cleared (file untouched)")
    }

    /// Live subscription; returns an id for `unsubscribe`. The callback runs
    /// on whichever thread pushed the entry (supervisor threads, mostly).
    public func subscribe(_ fn: @escaping @Sendable (LogEntry) -> Void) -> UInt64 {
        lock.withLock {
            let id = nextSub
            nextSub += 1
            subs[id] = fn
            return id
        }
    }

    public func unsubscribe(_ id: UInt64) {
        lock.withLock { _ = subs.removeValue(forKey: id) }
    }

    /// Push an entry supplied by an untrusted-ish source as a JSON object
    /// (`{ level, msg, data }`, as the Electron pages POST to /log),
    /// sanitized like log.js: level whitelist, clipped message, plain keys
    /// only, scalars kept, anything else re-serialized and clipped.
    public func pushJSON(conn: String?, src: LogSource, _ any: Any) {
        pushJSON(conn: conn, src: src, JSONValue(any: any))
    }

    func pushJSON(conn: String?, src: LogSource, _ v: JSONValue) {
        guard case .object(let o) = v else { return }
        let level: LogLevel = o["level"]?.stringValue.map(LogLevel.parse) ?? .info
        let msg: String
        switch o["msg"] {
        case .string(let s)?: msg = s
        case .null?, nil: msg = ""
        case let m?: msg = m.serialized
        }
        var fields: [LogField] = []
        if case .object(let d)? = o["data"] {
            for k in d.keys.sorted().prefix(ConnectionLog.maxFields) {
                let val: LogValue
                switch d[k]! {
                case .string(let s): val = .string(s)
                case .integer(let i): val = .int(i)
                case .float(let f): val = .double(f)
                case .bool(let b): val = .bool(b)
                case .null: val = .null
                case .array, .object: val = .json(d[k]!.serialized)
                }
                fields.append(LogField(k, val))
            }
        }
        push(level: level, src: src, conn: conn, msg: msg, data: fields)
    }
}
