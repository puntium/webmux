// Copied from ghostty macos/Sources/Ghostty/Ghostty.Event.swift at 518ec334a and
// trimmed for webmux; see docs/macos-client.md. Unchanged apart from this header.
import Cocoa
import GhosttyKit

extension Ghostty {
    /// A comparable event.
    struct ComparableKeyEvent: Equatable {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags

        init(event: NSEvent) {
            self.keyCode = event.keyCode
            self.flags = event.modifierFlags
        }
    }
}
