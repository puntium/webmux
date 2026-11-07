// The session WebSocket's JSON frames (`/ws?session=<id>`), as the host
// sends and expects them. Port of the fork's `src/webmux/net/protocol.zig`;
// wire reference: host/internal/ptyhost/session.go (snapshot/output/title/
// exit), ptyhost.go (error), server/ws.go (input/resize/paste-image/
// clipboard-sync handling), server/paste.go (paste-result, open-url),
// docs/how-it-works.md › Protocol.
//
// Server → client:
//   {"type":"snapshot","data":S,"cols":N,"rows":N,"title":S,"pid":N}
//   {"type":"output","data":S}
//   {"type":"title","title":S}
//   {"type":"session-title","session":S,"title":S}
//   {"type":"exit","exitCode":N}
//   {"type":"error","message":S}          (no such session)
//   {"type":"paste-result","mode":"claude"|"path","path"?:S}
//   {"type":"open-url","url":S,"id":S}
// Client → server:
//   {"type":"input","data":S}
//   {"type":"resize","cols":N,"rows":N}   (integers; host clamps 2..500 × 2..300)
//   {"type":"paste-image","mime":S,"data":base64}
//   {"type":"clipboard-sync","mime":S,"data":base64}
import Foundation

public struct Snapshot: Sendable, Equatable, Codable {
    /// VT stream that recreates the session's screen and scrollback when fed
    /// to a freshly reset terminal of size cols × rows.
    public var data: String
    /// 0 when missing or out of range.
    public var cols: UInt16
    public var rows: UInt16
    public var title: String
    /// Shell pid on the host (nil when unknown).
    public var pid: Int64?

    public init(data: String, cols: UInt16, rows: UInt16, title: String, pid: Int64?) {
        self.data = data
        self.cols = cols
        self.rows = rows
        self.title = title
        self.pid = pid
    }
}

public enum ServerFrame: Sendable, Equatable {
    case snapshot(Snapshot)
    case output(String)
    case title(String)
    case sessionTitle(session: String, title: String)
    case exit(code: Int64)
    case error(message: String)
    case pasteResult(mode: String, path: String?)
    case openURL(url: String, id: String)
    /// A frame type this client does not know (ignored by the backend).
    case unknown(type: String)

    /// Parse one server message. `.protocolViolation(.invalidFrame)` unless
    /// it is a JSON object with a string `type`.
    public init(json: Data) throws {
        do {
            self = try JSONDecoder().decode(ServerFrame.self, from: json)
        } catch let e as HostError {
            throw e
        } catch {
            throw HostError.protocolViolation(.invalidFrame)
        }
    }

    public init(json text: String) throws {
        try self.init(json: Data(text.utf8))
    }
}

extension ServerFrame: Decodable {
    private enum Keys: String, CodingKey {
        case type, data, cols, rows, title, pid, session, exitCode, message, error, mode, path, url, id
    }

    public init(from decoder: Decoder) throws {
        let c: KeyedDecodingContainer<Keys>
        do {
            c = try decoder.container(keyedBy: Keys.self)
        } catch {
            throw HostError.protocolViolation(.invalidFrame)
        }
        guard let type = c.string(.type) else { throw HostError.protocolViolation(.invalidFrame) }
        switch type {
        case "output":
            self = .output(c.string(.data) ?? "")
        case "snapshot":
            self = .snapshot(Snapshot(
                data: c.string(.data) ?? "",
                cols: c.dimension(.cols),
                rows: c.dimension(.rows),
                title: c.string(.title) ?? "",
                pid: c.integer(.pid)
            ))
        case "title":
            self = .title(c.string(.title) ?? "")
        case "session-title":
            self = .sessionTitle(session: c.string(.session) ?? "", title: c.string(.title) ?? "")
        case "exit":
            self = .exit(code: c.integer(.exitCode) ?? 0)
        case "error":
            // The Electron client reads `msg.error || msg.message`.
            self = .error(message: c.string(.error) ?? c.string(.message) ?? "")
        case "paste-result":
            self = .pasteResult(mode: c.string(.mode) ?? "", path: c.string(.path))
        case "open-url":
            self = .openURL(url: c.string(.url) ?? "", id: c.string(.id) ?? "")
        default:
            self = .unknown(type: type)
        }
    }
}

