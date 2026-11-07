// Profiles and client-wide settings: the port of main.js's PROFILE_DEFAULTS,
// sanitizeSettings and the profiles:save validation rules, minus
// `passwordEnc` (Keychain) and `localPort` (unix-socket tunnel).
import Foundation

/// A connection profile.
public struct Profile: Sendable, Equatable, Hashable {
    /// Stable random id (16 hex chars), generated when the profile is first
    /// saved and kept across renames. The Keychain item for the profile's
    /// password is keyed by it (account = id).
    public var id: String = ""
    public var name: String = ""
    /// Anything ssh accepts, ~/.ssh/config aliases included.
    public var host: String = ""
    /// 0 = ssh default (22 / per ssh_config). Kept as read even above 65535
    /// (a hand edit): connecting then fails with `portError` instead of
    /// silently using the default port.
    public var sshPort: Int = 0
    /// Optional `-i` path.
    public var identityFile: String = ""
    /// Which webmux instance to run on the host (blank = "default"). It is
    /// interpolated into remote shell commands: see `Profile.validInstance`.
    public var instance: String = ""
    /// Extra ssh args, whitespace-separated (ProxyJump and friends go here).
    public var extraOptions: String = ""
    /// Where this profile's last file-browser download was saved.
    public var downloadDir: String = ""

    public init(id: String = "", name: String = "", host: String = "", sshPort: Int = 0, identityFile: String = "",
                instance: String = "", extraOptions: String = "", downloadDir: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.instance = instance
        self.extraOptions = extraOptions
        self.downloadDir = downloadDir
    }

    /// `instance || 'default'`.
    public var instanceOrDefault: String { instance.isEmpty ? "default" : instance }

    /// main.js's per-host key (`webmux://<slug>/` without the scheme).
    public var hostSlug: String { Profile.hostSlug(host: host, instance: instance) }

    /// main.js: blank or `^[A-Za-z0-9._-]+$` — the instance name lands in
    /// remote shell commands, so it must stay shell-inert.
    public static func validInstance(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            ("A"..."Z").contains(u) || ("a"..."z").contains(u) || ("0"..."9").contains(u) || u == "." || u == "_" || u == "-"
        }
    }

    public static let instanceError = "instance name must be blank (default) or letters, digits, . _ -"
    public static let portError = "SSH port must be a whole number from 1 to 65535 (blank = ssh's default)"

    public static func validPort(_ port: Int) -> Bool { port >= 0 && port <= 65535 }

    /// The per-host key (main.js `appOrigin` without the scheme): the
    /// lowercased host with runs of `[^a-z0-9-]` turned into `-` and leading
    /// or trailing `-` trimmed, plus `-` and the first 8 hex chars of
    /// sha256(`host\ninstance`), so sanitization can't collide two hosts.
    /// Stable across profile renames. Per-host files (tunnel socket, layout
    /// state) are named by it.
    public static func hostSlug(host: String, instance: String) -> String {
        let hex = Util.sha256Hex([host, "\n", instance.isEmpty ? "default" : instance])
        let hash = String(hex.prefix(8))
        var base = ""
        var inRun = false
        for u0 in host.lowercased().unicodeScalars {
            let ok = ("a"..."z").contains(u0) || ("0"..."9").contains(u0) || u0 == "-"
            if ok {
                inRun = false
                base.unicodeScalars.append(u0)
            } else if !inRun {
                inRun = true
                base += "-"
            }
        }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? hash : "\(trimmed)-\(hash)"
    }

    /// 1–64 hex chars (the ids we issue are 16).
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && Util.isHexString(id)
    }

    /// A fresh 16-hex-char id.
    public static func newID() -> String { Util.randomHex(bytes: 8) }

    /// The form's rule: blank = 0 (default); else decimal digits only, 1–65535.
    public static func parsePort(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if t.isEmpty { return 0 }
        if t.count > 5 { return nil }
        guard t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(t) else { return nil }
        if n == 0 || n > 65535 { return nil }
        return n
    }
}

/// The fields the profile form edits (profiles:save input).
public struct ProfileInput: Sendable, Equatable {
    public var name: String
    public var host: String
    /// 0 = ssh's default; above 65535 is refused (`Profile.portError`).
    public var sshPort: Int = 0
    /// The id for a new profile (nil: generate one). Ignored when an existing
    /// profile is replaced (its id is kept). Lets the app key a Keychain
    /// item before the profile is saved.
    public var id: String? = nil
    public var identityFile: String = ""
    public var instance: String = ""
    public var extraOptions: String = ""
    /// nil keeps the existing profile's value (the download hook maintains
    /// it, the form never shows it).
    public var downloadDir: String? = nil

    public init(name: String, host: String, sshPort: Int = 0, id: String? = nil, identityFile: String = "",
                instance: String = "", extraOptions: String = "", downloadDir: String? = nil) {
        self.name = name
        self.host = host
        self.sshPort = sshPort
        self.id = id
        self.identityFile = identityFile
        self.instance = instance
        self.extraOptions = extraOptions
        self.downloadDir = downloadDir
    }
}

/// Client-wide UI settings (main.js SETTINGS_DEFAULTS / ui/settings.js).
public struct Settings: Sendable, Equatable {
    /// Theme id: `[a-z0-9-]{1,32}`; the UI falls back to dark for ids it
    /// doesn't know (`dark`, `light`, and the Mac's `system`).
    public var theme: String = "dark"
    /// Unfocused-pane fade, 0..100 (percent).
    public var unfocusedFade: Int = 40
    /// Minimum and maximum column widths in terminal cells, 40..400, max >= min.
    public var minCols: Int = 90
    public var maxCols: Int = 200

