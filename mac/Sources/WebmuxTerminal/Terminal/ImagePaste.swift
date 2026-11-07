// Images on the pasteboard, for the image-paste flow (PARITY C-06, C-07, C-10,
// ruling A-11) and the proactive clipboard sync (C-09, H-03). GTK reference:
// terminal/clipboard.zig.
//
// The host stores image/png, jpeg, gif, webp and bmp and silently drops anything
// else (host/internal/server/paste.go). The pasteboard is read in a type the host
// takes when it has one (PNG preferred), and anything else AppKit can decode (TIFF,
// HEIC, …) is converted to PNG (A-11). Nothing here logs pasteboard contents.
import AppKit
import UniformTypeIdentifiers

public enum ImagePaste {
    /// An image ready for a `paste-image` or `clipboard-sync` frame.
    public struct Encoded: Equatable {
        public var mime: String
        public var base64: String
    }

    /// The host's accepted image types, with the pasteboard type each comes from.
    static let hostTypes: [(mime: String, type: NSPasteboard.PasteboardType)] = [
        ("image/png", .png),
        ("image/jpeg", NSPasteboard.PasteboardType(UTType.jpeg.identifier)),
        ("image/gif", NSPasteboard.PasteboardType(UTType.gif.identifier)),
        ("image/webp", NSPasteboard.PasteboardType(UTType.webP.identifier)),
        ("image/bmp", NSPasteboard.PasteboardType(UTType.bmp.identifier)),
    ]

    /// True if the pasteboard carries an image of any type (the Electron
    /// `image/*` check). Declared types only; no data is read.
    public static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { type in
            if type == .tiff || type == .png { return true }
            guard let ut = UTType(type.rawValue) else { return false }
            return ut.conforms(to: .image)
        }
    }

    /// The pasteboard's image in a type the host accepts, converted to PNG when
    /// needed. nil when there is no image or it cannot be decoded.
    public static func encode(_ pasteboard: NSPasteboard) -> Encoded? {
        guard hasImage(pasteboard) else { return nil }
        let available = Set(pasteboard.types ?? [])
        for (mime, type) in hostTypes where available.contains(type) {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return Encoded(mime: mime, base64: data.base64EncodedString())
            }
        }
        // Anything else AppKit can decode: TIFF (the usual macOS screenshot
        // or copy-from-Preview form), HEIC, …
        guard let image = NSImage(pasteboard: pasteboard), let png = pngData(image) else { return nil }
        return Encoded(mime: "image/png", base64: png.base64EncodedString())
    }

    /// PNG bytes for an image, through its best bitmap representation.
    static func pngData(_ image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

/// C-09: the clipboard image sync state per host (socket path): throttled to one
/// look per second, and the same image is never sent twice to a host.
@MainActor
public final class ClipboardSyncState {
    public static let shared = ClipboardSyncState()

    /// The Electron client's throttle (`syncClipboardImage`).
    public static let throttle: TimeInterval = 1.0

    private struct Host {
        var lastLook: Date?
        var lastHash: Int?
    }
    private var hosts: [String: Host] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// True if a look at the clipboard is due for `host` (and records it).
    public func shouldLook(host: String) -> Bool {
        let t = now()
        var h = hosts[host] ?? Host()
        if let last = h.lastLook, t.timeIntervalSince(last) < Self.throttle { return false }
        h.lastLook = t
        hosts[host] = h
        return true
    }

    /// True if `encoded` differs from the last image sent to `host`.
    public func isNew(_ encoded: ImagePaste.Encoded, host: String) -> Bool {
        hosts[host]?.lastHash != encoded.base64.hashValue
    }

    /// Remember `encoded` as the image `host` last received.
    public func recordSent(_ encoded: ImagePaste.Encoded, host: String) {
        var h = hosts[host] ?? Host()
        h.lastHash = encoded.base64.hashValue
        hosts[host] = h
    }

    public func reset(host: String) {
        hosts[host] = nil
    }
}
