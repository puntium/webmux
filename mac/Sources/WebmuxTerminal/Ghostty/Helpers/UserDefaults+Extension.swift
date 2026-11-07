// Copied from ghostty macos/Sources/Helpers/Extensions/UserDefaults+Extension.swift at 518ec334a and trimmed for webmux; see docs/macos-client.md.
// Unchanged apart from this header.
import Foundation

extension UserDefaults {
    static var ghosttySuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["GHOSTTY_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    static var ghostty: UserDefaults {
        ghosttySuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