    public init() {}

    public static func validTheme(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A partial update. Numbers follow JS `Number()` semantics in the JSON
    /// path; here they are plain doubles, and NaN/inf leave the field unchanged.
    public struct Patch: Sendable, Equatable {
        public var theme: String? = nil
        public var unfocusedFade: Double? = nil
        public var minCols: Double? = nil
        public var maxCols: Double? = nil
        public init(theme: String? = nil, unfocusedFade: Double? = nil, minCols: Double? = nil, maxCols: Double? = nil) {
            self.theme = theme
            self.unfocusedFade = unfocusedFade
            self.minCols = minCols
            self.maxCols = maxCols
        }
    }

    /// main.js sanitizeSettings(raw, base): unknown or malformed fields keep
    /// their base value, numbers are clamped and rounded (Math.round), and
    /// the column range stays a range whichever end moved.
    public func sanitized(with patch: Patch) -> Settings {
        var s = self
        if let t = patch.theme, Settings.validTheme(t) { s.theme = t }
        func clampRound(_ x: Double, _ lo: Double, _ hi: Double) -> Int { Int((min(hi, max(lo, x)) + 0.5).rounded(.down)) }
        if let f = patch.unfocusedFade, f.isFinite { s.unfocusedFade = clampRound(f, 0, 100) }
        if let f = patch.minCols, f.isFinite { s.minCols = clampRound(f, 40, 400) }
        if let f = patch.maxCols, f.isFinite { s.maxCols = clampRound(f, 40, 400) }
        if s.maxCols < s.minCols { s.maxCols = s.minCols }
        return s
    }

    /// sanitizeSettings over a parsed JSON object (config.json).
    func sanitized(withJSON raw: JSONValue?) -> Settings {
        guard let v = raw, case .object(let o) = v else { return sanitized(with: Patch()) }
        var p = Patch()
        if case .string(let t)? = o["theme"] { p.theme = t }
        if let x = o["unfocusedFade"] { p.unfocusedFade = x.jsNumber }
        if let x = o["minCols"] { p.minCols = x.jsNumber }
        if let x = o["maxCols"] { p.maxCols = x.jsNumber }
        return sanitized(with: p)
    }
}

// ---------------------------------------------------------------------------
// A small JSON value type (JSONSerialization loses the integer/float and
// bool/number distinctions config repair reports on).
// ---------------------------------------------------------------------------

enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case float(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parse JSON text; nil when it is not valid JSON.
    static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: any)
    }

    static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    init(any: Any) {
        if any is NSNull {
            self = .null
        } else if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .float(n.doubleValue)
            } else {
                self = .integer(n.int64Value)
            }
        } else if let s = any as? String {
            self = .string(s)
        } else if let a = any as? [Any] {
            self = .array(a.map { JSONValue(any: $0) })
        } else if let d = any as? [String: Any] {
            var o: [String: JSONValue] = [:]
            for (k, v) in d { o[k] = JSONValue(any: v) }
            self = .object(o)
        } else {
            self = .null
        }
    }

    /// JS `Number(v)`: numbers as is, strings parsed (blank → 0, junk →
    /// NaN), booleans 0/1, null 0, arrays/objects NaN (a simplification of
    /// JS's `[]` → 0 / `[x]` → Number(x)).
    var jsNumber: Double {
        switch self {
        case .integer(let i): return Double(i)
        case .float(let f): return f
        case .bool(let b): return b ? 1 : 0
        case .null: return 0
        case .string(let s):
            let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0b}\u{0c}"))
            if t.isEmpty { return 0 }
            if t == "Infinity" || t == "+Infinity" { return .infinity }
            if t == "-Infinity" { return -.infinity }
            if t.lowercased().hasPrefix("0x") {
                guard let n = UInt64(t.dropFirst(2), radix: 16) else { return .nan }
                return Double(n)
            }
            guard t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-" }) else { return .nan }
            return Double(t) ?? .nan
        case .array, .object: return .nan
        }
    }

    /// `${value}` in a JS template literal.
    var jsString: String {
        switch self {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .float(let f): return Util.jsNumber(f)
        case .array, .object: return serialized
        }
    }

    /// JS truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .integer(let i): return i != 0
        case .float(let f): return f != 0 && !f.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Compact JSON text (JSON.stringify without whitespace; object keys in
    /// sorted order, as the parser does not keep the file's).
    var serialized: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .float(let f): return Util.jsNumber(f)
        case .string(let s): return Util.jsonString(s)
        case .array(let a): return "[" + a.map { $0.serialized }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { Util.jsonString($0) + ":" + o[$0]!.serialized }.joined(separator: ",") + "}"
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Deviation 39: a port is a whole number from 1 to 65535 written in
    /// decimal (0 or absent = ssh's default). From JSON: an integer, or a
    /// string of decimal digits; anything else is not a port (nil).
    var portValue: Int? {
        switch self {
        case .integer(let i): return (i >= 0 && i <= 65535) ? Int(i) : nil
        case .string(let s): return Profile.parsePort(s)
        case .null: return 0
        default: return nil
        }
    }
}
