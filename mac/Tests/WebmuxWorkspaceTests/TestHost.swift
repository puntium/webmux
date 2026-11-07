// Test helper: the native dev host (`mac/scripts/dev-host.sh run ws-tests`)
// as an isolated instance of its own (name `ws-tests`, so it never touches
// the `dev` instance or WebmuxHostTests' `host-tests`). Same shape as
// Tests/WebmuxHostTests/TestHost.swift: HOME is an empty
// /tmp/wm-mac/ws-tests/home, sessions run `sh` with `PS1='$ '`.
//
// Skipped (XCTSkip) when host/dist/webmux-host-darwin-arm64 is missing.
import Foundation
import XCTest
import WebmuxHost

enum TestHost {
    static let name = "ws-tests"
    static let dir = "/tmp/wm-mac/\(name)"
    static let home = "\(dir)/home"

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var script: String { repoRoot.appendingPathComponent("mac/scripts/dev-host.sh").path }
    static var binary: String {
        ProcessInfo.processInfo.environment["WEBMUX_HOST_BIN"] ?? repoRoot.appendingPathComponent("host/dist/webmux-host-darwin-arm64").path
    }
    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: Result<String, Error>?

    /// The socket path of the running test host, starting it on first use.
    static func socketPath() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let started { return try started.get() }
        let r = Result { try start() }
        started = r
        return try r.get()
    }

    private static func run(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: script)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DEV_HOST_HOME"] = "isolated"
        env["SHELL_CMD"] = "sh"
        env["PS1"] = "$ "
        env["ENV"] = ""
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
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

    private static func start() throws -> String {
        guard binaryExists else { throw XCTSkip("no host binary at \(binary); run mac/scripts/dev-host.sh build") }
        _ = try? run(["stop", name])
        try? FileManager.default.removeItem(atPath: home)
        let r = try run(["run", name])
        guard r.status == 0, let sock = r.stdout.split(separator: "\n").first.map(String.init), !sock.isEmpty else {
            throw NSError(domain: "TestHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "dev-host.sh run failed (\(r.status)): \(r.stderr)"])
        }
        let api = HostAPI(socketPath: sock, timeout: .seconds(1))
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        Task {
            for _ in 0..<200 {
                if let h = try? await api.health(), h.ok { ok = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            sema.signal()
        }
        sema.wait()
        guard ok else { throw NSError(domain: "TestHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "host did not answer on \(sock)"]) }
        return sock
    }

    /// Shut the instance down (server and pty-host daemon).
    static func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard case .success = started else { return }
        _ = try? run(["stop", name])
        started = nil
    }
}
