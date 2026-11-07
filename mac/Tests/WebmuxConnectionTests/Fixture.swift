// The engine test fixture (conn/test.zig's Fixture): a fake `ssh` (a shell
// script that runs the "remote" command locally against a scratch remote
// $HOME, and emulates `-N -L` by creating a marker file at the local socket
// path), stand-in `webmux-host` payloads built into a scratch payload dir,
// and a test liveness probe. Every path lives under a fresh short `/tmp/wm-*`
// root (unix socket paths are capped at 103 bytes on Darwin).
import Foundation
import XCTest
@testable import WebmuxConnection

let fixturesDir = Util.dirname(#filePath) + "/Fixtures"

func sleepMs(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

/// A LAN prober whose verdicts the test scripts.
final class FakeLAN: LocalNetworkProber, @unchecked Sendable {
    private let lock = NSLock()
    private var _local = true
    private var _result = LANProbeResult(ok: true, ms: 1)
    private var _probes = 0
    var local: Bool {
        get { lock.withLock { _local } }
        set { lock.withLock { _local = newValue } }
    }
    var result: LANProbeResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var probes: Int { lock.withLock { _probes } }
    func isLocalTarget(host: String) -> Bool { local }
    func probe(host: String, port: Int, timeoutMs: Int) -> LANProbeResult {
        lock.withLock {
            _probes += 1
            return _result
        }
    }
}

final class Fixture: @unchecked Sendable {
    let root: String
    var env: [String: String]
    var engine: ConnectionEngine?
    let passwords = InMemoryPasswordStore()
    var lan: FakeLAN?
    var electronCandidates: [String] = []
    private let lock = NSLock()
    private var _removed: [String] = []
    private var _restarts: [RestartResult] = []
    private var _states: [ConnectionState] = []
    private var _settings = 0
    private var _probes = 0

    init() throws {
        root = "/tmp/wm-ct-\(Util.randomHex(bytes: 4))"
        for d in ["home", "config", "state", "run", "remote", "rrun", "bin", "stubs", "payload", "app"] {
            try Util.makePath(Util.join(root, d), mode: 0o700)
        }
        var e: [String: String] = [:]
        e["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for (k, d) in [("HOME", "home"), ("FAKE_REMOTE_HOME", "remote"), ("FAKE_STUBS", "stubs"), ("WEBMUX_PAYLOAD_DIR", "payload"),
                       ("FAKE_LOG", "ssh.log"), ("FAKE_REMOTE_RUN", "rrun")] {
            e[k] = Util.join(root, d)
        }
        e["FAKE_PASSWORD"] = "s3cr3t-pw"
        env = e
        try copyScript("fake-ssh", to: "bin/ssh")
        // never let the restart script's pgrep fallback see real processes
        try writeScript("stubs/pgrep", "#!/bin/sh\nexit 1\n")
        // the "remote" is a Linux x86_64 box (the probe's uname runs locally)
        try writeScript("stubs/uname", "#!/bin/sh\ncase \"$1\" in -m) echo x86_64;; *) echo Linux;; esac\n")
    }

    func cleanup() {
        stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { Util.join(root, rel) }

    func copyScript(_ fixture: String, to rel: String) throws {
        let body = try Data(contentsOf: URL(fileURLWithPath: Util.join(fixturesDir, fixture)))
        try Util.atomicWrite(path(rel), Array(body), mode: 0o755)
    }

    func writeScript(_ rel: String, _ body: String) throws {
        try Util.atomicWrite(path(rel), body, mode: 0o755)
    }

    func writeFile(_ rel: String, _ body: String) throws {
        let p = path(rel)
        try Util.makePath(Util.dirname(p), mode: 0o700)
        try Util.atomicWrite(p, body, mode: 0o644)
    }

    func removeFile(_ rel: String) { Util.unlink(path(rel)) }
    func exists(_ rel: String) -> Bool { Util.fileExists(path(rel)) }
    func read(_ rel: String) -> String { Util.readString(path(rel)) ?? "" }
    func sshLog() -> String { read("ssh.log") }

    func sh(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("sh failed: \(script)\n\(text)")
            throw EngineError(description: "sh failed")
        }
    }

    /// Build a payload for linux-x64 (plus an arm64 stand-in) stamped with
    /// `version`, and point payload.json at it. Returns the hash.
    func buildPayload(_ version: String) throws -> String {
        let hostScript = try String(contentsOfFile: Util.join(fixturesDir, "fake-webmux-host"), encoding: .utf8)
        let hash = Util.sha256Hex([hostScript, version])
        let arm = Util.sha256Hex([hostScript, version, "arm64"])
        try sh("""
        set -e
        cd "\(root)/payload"
        rm -rf linux-x64 && mkdir -p linux-x64/staging/shims
        cp "\(fixturesDir)/fake-webmux-host" linux-x64/staging/webmux-host
        chmod 755 linux-x64/staging/webmux-host
        printf '#!/bin/sh\\nexit 0\\n' > linux-x64/staging/shims/xdg-open && chmod 755 linux-x64/staging/shims/xdg-open
        echo \(hash) > linux-x64/staging/PAYLOAD_HASH
        tar czf linux-x64/payload.tar.gz -C linux-x64/staging .
        printf '{"platforms":{"linux-x64":{"hash":"\(hash)","bytes":1},"linux-arm64":{"hash":"\(arm)","bytes":1}},"builtAt":"x"}\\n' > payload.json
        """)
        return hash
    }

    static func timing() -> ConnectionTiming {
        var t = ConnectionTiming()
        t.probeTimeoutMs = 200
        t.probeIntervalMs = 150
        t.probeRetryMs = 40
        t.probeMisses = 3
        t.probeFirstAnswerMs = 1200
        t.retryMinMs = 300
        t.retryMaxMs = 1200
        t.restartTimeoutMs = 5000
        t.killGraceMs = 1000
        t.lanProbeTimeoutMs = 100
        t.lanGrantReprobeMs = 50
        t.lanGrantWaitMs = 400
        t.lanRecoverReprobeMs = 50
        t.lanRecoverWaitMs = 3000
        return t
    }

    var paths: Paths { Paths(root: path("app"), payloadDir: Paths.findPayloadDir(environment: env, executableDir: root)) }

    @discardableResult
    func start() throws -> ConnectionEngine {
        var o = EngineOptions(paths: paths, environment: env)
        o.sshExecutable = path("bin/ssh")
        o.prober = ClosureHostProber { [self] sock, _ in self.probe(sock) }
        o.passwordStore = passwords
        o.passwordStoreName = "memory"
        o.localNetwork = lan
        o.timing = Fixture.timing()
        o.version = "test"
        o.electronConfigCandidates = electronCandidates
        o.onEvent = { [self] ev in self.onEvent(ev) }
        let e = try ConnectionEngine(options: o)
        engine = e
        return e
    }

    func stop() {
        engine?.shutdown()
        engine = nil
    }

    /// Test probe: "the server answers" iff ssh created the forward's local
    /// end and the remote server is not marked dead.
    private func probe(_ socketPath: String) -> String? {
        lock.withLock { _probes += 1 }
        if exists("remote/server-dead") { return "ConnectionRefused" }
        return Util.fileExists(socketPath) ? nil : "SocketMissing"
    }

    var probeCount: Int { lock.withLock { _probes } }

    private func onEvent(_ ev: ConnectionEvent) {
        lock.withLock {
            switch ev {
            case .status(let s):
                if _states.last != s.state { _states.append(s.state) }
            case .removed(let n): _removed.append(n)
            case .restartDone(let r): _restarts.append(r)
            case .settings: _settings += 1
            }
        }
    }

    var removedCount: Int { lock.withLock { _removed.count } }
    var restarts: [RestartResult] { lock.withLock { _restarts } }
    var settingsEvents: Int { lock.withLock { _settings } }
    func sawState(_ s: ConnectionState) -> Bool { lock.withLock { _states.contains(s) } }
    func clearStates() { lock.withLock { _states.removeAll() } }

    func addProfile(_ name: String, _ host: String, _ instance: String, file: StaticString = #filePath, line: UInt = #line) {
        if let err = engine!.saveProfile(ProfileInput(name: name, host: host, instance: instance)) {
            XCTFail("saveProfile: \(err)", file: file, line: line)
        }
    }

    func stateOf(_ name: String) -> ConnectionState? { engine!.status(name)?.state }

    /// Poll until the connection reaches `want` (or time runs out).
    func waitState(_ name: String, _ want: ConnectionState, _ timeoutMs: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Util.monoMs() + Int64(timeoutMs)
        while Util.monoMs() < deadline {
            if stateOf(name) == want { return }
            sleepMs(20)
        }
        let st = engine!.status(name)
        XCTFail("waitState(\(name)): wanted \(want), have \(st.map { "\($0.state) msg=\($0.msg) stderr=\($0.stderr)" } ?? "no connection")\n---- log ----\n\(logText())", file: file, line: line)
    }

    func waitFor(_ timeoutMs: Int, file: StaticString = #filePath, line: UInt = #line, _ pred: () -> Bool) {
        let deadline = Util.monoMs() + Int64(timeoutMs)
        while Util.monoMs() < deadline {
            if pred() { return }
            sleepMs(20)
        }
        XCTFail("waitFor timed out\n---- log ----\n\(logText())", file: file, line: line)
    }

    func logText() -> String { engine?.log.text() ?? "" }
    func logHas(_ needle: String) -> Bool { logText().contains(needle) }
    func logCount(_ needle: String) -> Int { logText().components(separatedBy: needle).count - 1 }

    func waitLog(_ needle: String, _ timeoutMs: Int, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Util.monoMs() + Int64(timeoutMs)
        while Util.monoMs() < deadline {
            if logCount(needle) >= count { return }
            sleepMs(20)
        }
        XCTFail("log never had \(count)x: \(needle)\n---- log ----\n\(logText())", file: file, line: line)
    }

    func expectLog(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        if !logHas(needle) { XCTFail("log lacks: \(needle)\n---- log ----\n\(logText())", file: file, line: line) }
    }
}
