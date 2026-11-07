// The persisted state of a files pane (F-02): `{"type":"files","dir":…,
// "cursor":…}`, the same document the Electron client keeps under
// `webmux-widgets` and the GTK client in its layout file's `widgets`.
// The text is untrusted (reference: files/wire.zig `parseState`): a
// directory that is not `~`, `~/…` or absolute, or a cursor that is not a
// plain name, falls back to the defaults (deviation 28).
import Foundation

public struct FilesPaneState: Equatable, Sendable {
    public var dir: String = "~"
    public var cursor: String? = nil

    public init(dir: String = "~", cursor: String? = nil) {
        self.dir = dir
        self.cursor = cursor
    }

    /// Parse the persisted JSON; anything unusable yields the defaults.
    public init(json: String?) {
        self.init()
        guard let json, let data = json.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let d = v["dir"] as? String, Self.validDir(d) { dir = d }
        if let c = v["cursor"] as? String, Self.validName(c) { cursor = c }
    }

    /// `{"type":"files","dir":…,"cursor":…}` with the keys in that order.
    public var json: String {
        func q(_ s: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            let arr = String(decoding: d, as: UTF8.self)
            return String(arr.dropFirst().dropLast())
        }
        return "{\"type\":\"files\",\"dir\":\(q(dir)),\"cursor\":\(cursor.map(q) ?? "null")}"
    }

    public static func validDir(_ d: String) -> Bool {
        if d.isEmpty || d.utf8.contains(0) { return false }
        return d == "~" || d.hasPrefix("~/") || d.hasPrefix("/")
    }

    public static func validName(_ n: String) -> Bool {
        if n.isEmpty || n == "." || n == ".." { return false }
        return !n.utf8.contains(UInt8(ascii: "/")) && !n.utf8.contains(0)
    }
}
