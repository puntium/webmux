// What a drop, paste or open-panel choice uploads (F-54, F-57): each
// dropped file under its own name, each dropped folder walked recursively
// with its files named by their path relative to the folder's parent
// (`photos/2024/a.jpg`), empty folders skipped. Symlinks are followed; a
// link back up the tree is cut off at `maxDepth`. Files that cannot be
// opened for reading are skipped (reference: files/uploads.zig).
import Foundation

public struct LocalUpload: Equatable, Sendable {
    /// Absolute local path.
    public var url: URL
    /// Upload name: the basename, or `folder/…/basename` inside a folder.
    public var name: String
    public var size: Int64

    public init(url: URL, name: String, size: Int64) {
        self.url = url
        self.name = name
        self.size = size
    }
}

public enum LocalUploads {
    public static let maxDepth = 32
    /// The host's per-file limit (fs.go: 200 MiB).
    public static let uploadLimit: Int64 = 200 * 1024 * 1024

    /// Collect the files to upload for `roots` (in drop order).
    public static func collect(_ roots: [URL]) -> [LocalUpload] {
        var out: [LocalUpload] = []
        let fm = FileManager.default
        for root in roots {
            let path = root.path
            guard let st = try? fm.attributesOfItem(atPath: resolved(path)) else { continue }
            let kind = st[.type] as? FileAttributeType
            let name = root.lastPathComponent
            if kind == .typeDirectory {
                walk(path, rel: name, depth: 0, into: &out)
            } else if kind == .typeRegular, readable(path) {
                out.append(LocalUpload(url: URL(fileURLWithPath: path), name: name, size: (st[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return out
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func readable(_ path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    private static func walk(_ dir: String, rel: String, depth: Int, into out: inout [LocalUpload]) {
        if depth >= maxDepth { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for n in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let child = dir + "/" + n
            guard let st = try? fm.attributesOfItem(atPath: resolved(child)) else { continue }
            switch st[.type] as? FileAttributeType {
            case .typeDirectory?:
                walk(child, rel: rel + "/" + n, depth: depth + 1, into: &out)
            case .typeRegular?:
                if readable(child) {
                    out.append(LocalUpload(url: URL(fileURLWithPath: child), name: rel + "/" + n, size: (st[.size] as? NSNumber)?.int64Value ?? 0))
                }
            default:
                break
            }
        }
    }
}