extension ServerFrame: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .snapshot(let s):
            try c.encode("snapshot", forKey: .type)
            try c.encode(s.data, forKey: .data)
            try c.encode(s.cols, forKey: .cols)
            try c.encode(s.rows, forKey: .rows)
            try c.encode(s.title, forKey: .title)
            try c.encode(s.pid ?? 0, forKey: .pid)
        case .output(let d):
            try c.encode("output", forKey: .type)
            try c.encode(d, forKey: .data)
        case .title(let t):
            try c.encode("title", forKey: .type)
            try c.encode(t, forKey: .title)
        case .sessionTitle(let s, let t):
            try c.encode("session-title", forKey: .type)
            try c.encode(s, forKey: .session)
            try c.encode(t, forKey: .title)
        case .exit(let code):
            try c.encode("exit", forKey: .type)
            try c.encode(code, forKey: .exitCode)
        case .error(let m):
            try c.encode("error", forKey: .type)
            try c.encode(m, forKey: .message)
        case .pasteResult(let mode, let path):
            try c.encode("paste-result", forKey: .type)
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(path, forKey: .path)
        case .openURL(let url, let id):
            try c.encode("open-url", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(id, forKey: .id)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

extension KeyedDecodingContainer {
    /// The string at `key`, or nil when missing or not a string.
    func string(_ key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }

    /// The integer at `key`: an integer, a finite float (truncated), or a
    /// numeric string; nil otherwise.
    func integer(_ key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let f = try? decodeIfPresent(Double.self, forKey: key) {
            guard f.isFinite else { return nil }
            return Int64(min(max(f.rounded(.towardZero), -9e15), 9e15))
        }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    /// A grid dimension: 0 when missing or out of range.
    func dimension(_ key: Key) -> UInt16 {
        guard let v = integer(key), v > 0, v <= Int64(UInt16.max) else { return 0 }
        return UInt16(v)
    }
}

public enum ClientFrame: Sendable, Equatable {
    /// Bytes for the pty. Encoded as a JSON string; bytes that are not
    /// valid UTF-8 become U+FFFD (see `jsonStringLiteral`).
    case input(Data)
    case resize(cols: UInt16, rows: UInt16)
    /// `data` is base64.
    case pasteImage(mime: String, data: String)
    /// `data` is base64.
    case clipboardSync(mime: String, data: String)

    /// Text for the pty.
    public static func input(_ text: String) -> ClientFrame { .input(Data(text.utf8)) }

    /// The frame as compact JSON, byte for byte what the reference client
    /// sends.
    public var wire: String {
        switch self {
        case .input(let data):
            return "{\"type\":\"input\",\"data\":\(jsonStringLiteral(data))}"
        case .resize(let cols, let rows):
            return "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        case .pasteImage(let mime, let data):
            return imageFrame("paste-image", mime, data)
        case .clipboardSync(let mime, let data):
            return imageFrame("clipboard-sync", mime, data)
        }
    }

    public var wireData: Data { Data(wire.utf8) }

    private func imageFrame(_ type: String, _ mime: String, _ data: String) -> String {
        "{\"type\":\"\(type)\",\"mime\":\(jsonStringLiteral(Data(mime.utf8))),\"data\":\(jsonStringLiteral(Data(data.utf8)))}"
    }
}

extension ClientFrame: Encodable {
    private enum Keys: String, CodingKey { case type, data, cols, rows, mime }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .input(let data):
            try c.encode("input", forKey: .type)
            try c.encode(lossyUTF8(data), forKey: .data)
        case .resize(let cols, let rows):
            try c.encode("resize", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .pasteImage(let mime, let data):
            try c.encode("paste-image", forKey: .type)
            try c.encode(mime, forKey: .mime)
            try c.encode(data, forKey: .data)
        case .clipboardSync(let mime, let data):
            try c.encode("clipboard-sync", forKey: .type)
            try c.encode(mime, forKey: .mime)
            try c.encode(data, forKey: .data)
        }
    }
}

// MARK: - JSON string literals with the host's U+FFFD rule

/// `bytes` as a JSON string literal. Valid UTF-8 passes through (with the
/// mandatory escapes); each maximal invalid subsequence becomes U+FFFD, the
/// same substitution the host's decodeUTF8 makes, so the host receives
/// exactly what it would have produced itself.
public func jsonStringLiteral(_ bytes: Data) -> String {
    var out = [UInt8]()
    out.reserveCapacity(bytes.count + 2)
    out.append(UInt8(ascii: "\""))
    let b = [UInt8](bytes)
    var i = 0
    while i < b.count {
        let c = b[i]
        if c >= 0x20 && c < 0x80 && c != UInt8(ascii: "\"") && c != UInt8(ascii: "\\") {
            out.append(c)
            i += 1
            continue
        }
        if c < 0x80 {
            switch c {
            case UInt8(ascii: "\""): out.append(contentsOf: [0x5c, 0x22])
            case UInt8(ascii: "\\"): out.append(contentsOf: [0x5c, 0x5c])
            case 0x0a: out.append(contentsOf: [0x5c, UInt8(ascii: "n")])
            case 0x0d: out.append(contentsOf: [0x5c, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5c, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5c, UInt8(ascii: "b")])
            case 0x0c: out.append(contentsOf: [0x5c, UInt8(ascii: "f")])
            default:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5c, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(c >> 4)], hex[Int(c & 0xf)]])
            }
            i += 1
            continue
        }
        let n = validSequenceLength(b, at: i)
        if n > 0 {
            out.append(contentsOf: b[i..<i + n])
            i += n
            continue
        }
        out.append(contentsOf: [0xef, 0xbf, 0xbd]) // U+FFFD
        i += invalidSkip(b, at: i)
    }
    out.append(UInt8(ascii: "\""))
    return String(decoding: out, as: UTF8.self)
}

