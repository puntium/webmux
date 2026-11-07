// Small helpers shared by the package: clocks, JS/JSON-compatible
// formatting, file primitives (atomic write, append, mkdir -p with mode).
import Foundation
import CommonCrypto

enum Util {
    /// Monotonic milliseconds (CLOCK_MONOTONIC).
    static func monoMs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    /// Wall-clock milliseconds since the Unix epoch.
    static func wallMs() -> Int64 {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
    }

    /// JS `new Date().toISOString()`: `2026-11-04T12:34:56.789Z`.
    static func isoNow() -> String { iso(ms: wallMs()) }

    static func iso(ms: Int64) -> String {
        let secs = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000)
        let millis = ms - secs * 1000
        var t = time_t(secs)
        var tmv = tm()
        gmtime_r(&t, &tmv)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
                      Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), Int(millis))
    }

    /// JSON.stringify for a string: quotes, `\"`, `\\`, the short escapes and
    /// `\u00XX` for other control characters. Everything else verbatim.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0c}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }

    /// JS `String(number)` for the values we log (whole numbers print
    /// without a fraction).
    static func jsNumber(_ f: Double) -> String {
        if f.isNaN { return "NaN" }
        if f.isInfinite { return f > 0 ? "Infinity" : "-Infinity" }
        if f == 0 { return "0" }
        // Whole numbers below 1e21 print without a fraction, like JS; %.0f
        // prints a double's exact integer digits.
        if f.rounded(.down) == f && abs(f) < 1e21 { return String(format: "%.0f", f) }
        return "\(f)"
    }

    /// The first `max` Unicode scalars of `s` (JS `slice(0, max)`, counting
    /// code points rather than UTF-16 units).
    static func clipChars(_ s: String, _ max: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= max { return s }
        var out = String.UnicodeScalarView()
        for (i, u) in scalars.enumerated() {
            if i == max { break }
            out.append(u)
        }
        return String(out)
    }

    static func sha256Hex(_ parts: [String]) -> String {
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        for p in parts {
            let bytes = Array(p.utf8)
            bytes.withUnsafeBufferPointer { buf in
                _ = CC_SHA256_Update(&ctx, buf.baseAddress, CC_LONG(buf.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(bytes n: Int) -> String {
        var raw = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &raw)
        return hexString(raw)
    }

    static func isHexString(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    // -- files ------------------------------------------------------------

    struct FileError: Error, CustomStringConvertible {
        let op: String
        let path: String
        let errno: Int32
        var description: String { "\(op) \(path): \(String(cString: strerror(errno)))" }
        var name: String {
            switch errno {
            case ENOENT: return "FileNotFound"
            case EACCES, EPERM: return "AccessDenied"
            case ENOTDIR: return "NotDir"
            case ENAMETOOLONG: return "NameTooLong"
            case ENOSPC: return "NoSpaceLeft"
            case EROFS: return "ReadOnlyFileSystem"
            default: return "\(op)Failed"
            }
        }
    }

    /// `mkdir -p` for an absolute path; every directory it creates gets `mode`.
    static func makePath(_ path: String, mode: mode_t) throws {
        if path.isEmpty { return }
        var prefix = ""
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + comp
            if mkdir(prefix, mode) != 0 {
                let e = errno
                if e != EEXIST { throw FileError(op: "mkdir", path: prefix, errno: e) }
            }
        }
    }

    /// A directory we own, not a symlink, mode forced to 0700 — the run dir
    /// holds the tunnel sockets and the askpass helper.
    static func ensurePrivateDir(_ path: String) throws {
        var st = stat()
        if lstat(path, &st) != 0 { throw FileError(op: "stat", path: path, errno: errno) }
        if (st.st_mode & S_IFMT) != S_IFDIR { throw FileError(op: "notadir", path: path, errno: ENOTDIR) }
        if st.st_uid != getuid() { throw FileError(op: "notowned", path: path, errno: EPERM) }
        try chmod(path, mode: 0o700)
    }

    static func chmod(_ path: String, mode: mode_t) throws {
        if Darwin.chmod(path, mode) != 0 { throw FileError(op: "chmod", path: path, errno: errno) }
    }

    /// Append bytes to a file, creating it (0600) if needed.
    static func appendToFile(_ path: String, _ bytes: [UInt8]) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if fd < 0 { throw FileError(op: "open", path: path, errno: errno) }
        defer { close(fd) }
        try writeAll(fd: fd, bytes, path: path)
    }

    static func writeAll(fd: Int32, _ bytes: [UInt8], path: String = "") throws {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + off, buf.count - off)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw FileError(op: "write", path: path, errno: errno)
            }
            off += n
        }
    }

    /// Write a file atomically: `<path>.tmp-<pid>` with `mode`, fsync, rename.
    static func atomicWrite(_ path: String, _ bytes: [UInt8], mode: mode_t) throws {
        let tmp = "\(path).tmp-\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        if fd < 0 { throw FileError(op: "open", path: tmp, errno: errno) }
        var ok = false
        defer { if !ok { Darwin.unlink(tmp) } }
        do {
            defer { close(fd) }
            try writeAll(fd: fd, bytes, path: tmp)
            if fsync(fd) != 0 { throw FileError(op: "fsync", path: tmp, errno: errno) }
            // the tmp file gets exactly `mode` whatever the umask says
            Darwin.fchmod(fd, mode)
        }
        if rename(tmp, path) != 0 { throw FileError(op: "rename", path: path, errno: errno) }
        ok = true
    }

    static func atomicWrite(_ path: String, _ text: String, mode: mode_t) throws {
        try atomicWrite(path, Array(text.utf8), mode: mode)
    }

    /// Read a whole file (nil if it does not exist).
    static func readFile(_ path: String) throws -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw FileError(op: "open", path: path, errno: errno)
        }
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileError(op: "read", path: path, errno: errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    static func readString(_ path: String) -> String? {
        guard let d = try? readFile(path) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func fileExists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    static func unlink(_ path: String) {
        Darwin.unlink(path)
    }

    static func fileSize(_ path: String) -> UInt64? {
        var st = stat()
        if stat(path, &st) != 0 { return nil }
        return UInt64(st.st_size)
    }

    static func dirname(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func join(_ parts: String...) -> String {
        var out = parts[0]
        for p in parts.dropFirst() {
            if out.hasSuffix("/") { out += p } else { out += "/" + p }
        }
        return out
    }

    /// Non-blocking fd.
    static func setNonblock(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags < 0 { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }
}
