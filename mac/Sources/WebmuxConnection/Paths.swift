// Where things live locally (docs/macos-client.md › Idiomatic macOS): one
// directory under Application Support, with an injectable root so tests
// never touch the real one.
//
//   <root>/config.json          profiles, lastProfile, settings (no passwords)
//   <root>/run/                 0700: tunnel sockets (<slug>.sock) and askpass.sh
//   <root>/logs/webmux.log      the connection log's file sink (+ .1)
//   <root>/layout/<slug>.json   per-host state (the layout package's)
import Foundation

public struct Paths: Sendable, Equatable {
    /// `~/Library/Application Support/me.puntium.webmux.mac` by default.
    public var root: String
    /// Payload dir (holding payload.json + <key>/payload.tar.gz), or nil
    /// when none was found.
    public var payloadDir: String?

    public init(root: String, payloadDir: String? = nil) {
        self.root = root
        self.payloadDir = payloadDir
    }

    /// The app's directory for `bundleID`, and the payload found through
    /// `environment` / the executable's location.
    public static func standard(bundleID: String = webmuxBundleID,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                executableDir: String? = nil) -> Paths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? Util.join(NSHomeDirectory(), "Library/Application Support")
        return Paths(root: Util.join(base, bundleID), payloadDir: findPayloadDir(environment: environment, executableDir: executableDir))
    }

    public var configFile: String { Util.join(root, "config.json") }
    public var runDir: String { Util.join(root, "run") }
    public var logsDir: String { Util.join(root, "logs") }
    public var layoutDir: String { Util.join(root, "layout") }
    public var askpassFile: String { Util.join(runDir, "askpass.sh") }

    /// `$WEBMUX_PAYLOAD_DIR`, else `<exe dir>/../Resources/payload` (inside
    /// webmux.app), else `electron/payload` found by walking up from the
    /// executable (a checkout). The latter two must hold a payload.json.
    public static func findPayloadDir(environment env: [String: String], executableDir: String? = nil) -> String? {
        if let d = env["WEBMUX_PAYLOAD_DIR"], !d.isEmpty { return d }
        let exeDir = executableDir ?? Util.dirname(Bundle.main.executablePath ?? CommandLine.arguments[0])
        let share = (Util.join(exeDir, "../Resources/payload") as NSString).standardizingPath
        if hasManifest(share) { return share }
        var dir = exeDir
        while true {
            let cand = Util.join(dir, "electron/payload")
            if hasManifest(cand) { return cand }
            let parent = Util.dirname(dir)
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        return nil
    }

    static func hasManifest(_ dir: String) -> Bool {
        Util.fileExists(Util.join(dir, "payload.json"))
    }

    public struct SocketPathError: Error, CustomStringConvertible {
        public var description: String { "RunDirTooLong" }
    }

    /// `sun_path` is 104 bytes on Darwin: a socket path may be at most 103.
    public static let maxSocketPath = 103

    /// The local tunnel socket for a host slug: `<run dir>/<slug>.sock`.
    /// When the slug would overflow, the base part of the slug is shortened
    /// (the 8-hex hash suffix, which carries the uniqueness, is always kept).
    public func socketPath(slug: String) throws -> String {
        let max = Paths.maxSocketPath
        let fixed = runDir.utf8.count + 1 + ".sock".utf8.count
        if fixed + slug.utf8.count <= max { return "\(runDir)/\(slug).sock" }
        if fixed + 8 > max { throw SocketPathError() }
        let hash = String(slug.suffix(min(8, slug.count)))
        let room = max - fixed
        if room <= 9 { return "\(runDir)/\(hash).sock" }
        let baseLen = min(slug.count - hash.count, room - 9)
        var base = String(slug.prefix(baseLen))
        while base.hasSuffix("-") { base.removeLast() }
        return "\(runDir)/\(base)-\(hash).sock"
    }

    public func socketPath(for profile: Profile) throws -> String {
        try socketPath(slug: profile.hostSlug)
    }

    /// The Electron client's config file (its userData for the app name
    /// "webmux" on macOS; the Linux-style path is checked too).
    public static func electronConfigCandidates(home: String = NSHomeDirectory()) -> [String] {
        [Util.join(home, "Library/Application Support/webmux/config.json"), Util.join(home, ".config/webmux/config.json")]
    }
}
