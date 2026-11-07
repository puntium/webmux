// Environment knobs of the app process (all optional; the bundle runs with
// none of them). `open --env NAME=value dist/webmux.app` sets them for the
// bundle too (mac/README.md).
import Foundation
import WebmuxConnection

enum AppEnvironment {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static func value(_ name: String) -> String? {
        guard let v = environment[name], !v.isEmpty else { return nil }
        return v
    }

    /// Dev mode: one workspace on this host's HTTP socket, no ssh.
    static var devSocketPath: String? { value("WEBMUX_MAC_DEV_SOCKET") }
    static var isDevMode: Bool { devSocketPath != nil }

    /// The control socket for scripted testing (docs/macos-client.md rule 5).
    static var controlPath: String? { value("WEBMUX_MAC_CONTROL") }

    /// Another Application Support root (tests and smokes never touch the
    /// real `~/Library/Application Support/me.puntium.webmux.mac`).
    static var appSupportRoot: String? { value("WEBMUX_MAC_APP_SUPPORT") }

    /// The ssh program the engine runs (e.g. a fake ssh); unset: `ssh` from PATH.
    static var sshExecutable: String? { value("WEBMUX_MAC_SSH") }

    /// Where the engine keeps its files, and the payload found for deploy.
    static func paths() -> Paths {
        var p = Paths.standard()
        if let root = appSupportRoot { p.root = root }
        return p
    }
}
