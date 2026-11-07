// Copied from ghostty macos/Sources/Ghostty/Ghostty.Action.swift at 518ec334a and
// trimmed for webmux; see docs/macos-client.md.
//
// Kept ColorChange (as NSColor), OpenURL and Scrollbar; dropped MoveTab, ProgressReport,
// StartSearch, PromptTitle and KeyTable (tabs, progress bar, search and key tables are
// not part of this shell).
import AppKit
import GhosttyKit

extension Ghostty {
    public struct Action {}
}

extension Ghostty.Action {
    struct ColorChange {
        let kind: Kind
        let color: NSColor

        enum Kind {
            case foreground
            case background
            case cursor
            case palette(index: UInt8)
        }

        init(c: ghostty_action_color_change_s) {
            switch c.kind {
            case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
                self.kind = .foreground
            case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
                self.kind = .background
            case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
                self.kind = .cursor
            default:
                self.kind = .palette(index: UInt8(truncatingIfNeeded: c.kind.rawValue))
            }

            self.color = NSColor(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1)
        }
    }

    public struct OpenURL {
        /// Where the URL came from. `unknown` and `osc8` may come from
        /// terminal output and must be treated as untrusted.
        public enum Kind {
            /// May be a plain path, such as `~/notes.txt`, instead of a URL.
            case unknown
            case text
            case html
            case osc8

            init(_ c: ghostty_action_open_url_kind_e) {
                switch c {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT:
                    self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
                    self = .html
                case GHOSTTY_ACTION_OPEN_URL_KIND_OSC8:
                    self = .osc8
                default:
                    self = .unknown
                }
            }
        }

        public let kind: Kind
        public let url: String

        init(c: ghostty_action_open_url_s) {
            self.kind = Kind(c.kind)
            let data = Data(bytes: c.url, count: Int(c.len))
            self.url = String(data: data, encoding: .utf8) ?? ""
        }
    }

    struct Scrollbar {
        let total: UInt64
        let offset: UInt64
        let len: UInt64

        init(c: ghostty_action_scrollbar_s) {
            total = c.total
            offset = c.offset
            len = c.len
        }
    }
}
