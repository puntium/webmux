// Copied from ghostty macos/Sources/Helpers/Extensions/Array+Extension.swift at 518ec334a and trimmed for webmux; see docs/macos-client.md.
// Kept withCStrings only.
extension Array where Element == String {
    /// Executes a closure with an array of C string pointers.
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>]) throws -> T) rethrows -> T {
        // Handle empty array
        if isEmpty {
            return try body([])
        }

        // Recursive helper to process strings
        func helper(index: Int, accumulated: [UnsafePointer<Int8>], body: ([UnsafePointer<Int8>]) throws -> T) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }

            return try self[index].withCString { cStr in
                var newAccumulated = accumulated
                newAccumulated.append(cStr)
                return try helper(index: index + 1, accumulated: newAccumulated, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}
