// A small JSON value, parser and writer for the layout file and the file
// browsers' states. Foundation's JSONSerialization loses key order (the
// Zig and app.js keep insertion order), so the saved document would not be
// byte-stable; this one keeps members in order, lets a repeated key keep
// its last value (JSON.parse), never recurses (an explicit stack, so a
// hostile 20000-deep document cannot overflow anything), and stops
// *building* past `JSONParser.buildDepth`: deeper containers parse (syntax
// is still checked) but come back as `.tooDeep`, which `depth(from:)`
// reports as beyond `Layout.maxStateDepth`. Internal to the module; the
// pane state stays a String of JSON text for callers.

import Foundation

struct JSONMember: Equatable {
    var key: String
    var value: JSONValue
}

indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    /// `isInteger`: the literal had no fraction or exponent (Zig's
    /// `.integer`; app.js has only Numbers, but the version check wants it).
    case number(Double, isInteger: Bool)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])
    /// A container nested deeper than `JSONParser.buildDepth`.
    case tooDeep

    /// Last-wins member lookup (duplicates were folded while parsing).
    func member(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// Depth of a JSON value (a scalar is 0, `{}` is 1); stops counting past
    /// `Layout.maxStateDepth` so a hostile document costs at most that many
    /// levels (Layout.zig `jsonDepth`).
    func depth(from level: Int) -> Int {
        if level > Layout.maxStateDepth { return level }
        switch self {
        case .array(let items):
            var deepest = level + 1
            for item in items { deepest = max(deepest, item.depth(from: level + 1)) }
            return deepest
        case .object(let members):
            var deepest = level + 1
            for m in members { deepest = max(deepest, m.value.depth(from: level + 1)) }
            return deepest
        case .tooDeep:
            return max(level + 1, Layout.maxStateDepth + 1)
        default:
            return level
        }
    }
}

enum JSONParser {
    /// Containers nested deeper than this are not built (see `.tooDeep`).
    static let buildDepth = Layout.maxStateDepth + 2

    /// Strict JSON (RFC 8259): nil on any syntax error, trailing content,
    /// control characters in strings or invalid escapes.
    static func parse(_ text: String) -> JSONValue? {
        var p = Parser(bytes: Array(text.utf8))
        return p.parseDocument()
    }

    private enum Frame {
        case array([JSONValue], discard: Bool)
        case object([JSONMember], index: [String: Int], key: String?, discard: Bool)
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }
        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func skipWhitespace() {
            while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
        }

        mutating func parseDocument() -> JSONValue? {
            var stack: [Frame] = []
            skipWhitespace()
            // Each turn of the loop either opens a container, or produces a
            // scalar / closed container (`value`) that is then folded into
            // the frame on top of the stack.
            var value: JSONValue? = nil
            while true {
                if value == nil {
                    guard let c = peek else { return nil }
                    switch c {
                    case UInt8(ascii: "{"):
                        i += 1
                        skipWhitespace()
                        let discard = stack.count >= buildDepth
                        if peek == UInt8(ascii: "}") {
                            i += 1
                            value = discard ? .tooDeep : .object([])
                            continue
                        }
                        guard let key = parseString() else { return nil }
                        skipWhitespace()
                        guard peek == UInt8(ascii: ":") else { return nil }
                        i += 1
                        skipWhitespace()
                        stack.append(.object([], index: [:], key: key, discard: discard))
                        continue
                    case UInt8(ascii: "["):
                        i += 1
                        skipWhitespace()
                        let discard = stack.count >= buildDepth
                        if peek == UInt8(ascii: "]") {
                            i += 1
                            value = discard ? .tooDeep : .array([])
                            continue
                        }
                        stack.append(.array([], discard: discard))
                        continue
                    case UInt8(ascii: "\""):
                        guard let s = parseString() else { return nil }
                        value = .string(s)
                    case UInt8(ascii: "t"):
                        guard consume("true") else { return nil }
                        value = .bool(true)
                    case UInt8(ascii: "f"):
                        guard consume("false") else { return nil }
                        value = .bool(false)
                    case UInt8(ascii: "n"):
                        guard consume("null") else { return nil }
                        value = .null
                    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                        guard let n = parseNumber() else { return nil }
                        value = n
                    default:
                        return nil
                    }
                }
                // Fold `value` into the open container, or finish.
                guard let v = value else { return nil }
                value = nil
                guard let top = stack.popLast() else {
                    skipWhitespace()
                    return atEnd ? v : nil
                }
                skipWhitespace()
                switch top {
                case .array(var items, let discard):
                    if !discard { items.append(v) }
                    if peek == UInt8(ascii: ",") {
                        i += 1
                        skipWhitespace()
                        stack.append(.array(items, discard: discard))
                    } else if peek == UInt8(ascii: "]") {
                        i += 1
                        value = discard ? .tooDeep : .array(items)
                    } else {
                        return nil
                    }
                case .object(var members, var index, let key, let discard):
                    if !discard, let k = key {
                        if let at = index[k] {
                            members[at].value = v
                        } else {
                            index[k] = members.count
                            members.append(JSONMember(key: k, value: v))
                        }
                    }
                    if peek == UInt8(ascii: ",") {
                        i += 1
                        skipWhitespace()
                        guard let next = parseString() else { return nil }
                        skipWhitespace()
                        guard peek == UInt8(ascii: ":") else { return nil }
                        i += 1
                        skipWhitespace()
                        stack.append(.object(members, index: index, key: next, discard: discard))
                    } else if peek == UInt8(ascii: "}") {
                        i += 1
                        value = discard ? .tooDeep : .object(members)
                    } else {
                        return nil
                    }
                }
            }
        }

