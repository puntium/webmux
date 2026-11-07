// Copied from ghostty macos/Sources/Ghostty/Ghostty.Shell.swift at 518ec334a and
// trimmed for webmux; see docs/macos-client.md. Kept `escape` (used by the pasteboard
// helper when a file is dropped or pasted); dropped `quote`.
extension Ghostty {
    enum Shell {
        // Characters to escape in the shell.
        private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string by prefixing each with a
        /// backslash. Suitable for inserting paths/URLs into a live terminal buffer.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }

            return result
        }
    }
}
