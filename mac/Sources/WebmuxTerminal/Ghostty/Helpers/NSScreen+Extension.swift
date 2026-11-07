// Copied from ghostty macos/Sources/Helpers/Extensions/NSScreen+Extension.swift at 518ec334a and trimmed for webmux; see docs/macos-client.md.
// Kept displayID only.
import Cocoa

extension NSScreen {
    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