        mutating func consume(_ literal: StaticString) -> Bool {
            let n = literal.utf8CodeUnitCount
            guard i + n <= bytes.count else { return false }
            let ok = literal.withUTF8Buffer { buf -> Bool in
                for k in 0..<n where bytes[i + k] != buf[k] { return false }
                return true
            }
            if ok { i += n }
            return ok
        }

        /// At an opening quote; returns the unescaped string.
        mutating func parseString() -> String? {
            guard peek == UInt8(ascii: "\"") else { return nil }
            i += 1
            var out: [UInt8] = []
            while true {
                guard let c = peek else { return nil }
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let e = peek else { return nil }
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let hi = parseHex4() else { return nil }
                        var scalar: UInt32 = hi
                        if (0xD800...0xDBFF).contains(hi) {
                            // A high surrogate: pair it with a following \uDC00…\uDFFF,
                            // else the replacement character (lenient, like Zig's scanner).
                            if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                                let save = i
                                i += 2
                                if let lo = parseHex4(), (0xDC00...0xDFFF).contains(lo) {
                                    scalar = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                                } else {
                                    i = save
                                    scalar = 0xFFFD
                                }
                            } else {
                                scalar = 0xFFFD
                            }
                        } else if (0xDC00...0xDFFF).contains(hi) {
                            scalar = 0xFFFD
                        }
                        guard let u = Unicode.Scalar(scalar) else { return nil }
                        out.append(contentsOf: Array(String(Character(u)).utf8))
                    default:
                        return nil
                    }
                case 0x00...0x1F:
                    return nil // control characters must be escaped
                default:
                    out.append(c)
                }
            }
        }

        mutating func parseHex4() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 {
                let c = bytes[i + k]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A")) + 10
                default: return nil
                }
                v = v * 16 + d
            }
            i += 4
            return v
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
        mutating func parseNumber() -> JSONValue? {
            let start = i
            var isInteger = true
            func digit(_ c: UInt8?) -> Bool { c.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
            if peek == UInt8(ascii: "-") { i += 1 }
            guard digit(peek) else { return nil }
            if peek == UInt8(ascii: "0") {
                i += 1
            } else {
                while digit(peek) { i += 1 }
            }
            if peek == UInt8(ascii: ".") {
                isInteger = false
                i += 1
                guard digit(peek) else { return nil }
                while digit(peek) { i += 1 }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                isInteger = false
                i += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
                guard digit(peek) else { return nil }
                while digit(peek) { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let d = Double(text) else { return nil }
            return .number(d, isInteger: isInteger)
        }
    }
}

enum JSONWriter {
    /// Compact text, members in order, non-ASCII raw (as JSON.stringify and
    /// Zig's Stringify write it).
    static func write(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    static func write(_ value: JSONValue, into out: inout String) {
        // An explicit stack again: the value may be `buildDepth` levels deep,
        // which is small, but the writer is also used on arbitrary states.
        enum Item {
            case value(JSONValue)
            case text(String)
        }
        var work: [Item] = [.value(value)]
        while let item = work.popLast() {
            switch item {
            case .text(let s):
                out.append(s)
            case .value(let v):
                switch v {
                case .null: out.append("null")
                case .bool(let b): out.append(b ? "true" : "false")
                case .number(let d, _): out.append(number(d))
                case .string(let s): writeString(s, into: &out)
                case .tooDeep: out.append("null")
                case .array(let items):
                    out.append("[")
                    work.append(.text("]"))
                    for (k, item) in items.enumerated().reversed() {
                        work.append(.value(item))
                        if k > 0 { work.append(.text(",")) }
                    }
                case .object(let members):
                    out.append("{")
                    work.append(.text("}"))
                    for (k, m) in members.enumerated().reversed() {
                        work.append(.value(m.value))
                        var keyText = ""
                        writeString(m.key, into: &keyText)
                        keyText.append(":")
                        if k > 0 { keyText = "," + keyText }
                        work.append(.text(keyText))
                    }
                }
            }
        }
    }

    /// Integral values print as integers (`1`, not `1.0`); others shortest
    /// round-trip; non-finite values (never written by this module) as null.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 {
            return String(Int64(d))
        }
        return d.description
    }

    static func writeString(_ s: String, into out: inout String) {
        out.append("\"")
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if u.value < 0x20 {
                    out.append(String(format: "\\u%04x", u.value))
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out.append("\"")
    }
}