/// `bytes` decoded as UTF-8 with the same maximal-subpart U+FFFD rule.
func lossyUTF8(_ bytes: Data) -> String {
    var out = [UInt8]()
    out.reserveCapacity(bytes.count)
    let b = [UInt8](bytes)
    var i = 0
    while i < b.count {
        if b[i] < 0x80 {
            out.append(b[i])
            i += 1
            continue
        }
        let n = validSequenceLength(b, at: i)
        if n > 0 {
            out.append(contentsOf: b[i..<i + n])
            i += n
        } else {
            out.append(contentsOf: [0xef, 0xbf, 0xbd])
            i += invalidSkip(b, at: i)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Lead byte → (continuation count, bounds of the first continuation byte).
private func leadInfo(_ c: UInt8) -> (need: Int, lo: UInt8, hi: UInt8)? {
    switch c {
    case 0xC2...0xDF: return (1, 0x80, 0xBF)
    case 0xE0: return (2, 0xA0, 0xBF)
    case 0xE1...0xEC, 0xEE...0xEF: return (2, 0x80, 0xBF)
    case 0xED: return (2, 0x80, 0x9F)
    case 0xF0: return (3, 0x90, 0xBF)
    case 0xF1...0xF3: return (3, 0x80, 0xBF)
    case 0xF4: return (3, 0x80, 0x8F)
    default: return nil
    }
}

/// Length of the valid multi-byte sequence at `b[i]`, or 0.
private func validSequenceLength(_ b: [UInt8], at i: Int) -> Int {
    guard let info = leadInfo(b[i]) else { return 0 }
    if b.count - i < 1 + info.need { return 0 }
    if b[i + 1] < info.lo || b[i + 1] > info.hi { return 0 }
    for x in b[(i + 2)..<(i + 1 + info.need)] where x < 0x80 || x > 0xBF { return 0 }
    return 1 + info.need
}

/// Bytes covered by one U+FFFD (the maximal subpart), at least 1.
private func invalidSkip(_ b: [UInt8], at i: Int) -> Int {
    guard let info = leadInfo(b[i]) else { return 1 }
    var j = 1
    var lo = info.lo
    var hi = info.hi
    var k = 0
    while k < info.need {
        if i + j >= b.count || b[i + j] < lo || b[i + j] > hi { break }
        lo = 0x80
        hi = 0xBF
        j += 1
        k += 1
    }
    return j
}
