// Copied from ghostty macos/Sources/Ghostty/Ghostty.Config.swift at 518ec334a and
// trimmed for webmux; see docs/macos-client.md.
//
// webmux never reads ~/.config/ghostty, CLI args or `config-file` includes: the
// configuration is built from a string (Terminal/TerminalConfig.swift) through the
// fork's `ghostty_config_load_string`, and `ghostty_config_webmux_links` (after
// finalize) makes URLs underline on hover and open on a plain click, as the GTK
// client's config.zig does. Dropped: every window/tab/quick-terminal/notification
// getter; SwiftUI `Color` became `NSColor`.
import AppKit
import GhosttyKit

extension Ghostty {
    /// Maps to a `ghostty_config_t` and the various operations on that.
    public class Config {
        // The underlying C pointer to the Ghostty config structure. This
        // should never be accessed directly. Any operations on this should
        // be called from the functions on this or another class.
        private(set) var config: ghostty_config_t? {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        /// True if the configuration is loaded
        public var loaded: Bool { config != nil }

        /// Return the errors found while loading the configuration.
        public var errors: [String] {
            guard let cfg = self.config else { return [] }

            var diags: [String] = []
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            for i in 0..<diagsCount {
                let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                let message = String(cString: diag.message)
                diags.append(message)
            }

            return diags
        }

        init(config: ghostty_config_t?) {
            self.config = config
        }

        /// webmux: build a finalized configuration from config-file text
        /// (Ghostty's own syntax, one `key = value` per line).
        public convenience init(text: String) {
            self.init(config: Self.loadConfig(text: text))
        }

        convenience init(clone config: ghostty_config_t) {
            self.init(config: ghostty_config_clone(config))
        }

        func clone(config: ghostty_config_t) {
            self.config = config
        }

        deinit {
            self.config = nil
        }

        /// Initializes a new configuration from the given text and finalizes
        /// it. Diagnostics are logged; they are bugs in the text.
        static func loadConfig(text: String) -> ghostty_config_t? {
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                return nil
            }

            var bytes = Array(text.utf8)
            bytes.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                    ghostty_config_load_string(cfg, ptr, UInt(buf.count))
                }
            }

            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)
            // Links as in the Electron client: underline on hover, open on a
            // plain click, xterm.js's URL regex (PARITY T-24/T-25).
            ghostty_config_webmux_links(cfg)

            // Log any configuration errors.
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            if diagsCount > 0 {
                logger.warning("config error: \(diagsCount, privacy: .public) configuration errors")
                for i in 0..<diagsCount {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let message = String(cString: diag.message)
                    logger.warning("config error: \(message, privacy: .public)")
                }
            }

            return cfg
        }

        // MARK: - Configuration Values

        /// For all of the configuration values below, see the associated Ghostty documentation for
        /// details on what each means. We only add documentation if there is a strange conversion
        /// due to the embedded library and Swift.

        public var backgroundColor: NSColor {
            var color: ghostty_config_color_s = .init()
            let bg_key = "background"
            guard let config = self.config,
                  ghostty_config_get(config, &color, bg_key, UInt(bg_key.lengthOfBytes(using: .utf8))) else {
                return NSColor.windowBackgroundColor
            }

            return NSColor(ghostty: color)
        }

        public var foregroundColor: NSColor {
            var color: ghostty_config_color_s = .init()
            let key = "foreground"
            guard let config = self.config,
                  ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
                return NSColor.textColor
            }

            return NSColor(ghostty: color)
        }

        public var fontSize: Float {
            guard let config = self.config else { return 0 }
            var v: Float = 0
            let key = "font-size"
            _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
            return v
        }

        var shouldQuitAfterLastWindowClosed: Bool {
            guard let config = self.config else { return true }
            var v = false
            let key = "quit-after-last-window-closed"
            _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
            return v
        }
    }
}
