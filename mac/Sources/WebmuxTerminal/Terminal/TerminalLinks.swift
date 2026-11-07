// Links in a terminal pane (PARITY T-24, T-25, T-26, C-11; GTK reference
// terminal/links.zig and panels/model.zig `urlKind`): what counts as a link, how a
// URL under the pointer is found in a row of text, and the per-host dedupe of the
// host's `open-url` relay frames.
//
// Detection is done here, in Swift, over the row text read from the core
// (`ghostty_surface_read_text`) rather than by the core's own link matcher,
// because the core's default link needs ⌘ for hover and click and the config file
// syntax cannot change that (see TerminalConfig.swift). The regex is the xterm.js
// web-links addon's `strictUrlRegex`, the same one the GTK client installs.
import Foundation

/// What a URL is, for the click rules (T-24/T-25, GTK deviation 26).
public enum LinkKind: Equatable, Sendable {
    /// http(s): a plain click opens the browser, Shift+click copies.
    case http
    /// mailto: never opened by a click; the chooser offers Open (mail app) and Copy.
    case mailto
    /// Anything else (file:, ssh:, …): the chooser offers Copy only.
    case other
    /// The host's `open-url` relay (a program ran xdg-open): always the chooser,
    /// Cancel / Copy / Open in browser (C-11, M-04).
    case relay

    public init(url: String) {
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            self = .http
        } else if lower.hasPrefix("mailto:") {
            self = .mailto
        } else {
            self = .other
        }
    }

    /// Only http(s) links act on a click (T-25).
    public var isClickable: Bool { self == .http }
}

public enum TerminalLinks {
    /// xterm.js web-links `strictUrlRegex` (also gtk config.zig `url_regex`), in
    /// ICU syntax: http(s) only, no trailing punctuation. NUL is excluded because
    /// the core renders an empty cell as U+0000 in text dumps.
    static let urlPattern = #"(?:https?|HTTPS?)://[^\s\x00"'!*(){}|\\^<>`]*[^\s\x00"':,.!?{}|\\^~\[\]`()<>]"#

    static let urlRegex: NSRegularExpression = {
        // The pattern is a constant; a failure here is a bug caught by the tests.
        (try? NSRegularExpression(pattern: urlPattern)) ?? NSRegularExpression()
    }()

    /// A URL found in a row.
    public struct Match: Equatable {
        public var url: String
        /// Columns (character offsets into the row text) the URL covers.
        public var range: Range<Int>
    }

    /// Every URL in a row of terminal text, in order.
    public static func urls(in row: String) -> [Match] {
        let ns = row as NSString
        return urlRegex.matches(in: row, range: NSRange(location: 0, length: ns.length)).map { m in
            Match(url: ns.substring(with: m.range), range: m.range.location..<(m.range.location + m.range.length))
        }
    }

    /// The URL whose text covers `column` (a UTF-16 offset into `row`, which is
    /// one cell per character for the terminal's text dump), or nil.
    public static func url(in row: String, atColumn column: Int) -> Match? {
        urls(in: row).first { $0.range.contains(column) }
    }

    /// The grid cell under a point, in the pane's own coordinates (origin at the
    /// bottom-left, as AppKit has it): `topY` is measured from the top edge. The
    /// grid starts `TerminalConfig.padding` from the top-left corner (T-09,
    /// `window-padding-balance = false`).
    public static func cell(x: CGFloat, topY: CGFloat, cellSize: CGSize, columns: Int, rows: Int) -> (col: Int, row: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, columns > 0, rows > 0 else { return nil }
        let fx = (x - TerminalConfig.padding) / cellSize.width
        let fy = (topY - TerminalConfig.padding) / cellSize.height
        guard fx >= 0, fy >= 0 else { return nil }
        let col = Int(fx.rounded(.down))
        let row = Int(fy.rounded(.down))
        guard col < columns, row < rows else { return nil }
        return (col, row)
    }
}

/// C-11: an `open-url` frame is broadcast on every socket of the host when the
/// session that asked is unknown, so each `id` is shown at most once per host.
/// Keyed by the host's socket path; bounded so a long-lived app never grows.
@MainActor
public final class OpenURLDedupe {
    public static let shared = OpenURLDedupe()

    private var seen: [String: [String]] = [:]
    private let limit: Int

    public init(limit: Int = 256) {
        self.limit = limit
    }

    /// True the first time `id` is seen for `host`.
    public func shouldShow(id: String, host: String) -> Bool {
        var ids = seen[host] ?? []
        if ids.contains(id) { return false }
        ids.append(id)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        seen[host] = ids
        return true
    }

    public func reset(host: String) {
        seen[host] = nil
    }
}
