// One supervised connection: main.js's connectConn / startTunnel /
// runDeploy / spawnTunnel / onTunnelDown / scheduleRetry / probeLoop /
// onServerUp state machine (plus warmLocalNetwork / awaitLanGrant), run
// sequentially on the connection's own thread. Where main.js juggles
// callbacks and a `generation` counter to orphan stale handlers, this
// thread does one thing at a time and every blocking wait also watches a
// wake pipe for commands from the app (connect/reconnect, disconnect,
// resume, quit).
//
// States: connecting → connected; a drop of a cycle that was ever connected
// → retry (backoff 1 s doubling to 15 s, deploy re-run on every attempt); a
// drop of a cycle that never connected → failed (parked with ssh's stderr,
// no background retry — unless the failure reads like a macOS Local Network
// denial, which keeps probing the target and reconnects when it is allowed).
import Foundation

/// main.js's connection states. (`degraded` is not here: it is the app's
/// own verdict — connected while a pane's session socket is down — as in
/// main.js `snapshot`.)
public enum ConnectionState: String, Sendable {
    /// deploying or waiting for the server to first answer through a fresh tunnel
    case connecting
    /// the server answered through the tunnel
    case connected
    /// an established connection was interrupted; retrying after a delay
    case retry
    /// parked: a connect that never got through, or a Keychain refusal; no
    /// background retry until the user acts
    case failed
}

/// What the supervisor is doing right now (finer than `ConnectionState`).
public enum ConnectionStep: String, Sendable {
    case idle
    /// `checking local network access…` / waiting for the permission prompt (X-40)
    case checkingLocalNetwork
    /// deploy: `probing host…`
    case probing
    /// deploy: streaming the payload (see pushSent / pushTotal)
    case pushing
    /// deploy: `starting server…`
    case starting
    /// tunnel spawned, probing through it
    case tunnel
    /// waiting out a retry delay
    case waitingRetry
    /// parked on the Local Network hint, re-probing the target (X-41)
    case waitingLocalNetworkGrant
}

/// A connection's status (an immutable copy).
public struct ConnectionStatus: Sendable, Equatable {
    /// profile name (follows renames)
    public var name: String
    public var state: ConnectionState
    /// main.js status `msg`: "ssh <host>", deploy progress lines,
    /// "ssh exited (255)", "connection failed", … (empty when connected)
    public var msg: String
    /// the last 8 lines of ssh stderr and deploy/probe diagnostics, joined
    /// with '\n' (main.js `stderr`)
    public var stderr: String
    public var step: ConnectionStep
    /// push progress in bytes (step == .pushing)
    public var pushSent: UInt64 = 0
    public var pushTotal: UInt64 = 0
    /// retry state: delay in seconds as main.js reports it, and the monotonic
    /// deadline (`ConnectionEngine.nowMs` clock); 0 when not retrying
    public var retryDelaySeconds: Int = 0
    public var retryDeadlineMs: Int64 = 0
    /// local tunnel socket, set while connected (nil otherwise)
    public var socketPath: String?
    /// the remote server's advertised socket (last successful deploy)
    public var remoteSocket: String?
    /// what the connection is on, which may differ from the stored profile
    /// after an edit (until Reconnect)
    public var host: String
    public var instance: String
    public var sshPort: Int
    /// this connect-cycle reached connected at least once (drops retry)
    public var hadConnection: Bool
    public var tunnelPID: pid_t?

    /// ms left on the retry countdown at monotonic time `nowMs`.
    public func retryRemainingMs(now nowMs: Int64) -> Int64 {
        if state != .retry || retryDeadlineMs == 0 { return 0 }
        return max(0, retryDeadlineMs - nowMs)
    }
}

struct PasswordState {
    var password: String?
    var unavailable: String?
    var has: Bool { password != nil }
    mutating func wipe() {
        password = nil
        unavailable = nil
    }
}

final class ConnectionSupervisor: @unchecked Sendable {
    static let tailMax = 8

    unowned let engine: ConnectionEngine
    private let lock = NSLock()
    let wake = WakePipe()
    private let done = DispatchSemaphore(value: 0)
    private var started = false

