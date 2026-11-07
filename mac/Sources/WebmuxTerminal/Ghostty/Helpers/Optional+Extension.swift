// Copied from ghostty macos/Sources/Helpers/Extensions/Optional+Extension.swift at 518ec334a and trimmed for webmux; see docs/macos-client.md.
// Unchanged apart from this header.
extension Optional where Wrapped == String {
    /// Executes a closure with a C string pointer, handling nil gracefully.
    func withCString<T>(_ body: (UnsafePointer<Int8>?) throws -> T) rethrows -> T {
        if let string = self {
            return try string.withCString(body)
        } else {
            return try body(nil)
        }
    }
}
