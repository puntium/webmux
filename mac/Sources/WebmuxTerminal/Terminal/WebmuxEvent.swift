// The webmux backend's events (gtk/ghostty/src/termio/Webmux.zig "Events"), as a
// Swift value. `ghostty_webmux_event_s` is only valid during the C callback and its
// strings are borrowed, so the callback converts it with `init(c:)` right away and
// hops to the main queue with the copy.
import Foundation
import GhosttyKit

public enum WebmuxEvent: Equatable {
    /// Socket open (first attach or reconnect).
    case linkUp
    /// Socket lost or first connect failed; the backend retries.
    case linkDown
    /// A snapshot was replayed. `cols`/`rows` are the local grid, `remoteCols`/
    /// `remoteRows` the grid the snapshot came from; `pid` is -1 when unknown.
    case snapshot(cols: Int, rows: Int, remoteCols: Int, remoteRows: Int, bytes: Int, pid: Int64)
    /// This session's title (also sent on every attach; may be empty).
    case title(String)
    /// Any session's title.
    case sessionTitle(session: String, title: String)
    /// The shell exited; final. The backend has already printed "[session exited: N]".
    case exit(code: Int64)
    /// No such session; final.
    case sessionError(message: String)
    /// A paste-image result: `mode` is "claude" or "path".
    case pasteResult(mode: String, path: String?)
    /// The host asked to open a URL; dedupe by `id`.
    case openURL(url: String, id: String)
    /// Socket lifecycle, for the connection log.
    case socket(Socket)

    public struct Socket: Equatable {
        public enum Kind: Equatable {
            case connecting, reconnecting, open, reopened, snapshot, closed, dropped, connectFailed
        }
        public var kind: Kind
        public var attempt: UInt32
        public var ms: Int64
        /// WebSocket close code (closed/dropped).
        public var code: Int64
        public var reason: String?
        public var clean: Bool
        public var retryInMs: UInt32
        public var bytes: Int
    }

    /// Copy a C event. Returns nil for a tag this build does not know.
    init?(c e: ghostty_webmux_event_s) {
        func str(_ p: UnsafePointer<CChar>?, _ len: Int) -> String? {
            guard let p else { return nil }
            let data = Data(bytes: p, count: len)
            return String(decoding: data, as: UTF8.self)
        }
        let text = str(e.text, Int(e.text_len))
        let aux = str(e.aux, Int(e.aux_len))

        switch e.tag {
        case GHOSTTY_WEBMUX_EVENT_LINK_UP:
            self = .linkUp
        case GHOSTTY_WEBMUX_EVENT_LINK_DOWN:
            self = .linkDown
        case GHOSTTY_WEBMUX_EVENT_SNAPSHOT:
            self = .snapshot(
                cols: Int(e.cols), rows: Int(e.rows),
                remoteCols: Int(e.remote_cols), remoteRows: Int(e.remote_rows),
                bytes: Int(e.bytes), pid: e.pid)
        case GHOSTTY_WEBMUX_EVENT_TITLE:
            self = .title(text ?? "")
        case GHOSTTY_WEBMUX_EVENT_SESSION_TITLE:
            self = .sessionTitle(session: aux ?? "", title: text ?? "")
        case GHOSTTY_WEBMUX_EVENT_EXIT:
            self = .exit(code: e.code)
        case GHOSTTY_WEBMUX_EVENT_SESSION_ERROR:
            self = .sessionError(message: text ?? "")
        case GHOSTTY_WEBMUX_EVENT_PASTE_RESULT:
            self = .pasteResult(mode: text ?? "", path: aux)
        case GHOSTTY_WEBMUX_EVENT_OPEN_URL:
            self = .openURL(url: text ?? "", id: aux ?? "")
        case GHOSTTY_WEBMUX_EVENT_SOCKET:
            guard let kind = Socket.Kind(c: e.socket_kind) else { return nil }
            self = .socket(Socket(
                kind: kind, attempt: e.attempt, ms: e.ms, code: e.code,
                reason: text, clean: e.clean, retryInMs: e.retry_in_ms, bytes: Int(e.bytes)))
        default:
            return nil
        }
    }
}

extension WebmuxEvent.Socket.Kind {
    init?(c: ghostty_webmux_socket_kind_e) {
        switch c {
        case GHOSTTY_WEBMUX_SOCKET_CONNECTING: self = .connecting
        case GHOSTTY_WEBMUX_SOCKET_RECONNECTING: self = .reconnecting
        case GHOSTTY_WEBMUX_SOCKET_OPEN: self = .open
        case GHOSTTY_WEBMUX_SOCKET_REOPENED: self = .reopened
        case GHOSTTY_WEBMUX_SOCKET_SNAPSHOT: self = .snapshot
        case GHOSTTY_WEBMUX_SOCKET_CLOSED: self = .closed
        case GHOSTTY_WEBMUX_SOCKET_DROPPED: self = .dropped
        case GHOSTTY_WEBMUX_SOCKET_CONNECT_FAILED: self = .connectFailed
        default: return nil
        }
    }
}
