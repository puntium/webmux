// Pure path and formatting helpers for the file browser. Ports of the small
// functions at the top of electron/ui/files-widget.js (reference:
// gtk/ghostty/src/apprt/webmux/files/paths.zig). Paths are the host's:
// absolute, '/'-separated, never ending in '/' except the root itself.
import Foundation

public enum FilesPaths {
    /// `dir/name` (`/name` under the root). files-widget.js `fsJoin`.
    public static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// The parent directory; "/" for top-level entries and for "/" itself.
    public static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "/" }
        return i == p.startIndex ? "/" : String(p[..<i])
    }

    /// The last segment; "/" for the root.
    public static func base(_ p: String) -> String {
        if p == "/" { return "/" }
        guard let i = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: i)...])
    }

    /// '/a/b' → ['/', '/a', '/a/b']. files-widget.js `fsChain`.
    public static func chain(_ dir: String) -> [String] {
        var out = ["/"]
        var acc = ""
        for seg in dir.split(separator: "/", omittingEmptySubsequences: true) {
            acc += "/" + seg
            out.append(acc)
        }
        return out
    }

    /// `.md .markdown .mdown .mkd`, any case.
    public static func isMarkdownName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".md", ".markdown", ".mdown", ".mkd"].contains { lower.hasSuffix($0) }
    }

    /// `~` + rest when `p` is the home directory or inside it, else `p`.
    /// `home` nil (unknown, or "/") disables the abbreviation.
    public static func tilde(home: String?, _ p: String) -> String {
        guard let h = home, !h.isEmpty, h != "/" else { return p }
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    /// Shorten a display path to `maxWidth` while keeping its last segment
    /// whole for as long as possible: interior directories collapse into
    /// one '…' starting next to the anchor ('~' or the root), then the
    /// anchor goes, then only the name is left (the label ellipsises it
    /// from there). F-15; files-widget.js `fitPath`.
    ///   ~/src/webmux/electron/ui/app.js → ~/…/electron/ui/app.js
    ///   → ~/…/ui/app.js → ~/…/app.js → …/app.js → app.js
    public static func fitPath(_ display: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        if measure(display) <= maxWidth { return display }
        var dirs = display.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = dirs.popLast(), !name.isEmpty else { return display } // '/' itself
        var tail = dirs.count - 2
        while tail >= 0 {
            let kept = dirs.suffix(tail)
            let s = ([dirs[0], "…"] + kept).joined(separator: "/") + "/" + name
            if measure(s) <= maxWidth { return s }
            tail -= 1
        }
        let s = "…/" + name
        return measure(s) <= maxWidth ? s : name
    }

    /// `N B` under 1024, else KB/MB/GB/TB with one decimal below 10 and
    /// none above (JS toFixed rounding: half away from zero). F-31.
    public static func formatSize(_ bytes: Double) -> String {
        if bytes.isNaN || bytes < 1024 {
            let b = bytes > 0 ? UInt64(bytes) : 0
            return "\(b) B"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var v = bytes / 1024
        var u = 0
        while v >= 1024 && u < units.count - 1 {
            v /= 1024
            u += 1
        }
        if v < 10 {
            let r = (v * 10 + 0.5).rounded(.down) / 10
            return String(format: "%.1f %@", r, units[u])
        }
        let r = (v + 0.5).rounded(.down)
        return String(format: "%.0f %@", r, units[u])
    }

    /// Resolve a link from a markdown file against that file's directory.
    /// Nil for anything with a scheme (http:, mailto:, …). The result is
    /// absolute and normalised ('.' and '..' applied, no empty segments).
    public static func resolveRelative(baseDir: String, href: String) -> String? {
        if hasScheme(href) { return nil }
        var segs: [String] = href.hasPrefix("/") ? [] : baseDir.split(separator: "/").map(String.init)
        for seg in href.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." { _ = segs.popLast() } else { segs.append(String(seg)) }
        }
        return "/" + segs.joined(separator: "/")
    }

    /// `^[a-z][a-z0-9+.-]*:` (case-insensitive).
    public static func hasScheme(_ href: String) -> Bool {
        let u = Array(href.utf8)
        guard let first = u.first, (first | 0x20) >= 0x61 && (first | 0x20) <= 0x7a else { return false }
        for c in u.dropFirst() {
            if c == UInt8(ascii: ":") { return true }
            let alnum = (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a)
            if !(alnum || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || c == UInt8(ascii: "-")) { return false }
        }
        return false
    }

    /// Decode %XX escapes (a relative markdown link to "my%20file.md" names
    /// "my file.md"). Invalid escapes are kept as they are.
    public static func percentDecode(_ s: String) -> String {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "%"), i + 2 < u.count, let hi = hexValue(u[i + 1]), let lo = hexValue(u[i + 2]) {
                out.append(hi * 16 + lo)
                i += 3
                continue
            }
            out.append(u[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// The rename preselection (F-50): everything before the last '.', or
    /// the whole name for dot-files and names without an extension.
    public static func renameStem(_ name: String) -> Range<String.Index> {
        if name.hasPrefix(".") { return name.startIndex..<name.endIndex }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name.startIndex..<name.endIndex }
        return name.startIndex..<dot
    }

    /// Image preview extensions (F-33; the host decides the kind, this is
    /// used for the PDF special case and tests).
    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
