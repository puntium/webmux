// The Connection Log window's pure parts (G-22…G-27; electron/logs.html;
// reference: panels/model.zig): the filter, the host list, the count and
// copy texts.
import Foundation
import WebmuxConnection

/// G-22: Host (`all`, a host, or `client (no host)`), Level (`debug+` …
/// `error`), and a case-insensitive substring of the file-format line.
public struct LogFilter: Equatable, Sendable {
    /// nil = all; `LogFilter.clientKey` = app-wide entries only.
    public var host: String? = nil
    public var level: LogLevel = .info
    public var text: String = ""

    public init(host: String? = nil, level: LogLevel = .info, text: String = "") {
        self.host = host
        self.level = level
        self.text = text
    }

    /// The popup entry for entries without a connection.
    public static let clientKey = "·client·"
    public static let clientLabel = "client (no host)"
    public static let levelLabels: [(LogLevel, String)] = [(.debug, "debug+"), (.info, "info+"), (.warn, "warn+"), (.error, "error")]

    public var isActive: Bool { host != nil || level != .debug || !text.isEmpty }

    public static func hostKey(_ conn: String?) -> String { conn ?? clientKey }

    public func passes(_ e: LogEntry) -> Bool {
        if e.level < level { return false }
        if let h = host, LogFilter.hostKey(e.conn) != h { return false }
        if !text.isEmpty {
            let q = text.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty && !e.line.lowercased().contains(q) { return false }
        }
        return true
    }

    /// G-27: `<N> entries`, or `<shown> of <N> entries` while filtered.
    public static func countText(shown: Int, total: Int) -> String {
        shown == total ? "\(total) entries" : "\(shown) of \(total) entries"
    }

    /// G-25: the flash after a copy.
    public static func copiedText(_ n: Int, visible: Bool) -> String {
        let unit = n == 1 ? "line" : "lines"
        return visible ? "copied \(n) visible \(unit)" : "copied \(n) \(unit)"
    }

    /// G-27 empty states.
    public static func emptyText(total: Int) -> String {
        total == 0 ? "No log entries yet." : "Nothing matches the current filters."
    }

    /// G-25: newline-joined with a trailing newline.
    public static func copyText(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// G-23: the local time `HH:MM:SS.mmm` of an ISO timestamp.
    public static func localTime(_ iso: String) -> String {
        guard let d = isoParser.date(from: iso) else { return iso }
        return timeFormatter.string(from: d)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// The hosts seen so far, in order of first appearance (G-22).
public struct LogHostList: Equatable, Sendable {
    public private(set) var hosts: [String] = []
    public private(set) var hasClient = false

    public init() {}

    /// Returns true when the list changed.
    @discardableResult
    public mutating func note(_ e: LogEntry) -> Bool {
        if let c = e.conn {
            if hosts.contains(c) { return false }
            hosts.append(c)
            return true
        }
        if hasClient { return false }
        hasClient = true
        return true
    }
}