    // guarded by `lock`
    private var _name: String
    private var _profile: Profile
    private var cmdConnect: String?
    private var cmdDisconnect: String?
    private var cmdResume = false
    private var cmdQuit = false
    private var finished = false
    private var state: ConnectionState = .connecting
    private var msg = ""
    private var tail: [String] = []
    private var step: ConnectionStep = .idle
    private var pushSent: UInt64 = 0
    private var pushTotal: UInt64 = 0
    private var retryDelaySeconds = 0
    private var retryDeadlineMs: Int64 = 0
    private var socketPath: String?
    private var remoteSocket: String?
    private var hadConnection = false
    private var tunnelPID: pid_t?
    private var deployPID: pid_t?
    private var awaitingGrant = false

    // supervisor-thread-only
    private var retryDelayMs = 0
    private var lastStep = ""
    private var disconnecting = false

    init(engine: ConnectionEngine, profile: Profile) {
        self.engine = engine
        _name = profile.name
        _profile = profile
    }

    func start() {
        started = true
        let t = Thread { [self] in self.threadMain() }
        t.name = "webmux.connection.\(_name)"
        t.stackSize = 1 << 20
        t.start()
    }

    /// Wait for the thread to finish (only after `isFinished`, or quit).
    func join() {
        if started {
            done.wait()
            started = false
        }
    }

    // -- queries/commands from the engine (any thread) ---------------------

    var name: String { lock.withLock { _name } }
    var profile: Profile { lock.withLock { _profile } }

    func rename(_ name: String) { lock.withLock { _name = name } }
    func setProfile(_ p: Profile) { lock.withLock { _profile = p } }
    var slug: String { lock.withLock { _profile.hostSlug } }

    /// Whether this connection holds (or is about to bind) its tunnel
    /// socket: anything but parked in `failed` with no tunnel.
    var holdsSocket: Bool {
        lock.withLock {
            if finished { return false }
            return state != .failed || tunnelPID != nil || cmdConnect != nil || awaitingGrant
        }
    }

    var isConnected: Bool {
        lock.withLock { state == .connected && tunnelPID != nil && cmdConnect == nil }
    }

    var hasTunnel: Bool { lock.withLock { tunnelPID != nil } }
    var isFinished: Bool { lock.withLock { finished } }
    var stateName: String { lock.withLock { state.rawValue } }

    func requestConnect(_ why: String) {
        lock.withLock { cmdConnect = why }
        wake.wake()
    }

    func requestDisconnect(_ why: String) {
        lock.withLock { cmdDisconnect = why }
        wake.wake()
    }

    func requestResume() {
        lock.withLock { cmdResume = true }
        wake.wake()
    }

    func requestQuit() {
        lock.withLock { cmdQuit = true }
        wake.wake()
    }

    /// Caller holds the lock.
    private func statusLocked() -> ConnectionStatus {
        ConnectionStatus(name: _name, state: state, msg: msg, stderr: tail.joined(separator: "\n"), step: step,
                         pushSent: pushSent, pushTotal: pushTotal, retryDelaySeconds: retryDelaySeconds,
                         retryDeadlineMs: retryDeadlineMs, socketPath: state == .connected ? socketPath : nil,
                         remoteSocket: remoteSocket, host: _profile.host, instance: _profile.instanceOrDefault,
                         sshPort: _profile.sshPort, hadConnection: hadConnection, tunnelPID: tunnelPID)
    }

    var status: ConnectionStatus { lock.withLock { statusLocked() } }

    // -- supervisor-thread helpers -----------------------------------------

    private func log(_ level: LogLevel, _ message: String, _ data: [LogField] = []) {
        engine.log.at(level, name, message, data)
    }

    private func publish() {
        if disconnecting { return }
        engine.emit(.status(status))
    }

    private func pushTail(_ line: String) {
        lock.withLock {
            tail.append(line)
            if tail.count > ConnectionSupervisor.tailMax { tail.removeFirst(tail.count - ConnectionSupervisor.tailMax) }
        }
    }

    private func clearTail() {
        lock.withLock { tail.removeAll() }
    }

    private struct StatusUpdate {
        var state: ConnectionState
        var msg: String = ""
        var step: ConnectionStep
        var pushSent: UInt64 = 0
        var pushTotal: UInt64 = 0
        var retryDelaySeconds = 0
        var retryDeadlineMs: Int64 = 0
    }

