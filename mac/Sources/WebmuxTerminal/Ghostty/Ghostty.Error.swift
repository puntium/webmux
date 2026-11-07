// Copied from ghostty macos/Sources/Ghostty/Ghostty.Error.swift at 518ec334a and
// trimmed for webmux; see docs/macos-client.md. Unchanged apart from this header.
import Foundation

extension Ghostty {
    /// Possible errors from internal Ghostty calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case apiFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libghostty API call failed"
            }
        }
    }
}
