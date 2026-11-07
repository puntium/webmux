// Test helper: the native dev host (`mac/scripts/dev-host.sh run term-tests`) as a
// fully isolated instance for the terminal pane's live tests, after
// Tests/WebmuxHostTests/TestHost.swift (instance name `term-tests`, so it never
// touches `dev` or `host-tests`). HOME is the empty /tmp/wm-mac/term-tests/home,
// sessions run `sh` with `PS1='$ '` and no rc file. `stop` shuts the pty-host
// daemon down too.
//
// This target cannot import WebmuxHost (Package.swift is the lead's), so the two
// HTTP calls (health, create session) go through `curl --unix-socket`, like the
// app's dev-mode DevHTTP.
//
// Skipped (XCTSkip) when host/dist/webmux-host-darwin-arm64 is missing.
import Foundation
import XCTest

enum TermTestHost {
    static let name = "term-tests"
    static let dir = "/tmp/wm-mac/\(name)"
    static let home = "\(dir)/home"

    static var repoRoot: URL {
        // …/mac/Tests/WebmuxTerminalTests/TermTestHost.swift → repo root.
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var script: String { repoRoot.appendingPathComponent("mac/scripts/dev-host.sh").path }
    static var binary: String {
        ProcessInfo.processInfo.environment["WEBMUX_HOST_BIN"] ?? repoRoot.appendingPathComponent("host/dist/webmux-host-darwin-arm64").path
    }
    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private static let lock = NSLock()
    private static var started: Result<String, Error>?

    /// The socket path of the running test host, starting it on first use.
    static func socketPath() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let started { return try started.get() }
        let r = Result { try start() }
        started = r
        return try r.get()
    }

    private static func run(_ exe: String, _ args: [String], env extra: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DEV_HOST_HOME"] = "isolated"
        env["SHELL_CMD"] = "sh"
        env["PS1"] = "$ "
        env["ENV"] = ""
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// One HTTP request over the unix socket through curl; the body, or nil on failure.
    static func http(_ socket: String, method: String, path: String, body: String? = nil) -> String? {
        var args = ["-s", "--max-time", "5", "--unix-socket", socket, "-X", method, "http://localhost\(path)"]
        if let body {
            args += ["-H", "Content-Type: application/json", "-d", body]
        }
        guard let r = try? run("/usr/bin/curl", args), r.status == 0 else { return nil }
        return r.stdout
    }

    private static func start() throws -> String {
        guard binaryExists else { throw XCTSkip("no host binary at \(binary); run mac/scripts/dev-host.sh build") }
        // A leftover instance (from an interrupted run) may carry another
        // environment: restart it.
        _ = try? run(script, ["stop", name])
        try? FileManager.default.removeItem(atPath: home)
        let r = try run(script, ["run", name])
        guard r.status == 0, let sock = r.stdout.split(separator: "\n").first.map(String.init), !sock.isEmpty else {
            throw NSError(domain: "TermTestHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "dev-host.sh run failed (\(r.status)): \(r.stderr)"])
        }
        // Wait until GET / answers.
        for _ in 0..<200 {
            if let body = http(sock, method: "GET", path: "/"), body.contains("ok") { return sock }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "TermTestHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "host did not answer on \(sock)"])
    }

    /// `POST /api/sessions` → the new session's id.
    static func createSession(_ socket: String, cols: Int = 80, rows: Int = 24) throws -> String {
        guard let body = http(socket, method: "POST", path: "/api/sessions", body: "{\"cols\":\(cols),\"rows\":\(rows)}"),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw NSError(domain: "TermTestHost", code: 3, userInfo: [NSLocalizedDescriptionKey: "POST /api/sessions failed"])
        }
        return id
    }

    static func deleteSession(_ socket: String, id: String) {
        _ = http(socket, method: "DELETE", path: "/api/sessions/\(id)")
    }

    /// Shut the instance down (server and pty-host daemon).
    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard case .success = started else { return }
        _ = try? run(script, ["stop", name])
        started = nil
    }
}