    /// main.js setConnStatus: every state change is a log line; same-state
    /// updates (deploy progress, retry countdowns) are logged by their producers.
    private func setStatus(_ u: StatusUpdate) {
        let prev: ConnectionState = lock.withLock {
            let prev = state
            state = u.state
            msg = u.msg
            step = u.step
            pushSent = u.pushSent
            pushTotal = u.pushTotal
            retryDelaySeconds = u.retryDelaySeconds
            retryDeadlineMs = u.retryDeadlineMs
            return prev
        }
        if prev != u.state {
            let level: LogLevel = u.state == .failed ? .error : u.state == .retry ? .warn : .info
            log(level, "state \(prev.rawValue) → \(u.state.rawValue)", u.msg.isEmpty ? [] : [LogField("msg", u.msg)])
        }
        publish()
    }

    private enum Cmd {
        case none
        case connect(String)
        case exit(String)
        case resume
    }

    /// Take the most important pending command. Drains the wake pipe.
    private func takeCommand(acceptResume: Bool) -> Cmd {
        wake.drain()
        return lock.withLock {
            if cmdQuit { return .exit("quit") }
            if let w = cmdDisconnect { return .exit(w) }
            if let w = cmdConnect {
                cmdConnect = nil
                return .connect(w)
            }
            if cmdResume {
                cmdResume = false
                if acceptResume { return .resume }
            }
            return .none
        }
    }

    /// Is a stopping command (connect/disconnect/quit) pending? (No drain.)
    private func stopPending() -> String? {
        lock.withLock {
            if cmdQuit { return "quit" }
            if let w = cmdDisconnect { return w }
            if let w = cmdConnect { return w }
            return nil
        }
    }

    private func takeResume() -> Bool {
        lock.withLock {
            let r = cmdResume
            cmdResume = false
            return r
        }
    }

    private var timing: ConnectionTiming { engine.timing }

    // -- the thread ------------------------------------------------------------

    private enum Next {
        /// parked (failed / idle): wait for a command
        case wait
        /// connectConn: a fresh manual connect cycle
        case cycle(String)
        /// startTunnel: one attempt (deploy + tunnel + probe loop)
        case attempt
        /// scheduleRetry with main.js's exitCode (nil = undefined)
        case retry(ExitStatus?)
        /// awaitLanGrant: parked on the Local Network hint, watching the target
        case awaitGrant
        /// a command interrupted the current step: act on it
        case command
        case exit
    }

