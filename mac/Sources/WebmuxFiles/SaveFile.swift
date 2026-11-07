// Writing a download to the local disk without destroying anything the
// user did not agree to replace (reference: files/savefile.zig). The bytes
// go to a new file in the destination's directory, created exclusively
// under an unpredictable name `.<name>.<16 hex>.webmux-part`. Only a
// complete download is renamed onto the destination (the save panel asked
// before replacing an existing file); a failed or cancelled one removes
// its own temporary file and nothing else.
import Foundation

public struct SaveFileError: Error, Equatable, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

public final class SaveFile {
    /// Absolute path of the temporary file.
    public let temporaryURL: URL
    public let destination: URL
    private var committed = false

    /// Longest part of the destination's name kept in the temporary name,
    /// so the temporary name stays within 255 bytes.
    public static let maxNamePart = 200

    /// Create the temporary file next to `dest`.
    public init(destination dest: URL) throws {
        destination = dest
        let dir = dest.deletingLastPathComponent().path
        let base = Self.shorten(dest.lastPathComponent, max: Self.maxNamePart)
        var made: URL?
        for _ in 0..<16 {
            let hex = String(format: "%08x%08x", UInt32.random(in: 0...UInt32.max), UInt32.random(in: 0...UInt32.max))
            let path = "\(dir)/.\(base).\(hex).webmux-part"
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd >= 0 {
                close(fd)
                made = URL(fileURLWithPath: path)
                break
            }
            if errno == EEXIST { continue }
            throw SaveFileError(Self.reason(errno: errno))
        }
        guard let made else { throw SaveFileError("cannot create a temporary file") }
        temporaryURL = made
    }

    /// Move the complete file onto the destination. On failure the
    /// temporary file is removed and the destination untouched.
    public func commit() throws {
        committed = true
        if rename(temporaryURL.path, destination.path) != 0 {
            let e = errno
            unlink(temporaryURL.path)
            throw SaveFileError(Self.reason(errno: e))
        }
    }

    /// Remove the temporary file (after a failure or a cancel).
    public func discard() {
        if committed { return }
        committed = true
        unlink(temporaryURL.path)
    }

    deinit { discard() }

    /// At most `max` bytes of `s`, cut at a UTF-8 character boundary.
    public static func shorten(_ s: String, max: Int) -> String {
        let u = Array(s.utf8)
        if u.count <= max { return s }
        var n = max
        while n > 0 && (u[n] & 0xC0) == 0x80 { n -= 1 }
        return String(decoding: u[0..<n], as: UTF8.self)
    }

    /// Why a local write failed, for the status line and the log.
    public static func reason(errno e: Int32) -> String {
        switch e {
        case EACCES, EPERM: return "permission denied"
        case ENOSPC: return "no space left on the device"
        case EDQUOT: return "disk quota exceeded"
        case ENAMETOOLONG: return "name too long for the target folder"
        case EISDIR: return "a folder has that name"
        case ENOTDIR, ENOENT: return "the folder does not exist"
        case EROFS: return "read-only file system"
        case EFBIG: return "file too big for the target file system"
        case EEXIST: return "cannot create a temporary file"
        default: return String(cString: strerror(e))
        }
    }

    /// A Finder-style free name in `dir`: `name`, else `stem (1).ext`,
    /// `stem (2).ext`, …
    public static func freeName(in dir: URL, _ name: String) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let stem: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        var n = 1
        while true {
            let u = dir.appendingPathComponent("\(stem) (\(n))\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }
}
