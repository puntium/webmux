// Copied from ghostty macos/Sources/Ghostty/GhosttyPackage.swift (merged with
// GhosttyPackageMeta.swift) at 518ec334a and trimmed for webmux; see docs/macos-client.md.
//
// Dropped: user-notification identifiers, launch source, split/tab/float/secure-input
// enums, the macOS window/titlebar config enums, and every notification name a
// single-surface host never posts (tabs, splits, fullscreen, inspector, search,
// scrollbar, key sequences/tables, readonly, command palette, maximize).
import AppKit
import Foundation
import os
import GhosttyKit

// This defines the minimal information required so all other files can do
// `extension Ghostty` to add more to it.
public enum Ghostty {
    // The primary logger used by the GhosttyKit wrapper.
    static let logger = Logger(
        subsystem: "me.puntium.webmux.mac",
        category: "ghostty"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}
}

// MARK: Build Info

extension Ghostty {
    public struct Info {
        public var mode: ghostty_build_mode_e
        public var version: String
    }

    public static var info: Info {
        let raw = ghostty_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: Swift Types for C Types

extension Ghostty {
    class AllocatedString {
        private let cString: ghostty_string_s

        init(_ c: ghostty_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            ghostty_string_free(cString)
        }
    }
}

extension Ghostty {
    /// One representation of clipboard contents. The data is binary-safe;
    /// textual consumers use `string`.
    struct ClipboardContent {
        let mime: String
        let data: Data

        /// The data as text, if it is valid UTF-8.
        var string: String? { String(data: data, encoding: .utf8) }

        static func from(content: ghostty_clipboard_content_s) -> ClipboardContent {
            ClipboardContent(
                mime: String(cString: content.mime),
                data: Data(bytes: content.data, count: content.len)
            )
        }
    }
}

// MARK: Surface Notification

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    public static let ghosttyConfigDidChange = Notification.Name("com.mitchellh.ghostty.configDidChange")
    public static let GhosttyConfigChangeKey = ghosttyConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    public static let ghosttyColorDidChange = Notification.Name("com.mitchellh.ghostty.ghosttyColorDidChange")
    public static let GhosttyColorChangeKey = ghosttyColorDidChange.rawValue

    /// Close window
    public static let ghosttyCloseWindow = Notification.Name("com.mitchellh.ghostty.closeWindow")

    /// Ring the bell
    public static let ghosttyBellDidRing = Notification.Name("com.mitchellh.ghostty.ghosttyBellDidRing")

    /// The active selection changed
    public static let ghosttySelectionDidChange = Notification.Name("com.mitchellh.ghostty.ghosttySelectionDidChange")

    /// webmux: the core asked to open a URL (a click on a link). Object is the
    /// surface; userInfo[GhosttyOpenURLKey] is a `Ghostty.Action.OpenURL`. The
    /// shell decides what to do (PARITY T-24/T-25); the wrapper never opens it.
    public static let ghosttyOpenURL = Notification.Name("me.puntium.webmux.mac.ghosttyOpenURL")
    public static let GhosttyOpenURLKey = ghosttyOpenURL.rawValue
}

extension Ghostty.Notification {
    /// Close the calling surface.
    static let ghosttyCloseSurface = Notification.Name("com.mitchellh.ghostty.closeSurface")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("com.mitchellh.ghostty.didUpdateRendererHealth")
}

// Make the input enum hashable.
extension ghostty_input_key_e: @retroactive Hashable {}