    private func threadMain() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &set, nil)

        var next: Next = .wait
        var pw = PasswordState()
        var havePw = false
        loop: while true {
            switch next {
            case .wait: next = waitCommand()
            case .command: next = commandNext()
            case .cycle(let why):
                connectConn(why, &pw)
                havePw = true
                next = .attempt
            case .attempt:
                if !havePw { pw = engine.lookupPassword(profile) }
                havePw = false
                next = attempt(&pw)
            case .retry(let code): next = scheduleRetry(code)
            case .awaitGrant: next = awaitLanGrant()
            case .exit: break loop
            }
        }
        pw.wipe()
        let quit = lock.withLock { cmdQuit }
        if !quit { engine.emit(.removed(name: name)) }
        // Last: once set, the engine may join and free this connection.
        lock.withLock { finished = true }
        done.signal()
    }

    private func waitCommand() -> Next {
        while true {
            switch takeCommand(acceptResume: false) {
            case .connect(let why): return .cycle(why)
            case .exit:
                disconnecting = true
                return .exit
            case .none, .resume: wake.wait(timeoutMs: -1)
            }
        }
    }

    private func commandNext() -> Next {
        switch takeCommand(acceptResume: false) {
        case .connect(let why): return .cycle(why)
        case .exit:
            disconnecting = true
            return .exit
        case .none, .resume: return .wait
        }
    }

    /// main.js connectConn (the parts after stopTunnel).
    private func connectConn(_ why: String, _ pw: inout PasswordState) {
        retryDelayMs = 0
        lock.withLock { hadConnection = false } // a fresh manual attempt parks on failure, no retry loop
        let p = profile
        pw = engine.lookupPassword(p)
        let sock = (try? engine.paths.socketPath(for: p)) ?? "(run dir too long for a socket path)"
        var fields: [LogField] = [LogField("host", p.host), LogField("instance", p.instanceOrDefault), LogField("socket", sock)]
        if p.sshPort != 0 { fields.append(LogField("sshPort", p.sshPort)) }
        if !p.identityFile.isEmpty { fields.append(LogField("identityFile", p.identityFile)) }
        if !p.extraOptions.isEmpty { fields.append(LogField("extraOptions", p.extraOptions)) }
        // main.js logs whether a password is stored, not whether it could be
        // read (a locked keychain still means password auth).
        let stored = pw.has || pw.unavailable != nil || engine.passwordStored(p.id)
        fields.append(LogField("auth", stored ? "password" : "key"))
        log(.info, "\(why) requested", fields)
    }

    /// The status line for a failed/interrupted attempt (main.js failureMsg):
    /// ssh's exit code, or — when its stderr carries the Local Network denial
    /// signature — what that actually means and where the toggle is.
    private func failureMsg(_ exit: ExitStatus?) -> String {
        if engine.lanGated {
            let lines = lock.withLock { tail }
            if LocalNetwork.looksDenied(lines) {
                log(.warn, "ssh reported \"No route to host\" — on macOS this is usually the Local Network privacy grant, not routing")
                return LocalNetwork.hint
            }
        }
        guard let e = exit else { return "connection failed" }
        return "ssh exited (\(e))"
    }

    /// main.js onTunnelDown.
    private func onTunnelDown(_ exit: ExitStatus?) -> Next {
        if lock.withLock({ hadConnection }) { return .retry(exit) }
        let m = failureMsg(exit)
        setStatus(StatusUpdate(state: .failed, msg: m, step: .idle))
        if m == LocalNetwork.hint { return .awaitGrant }
        return .wait
    }

    /// main.js scheduleRetry + the retry timer firing.
    private func scheduleRetry(_ exit: ExitStatus?) -> Next {
        let t = timing
        retryDelayMs = min(max(retryDelayMs * 2, t.retryMinMs), t.retryMaxMs)
        let delay = retryDelayMs
        log(.warn, "interrupted — retry in \(ConnectionSupervisor.fmtSeconds(delay))s", exit.map { [LogField("exitCode", $0.logExitCode)] } ?? [])
        let deadline = Util.monoMs() + Int64(delay)
        setStatus(StatusUpdate(state: .retry, msg: failureMsg(exit), step: .waitingRetry,
                               retryDelaySeconds: (delay + 500) / 1000, retryDeadlineMs: deadline))
        while true {
            switch takeCommand(acceptResume: false) {
            case .connect(let why):
                log(.info, "pending retry cancelled (\(why))")
                return .cycle(why)
            case .exit(let why):
                disconnecting = true
                log(.info, "pending retry cancelled (\(why))")
                return .exit
            case .none, .resume: break
            }
            let left = deadline - Util.monoMs()
            if left <= 0 { break }
            wake.wait(timeoutMs: Int32(min(left, 60_000)))
        }
        log(.info, "retrying")
        return .attempt
    }

    static func fmtSeconds(_ ms: Int) -> String {
        if ms % 1000 == 0 { return String(ms / 1000) }
        return Util.jsNumber(Double(ms) / 1000.0)
    }

    // -- one attempt (startTunnel → warmLocalNetwork → runDeploy → spawnTunnel → probeLoop)

    private final class Attempt {
        let profile: Profile
        let hasPassword: Bool
        var env: [String: String]
        let startedMs: Int64
        var command = ""
        init(profile: Profile, hasPassword: Bool, env: [String: String]) {
            self.profile = profile
            self.hasPassword = hasPassword
            self.env = env
            startedMs = Util.monoMs()
        }
    }

    private func attempt(_ pw: inout PasswordState) -> Next {
        clearTail()
        let p = profile

        if let why = pw.unavailable {
            // Keychain refused. Retrying won't help — park in failed with no
            // timer and let the user re-enter the password.
            pw.wipe()
            pushTail(why)
            log(.error, "saved password could not be decrypted", [LogField("error", why)])
            setStatus(StatusUpdate(state: .failed, msg: "saved password could not be decrypted — edit the profile and re-enter it", step: .idle))
            return .wait
        }
        if !p.instance.isEmpty && !Profile.validInstance(p.instance) {
            pw.wipe()
            pushTail(Profile.instanceError)
            setStatus(StatusUpdate(state: .failed, msg: "invalid instance name in profile", step: .idle))
            return .wait
        }
        if !Profile.validPort(p.sshPort) {
            pw.wipe()
            pushTail(Profile.portError)
            log(.error, "invalid SSH port in profile", [LogField("sshPort", p.sshPort)])
            setStatus(StatusUpdate(state: .failed, msg: "invalid SSH port in profile — edit the profile", step: .idle))
            return .wait
        }
        if (try? engine.paths.socketPath(for: p)) == nil {
            // No socket path can be built (Application Support path too
            // long): every attempt would fail the same way, so park with the reason.
            pw.wipe()
            let why = "cannot build the tunnel socket path under \(Util.clipChars(engine.paths.runDir, 300)): a unix socket path is limited to \(Paths.maxSocketPath) bytes"
            pushTail(why)
            log(.error, "no tunnel socket path", [LogField("error", why)])
            setStatus(StatusUpdate(state: .failed, msg: "the run directory is too long for a socket path", step: .idle))
            return .wait
        }

        setStatus(StatusUpdate(state: .connecting, msg: "ssh \(Util.clipChars(p.host, 500))", step: .probing))

        let env = SSHCommand.childEnvironment(base: engine.environment, askpassPath: engine.askpassPath, password: pw.password)
        let hasPassword = pw.has
        pw.wipe()
        let at = Attempt(profile: p, hasPassword: hasPassword, env: env)
        defer { at.env.removeValue(forKey: SSHCommand.passwordEnv) }

        if let interrupted = warmLocalNetwork(at) { return interrupted }

        lastStep = ""
        let runner = Deployer.Runner(
            run: { [self] command, stdinFile in try self.runnerRun(at, command, stdinFile) },
            status: { [self] step, msg, sent, total in self.runnerStatus(step, msg, sent, total) },
            stderr: { [self] line in self.runnerStderr(line) },
            isLive: { [self] in self.stopPending() == nil }
        )
        let outcome = Deployer.deploy(runner, payloadDir: engine.paths.payloadDir, instance: p.instanceOrDefault)
        let ms = Util.monoMs() - at.startedMs
        switch outcome {
        case .cancelled:
            return .command
        case .failed(let message):
            log(.error, "deploy failed", [LogField("ms", ms), LogField("error", message)])
            pushTail(message)
            return onTunnelDown(nil)
        case .ok(let res):
            log(.info, "deploy done: server \(res.action)", [
                LogField("ms", ms), LogField("platform", res.platform), LogField("payload", String(res.payloadHash.prefix(12))),
                LogField("socket", res.socket), LogField("pid", res.pid.map { LogValue.int($0) } ?? .null),
            ])
            lock.withLock { remoteSocket = res.socket }
            if stopPending() != nil { return .command }
            return runTunnel(at, remoteSock: res.socket)
        }
    }

    // -- macOS Local Network (main.js warmLocalNetwork / awaitLanGrant) ----------

    /// Before the first ssh to a LAN host, touch it from this process so the
    /// macOS Local Network prompt is attributed to us — the process whose
    /// children the ssh spawns are. One success per target per app run is
    /// enough; a denial (instant EHOSTUNREACH) is re-probed next time, since
    /// the user may have flipped the toggle in between. Never fails the
    /// connect: ssh runs regardless and reports its own verdict. Returns a
    /// `Next` only when a command interrupted the wait.
    private func warmLocalNetwork(_ at: Attempt) -> Next? {
        guard engine.lanGated, let lan = engine.localNetwork else { return nil }
        guard let target = LocalNetwork.sshTarget(at.profile) else { return nil }
        let key = "\(target.host):\(target.port)"
        if engine.isLanWarmed(key) { return nil }
        if !lan.isLocalTarget(host: target.host) { return nil }
        if stopPending() != nil { return .command }
        let t = timing
        let where_ = [LogField("host", target.host), LogField("port", target.port)]
        setStatus(StatusUpdate(state: .connecting, msg: "checking local network access…", step: .checkingLocalNetwork))
        var r = lan.probe(host: target.host, port: target.port, timeoutMs: t.lanProbeTimeoutMs)
        if stopPending() != nil { return .command }
        if LocalNetwork.grantPending(r, host: target.host) {
            // Denied (or, for a .local name, unresolvable — mDNS is gated too).
            // Either the prompt is on screen right now or the grant is
            // missing/broken. Keep re-probing for a while so a user who clicks
            // Allow gets a working ssh on this attempt.
            log(.warn, "local network probe: \(r.code ?? "?") in \(r.ms)ms — waiting for the macOS Local Network grant", where_)
            setStatus(StatusUpdate(state: .connecting, msg: "waiting for macOS Local Network permission — allow webmux in the prompt…", step: .checkingLocalNetwork))
            let until = Util.monoMs() + Int64(t.lanGrantWaitMs)
            while Util.monoMs() < until {
                wake.wait(timeoutMs: Int32(t.lanGrantReprobeMs))
                if stopPending() != nil { return .command }
                r = lan.probe(host: target.host, port: target.port, timeoutMs: t.lanProbeTimeoutMs)
                if stopPending() != nil { return .command }
                if !LocalNetwork.grantPending(r, host: target.host) { break }
            }
        }
        if r.ok {
            engine.markLanWarmed(key)
            log(.info, "local network probe: reachable", where_ + [LogField("ms", r.ms)])
        } else if LocalNetwork.grantPending(r, host: target.host) {
            log(.warn, "local network probe: still \(r.code ?? "?") after \(ConnectionSupervisor.fmtSeconds(t.lanGrantWaitMs))s — the macOS Local Network grant is missing or broken", where_)
        } else {
            log(.info, "local network probe: \(r.code ?? "?")", where_ + [LogField("ms", r.ms)])
        }
        return nil
    }

    /// A connect that parked on the Local Network hint: keep probing the
    /// target from this process and, the moment a connection goes through
    /// (the user flipped the toggle or answered a late prompt), start a
    /// fresh attempt — no need to find the Connect button. Stops when the
    /// user acts on the connection, or after `lanRecoverWaitMs`.
    private func awaitLanGrant() -> Next {
        guard let lan = engine.localNetwork, let target = LocalNetwork.sshTarget(profile) else { return .wait }
        let t = timing
        lock.withLock {
            awaitingGrant = true
            step = .waitingLocalNetworkGrant
        }
        defer { lock.withLock { awaitingGrant = false } }
        publish()
        let until = Util.monoMs() + Int64(t.lanRecoverWaitMs)
        while Util.monoMs() < until {
            wake.wait(timeoutMs: Int32(t.lanRecoverReprobeMs))
            if stopPending() != nil { return .command }
            let r = lan.probe(host: target.host, port: target.port, timeoutMs: t.lanProbeTimeoutMs)
            if stopPending() != nil { return .command }
            if r.ok {
                engine.markLanWarmed("\(target.host):\(target.port)")
                log(.info, "local network access granted — reconnecting", [LogField("host", target.host), LogField("port", target.port)])
                return .attempt
            }
        }
        lock.withLock { step = .idle }
        publish()
        return .wait
    }

    // -- deploy runner -----------------------------------------------------------

    private func runnerRun(_ at: Attempt, _ command: String, _ stdinFile: String?) throws -> RunResult {
        let argv = SSHCommand.commandArgv(ssh: engine.sshPath, at.profile, hasPassword: at.hasPassword, command: command)
        at.command = command
        let hooks = RunHooks(
            wakeFD: wake.r,
            shouldCancel: { [self] in self.runnerShouldCancel() },
            stderrLine: { [self] line in self.runnerStderr(line) },
            progress: { [self] sent, total in self.runnerProgress(sent, total) },
            spawned: { [self] pid in
                self.lock.withLock { self.deployPID = pid }
                self.log(.debug, "deploy step: ssh", [LogField("pid", pid), LogField("command", Util.clipChars(command, 120))])
            }
        )
        defer { lock.withLock { deployPID = nil } }
        let res = try runChild(argv: argv, env: at.env, hooks: hooks, options: RunOptions(stdinFile: stdinFile))
        log(.debug, "deploy step: ssh exited", [LogField("pid", res.pid), LogField("code", res.exit.logCode), LogField("signal", res.exit.logSignal)])
        return res
    }

    private func runnerShouldCancel() -> Bool {
        wake.drain()
        guard let why = stopPending() else {
            // resume only concerns live tunnels
            lock.withLock { cmdResume = false }
            return false
        }
        let pid = lock.withLock { deployPID }
        log(.info, "deploy step killed (\(why))", [LogField("pid", pid)])
        return true
    }

    private func runnerStatus(_ step: Deployer.Step, _ message: String, _ sent: UInt64, _ total: UInt64) {
        if stopPending() != nil { return }
        // progress messages differ only by a percentage; log each step once
        let key = ConnectionSupervisor.stepKey(message)
        if key != lastStep {
            lastStep = key
            log(.info, "deploy: \(message)")
        }
        let s: ConnectionStep
        switch step {
        case .probing: s = .probing
        case .pushing: s = .pushing
        case .starting: s = .starting
        }
        setStatus(StatusUpdate(state: .connecting, msg: message, step: s, pushSent: sent, pushTotal: total))
    }

    /// `msg.replace(/\s*\d+%.*$/, '')`
    static func stepKey(_ msg: String) -> String {
        let scalars = Array(msg.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard ("0"..."9").contains(scalars[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < scalars.count && ("0"..."9").contains(scalars[j]) { j += 1 }
            if j < scalars.count && scalars[j] == "%" {
                var k = i
                while k > 0 && (scalars[k - 1] == " " || scalars[k - 1] == "\t") { k -= 1 }
                return String(String.UnicodeScalarView(scalars[0..<k]))
            }
            i = j
        }
        return msg
    }

    private func runnerProgress(_ sent: UInt64, _ total: UInt64) {
        let pct = sent * 100 / max(total, 1)
        let mb = Double(total) / 1024.0 / 1024.0
        runnerStatus(.pushing, "pushing webmux… \(pct)% of \(String(format: "%.1f", mb)) MB", sent, total)
    }

    private func runnerStderr(_ line: String) {
        log(.warn, "ssh: \(line)")
        pushTail(line)
    }

    // -- the tunnel + probe loop ------------------------------------------------

    private func runTunnel(_ at: Attempt, remoteSock: String) -> Next {
        let t = timing
        guard let local = try? engine.paths.socketPath(for: at.profile) else { return onTunnelDown(nil) }
        try? Util.makePath(engine.paths.runDir, mode: 0o700)
        // The password was looked up when this attempt began; if it was
        // cleared since (during the deploy steps), it must not reach the
        // tunnel: start the attempt over with a fresh lookup.
        if at.hasPassword && engine.passwordStore != nil && !engine.passwordStored(at.profile.id) {
            log(.info, "saved password was cleared during the attempt — starting over without it")
            return .attempt
        }
        let argv = SSHCommand.tunnelArgv(ssh: engine.sshPath, at.profile, hasPassword: at.hasPassword, localSocket: local, remoteSocket: remoteSock)
        let p: ChildProcess
        do {
            p = try ChildProcess.spawn(argv: argv, env: at.env, stdin: .ignore, stdout: .ignore, stderr: .pipe)
        } catch {
            // spawn failure (no ssh binary)
            let m = (error as? SpawnError)?.text(program: engine.sshPath) ?? "spawn ssh failed"
            log(.error, "tunnel spawn error", [LogField("error", m)])
            pushTail(m)
            return onTunnelDown(nil)
        }
        // The password was only needed for the spawn.
        at.env.removeValue(forKey: SSHCommand.passwordEnv)
        let spawnedAt = Util.monoMs()
        log(.info, "tunnel spawned", [LogField("pid", p.pid), LogField("socket", local), LogField("remoteSock", remoteSock), LogField("cmd", SSHCommand.joinForLog(argv))])
        lock.withLock {
            socketPath = local
            tunnelPID = p.pid
            step = .tunnel
        }
        publish()

        var errSplit = LineSplitter()
        let onLine: (String) -> Void = { [self] l in
            self.log(.warn, "ssh: \(l)")
            self.pushTail(l)
        }
        var chunk = [UInt8](repeating: 0, count: 4096)
        var misses = 0
        var answered = false
        let started = Util.monoMs()
        var nextProbe = started
        var killed = false
        var exitFields: ((ExitStatus) -> [LogField]) {
            { e in [LogField("pid", p.pid), LogField("code", e.logCode), LogField("signal", e.logSignal), LogField("uptimeMs", Util.monoMs() - spawnedAt)] }
        }

        let result: Next
        loop: while true {
            let now = Util.monoMs()
            let timeout: Int32 = killed ? 200 : Int32(min(max(nextProbe - now, 0), 60_000))
            var fds = [
                pollfd(fd: wake.r, events: Int16(POLLIN), revents: 0),
                pollfd(fd: p.stderrFD ?? -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: p.exitFD, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&fds, 3, timeout)

            // commands
            if fds[0].revents != 0 {
                wake.drain()
                if let why = stopPending() {
                    // stopTunnel: this cycle is superseded (connect/reconnect)
                    // or over (disconnect/quit); commandNext acts on it.
                    log(.info, "tunnel killed (\(why))", [LogField("pid", p.pid)])
                    let exit = p.terminate(graceMs: Int32(t.killGraceMs))
                    log(.info, "tunnel exited (superseded)", exitFields(exit))
                    result = .command
                    break loop
                }
                if takeResume() && !killed {
                    // Lid-open: the pre-sleep tunnel is dead but doesn't know
                    // it yet; kill it so reconnection starts now. The exit
                    // path decides what follows.
                    log(.info, "killing pre-sleep tunnel to reconnect now", [LogField("pid", p.pid)])
                    retryDelayMs = 0
                    killed = true
                    p.signal(SIGTERM)
                }
            }

            // ssh stderr
            if fds[1].revents != 0, let fd = p.stderrFD {
                while let got = readSome(fd, &chunk) {
                    if got == 0 {
                        errSplit.flush(onLine)
                        p.closeStderr()
                        break
                    }
                    errSplit.feed(chunk[0..<got], onLine)
                }
            }

            // exit
            if fds[2].revents != 0 || !p.process.isRunning {
                if let fd = p.stderrFD {
                    while let got = readSome(fd, &chunk) {
                        if got == 0 { break }
                        errSplit.feed(chunk[0..<got], onLine)
                    }
                }
                errSplit.flush(onLine)
                let exit = p.wait()
                log(.warn, "tunnel exited", exitFields(exit))
                result = onTunnelDown(exit)
                break loop
            }

            // probe
            if !killed && Util.monoMs() >= nextProbe {
                let miss = engine.prober.probe(socketPath: local, timeoutMs: t.probeTimeoutMs)
                let after = Util.monoMs()
                if miss == nil {
                    if !answered {
                        answered = true
                        log(.info, "probe: server answered through the tunnel", [LogField("afterMs", after - started)])
                    } else if misses > 0 {
                        log(.info, "probe: server answering again", [LogField("misses", misses)])
                    }
                    misses = 0
                    onServerUp()
                    nextProbe = after + Int64(t.probeIntervalMs)
                } else {
                    let st = lock.withLock { state }
                    if st != .connected {
                        // Not up yet. `webmux-host start` just verified the
                        // socket answers, so a forward that never reaches it
                        // is broken.
                        if after - started > Int64(t.probeFirstAnswerMs) {
                            giveUp(p, misses: misses, started: started, why: "server did not answer through the tunnel")
                            killed = true
                        } else {
                            nextProbe = after + Int64(t.probeRetryMs)
                        }
                    } else {
                        misses += 1
                        log(.warn, "probe missed (\(misses)/\(t.probeMisses))", [LogField("error", (miss?.isEmpty == false) ? miss! : "no answer")])
                        if misses >= t.probeMisses {
                            giveUp(p, misses: misses, started: started, why: "server unreachable through the tunnel — reconnecting")
                            killed = true
                        } else {
                            nextProbe = after + Int64(t.probeIntervalMs)
                        }
                    }
                }
            }
            if killed && !p.exited(timeoutMs: 0) {
                // escalate if SIGTERM is ignored
                if !p.exited(timeoutMs: Int32(t.killGraceMs)) { p.signal(SIGKILL) }
            }
        }
        // the tunnel is gone either way
        if p.reaped == nil { _ = p.terminate(graceMs: Int32(t.killGraceMs)) }
        p.releaseAll()
        Util.unlink(local)
        lock.withLock { tunnelPID = nil }
        return result
    }

    private func giveUp(_ p: ChildProcess, misses: Int, started: Int64, why: String) {
        log(.error, "probe: \(why)", [LogField("misses", misses), LogField("pid", p.pid), LogField("afterMs", Util.monoMs() - started)])
        pushTail(why)
        retryDelayMs = 0 // a link we declared dead should be retried at once
        p.signal(SIGTERM) // exit → onTunnelDown decides retry vs failed
    }

    /// main.js onServerUp (the conn half; attaching panes is the app's, on
    /// the `.connected` status event).
    private func onServerUp() {
        retryDelayMs = 0 // healthy — next failure retries immediately
        let was: ConnectionState = lock.withLock {
            hadConnection = true // from here on, a drop is an interruption → auto-retry
            return state
        }
        if was != .connected { setStatus(StatusUpdate(state: .connected, step: .tunnel)) }
    }
}
