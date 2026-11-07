// Copied from ghostty macos/Sources/Helpers/Extensions/NSColor+Extension.swift at 518ec334a and trimmed for webmux; see docs/macos-client.md.
// Kept isLightColor/luminance/hexString and init(ghostty:); dropped the DOCK_TILE_PLUGIN guards, init(hex:) and darken.
import Foundation
import AppKit
import GhosttyKit

extension NSColor {
    var isLightColor: Bool {
        return self.luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed:green:blue:alpha requires sRGB space
        guard let rgb = self.usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(rgb.redComponent * 255)
        let green = Int(rgb.greenComponent * 255)
        let blue = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

// MARK: Ghostty Types
extension NSColor {
    /// Create a color from a Ghostty color.
    convenience init(ghostty: ghostty_config_color_s) {
        let red = Double(ghostty.r) / 255
        let green = Double(ghostty.g) / 255
        let blue = Double(ghostty.b) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
