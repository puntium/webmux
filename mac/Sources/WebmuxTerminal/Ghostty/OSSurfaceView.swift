// Copied from ghostty macos/Sources/Ghostty/Surface View/OSSurfaceView.swift at 518ec334a
// and trimmed for webmux; see docs/macos-client.md.
//
// Dropped: ObservableObject/@Published (no SwiftUI here), progress report, key tables,
// search state, readonly, highlight and the child-exited message. The properties that
// remain are plain stored properties.
import Foundation
import AppKit
import GhosttyKit

extension Ghostty {
    public class OSSurfaceView: NSView {
        typealias ID = UUID

        /// Unique ID per surface
        public let id: UUID

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        public internal(set) var cellSize: CGSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        var healthy: Bool = true

        // Any error while initializing the surface.
        var error: Error?

        // The hovered URL string
        var hoverUrl: String?

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        var focusInstant: ContinuousClock.Instant?

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        public internal(set) var surfaceSize: ghostty_surface_size_s?

        public var surface: ghostty_surface_t? {
            nil
        }

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)
        }

        public required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        // MARK: - Placeholders

        func focusDidChange(_ focused: Bool) {}

        func sizeDidChange(_ size: CGSize) {}
    }
}
