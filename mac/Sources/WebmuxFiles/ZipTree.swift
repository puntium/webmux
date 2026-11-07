// A zip's table of contents as a tree (F-40). files-widget.js `zipTree` +
// the walk in `previewContent`: members are nested under their parents,
// folders first then names (case-insensitive), folders with a trailing
// '/', files with their uncompressed size. Directories with no entry of
// their own are implied by their children's paths; a member that has
// children is a directory whatever its own entry said.
import Foundation
import WebmuxHost

public final class ZipNode {
    public let name: String
    public internal(set) var isDirEntry: Bool
    public internal(set) var size: Double
    public internal(set) var children: [ZipNode] = []
    private var index: [String: ZipNode] = [:]

    init(name: String, isDirEntry: Bool = true, size: Double = 0) {
        self.name = name
        self.isDirEntry = isDirEntry
        self.size = size
    }

    public var isDir: Bool { isDirEntry || !children.isEmpty }

    func child(_ seg: String) -> ZipNode {
        if let c = index[seg] { return c }
        let c = ZipNode(name: seg)
        index[seg] = c
        children.append(c)
        return c
    }

    /// Sort the children (folders first, then case-insensitive names),
    /// recursively.
    func sort() {
        children.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return ZipTree.compareNames(a.name, b.name) == .orderedAscending
        }
        for c in children { c.sort() }
    }
}

public struct ZipRow: Equatable {
    /// Connector prefix: indents + "├── " or "└── ".
    public var prefix: String
    /// Member name, with '/' appended for folders.
    public var name: String
    public var dir: Bool
    /// Uncompressed size (files only).
    public var size: Double
}

public enum ZipTree {
    /// The tree of `entries`, sorted for display.
    public static func build(_ entries: [ZipEntry]) -> ZipNode {
        let root = ZipNode(name: "")
        for e in entries {
            var node = root
            for seg in e.name.split(separator: "/", omittingEmptySubsequences: true) {
                node = node.child(String(seg))
            }
            if node !== root && !e.dir {
                node.isDirEntry = false
                node.size = e.size
            }
        }
        root.sort()
        return root
    }

    /// The `tree`-style rows.
    public static func rows(_ entries: [ZipEntry]) -> [ZipRow] {
        var out: [ZipRow] = []
        walk(build(entries), indent: "", into: &out)
        return out
    }

    private static func walk(_ node: ZipNode, indent: String, into out: inout [ZipRow]) {
        for (i, kid) in node.children.enumerated() {
            let last = i == node.children.count - 1
            let dir = kid.isDir
            out.append(ZipRow(prefix: indent + (last ? "└── " : "├── "), name: dir ? kid.name + "/" : kid.name, dir: dir, size: dir ? 0 : kid.size))
            walk(kid, indent: indent + (last ? "    " : "│   "), into: &out)
        }
    }

    /// Case-insensitive name order (localeCompare with sensitivity 'base').
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
    }
}
