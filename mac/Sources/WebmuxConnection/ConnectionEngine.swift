// The engine: the config store, the log, one supervisor per live connection
// (keyed by profile name; one live connection per host+instance, deviation
// 8), Restart Sessions workers, and the operations the UI invokes (main.js's
// IPC section).
//
// Locking: `lock` guards the store and the connection lists. Each
// connection has its own lock; lock order is engine → connection, and no
// callback is ever invoked with a lock held.
import Foundation

public struct RestartResult: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    /// user-facing outcome ("sessions restarted — …") or error text
    public var msg: String
}

public enum ConnectionEvent: Sendable {
    /// a connection's status changed (state, message, progress, countdown
    /// start, stderr)
    case status(ConnectionStatus)
    /// a disconnected connection finished tearing down (its thread exited)
    case removed(name: String)
    /// Restart Sessions finished; on `ok` a live connection's panes refer to
    /// sessions that no longer exist (the app reloads them)
    case restartDone(RestartResult)
    /// the client-wide settings changed
    case settings(Settings)
}

public struct EngineOptions {
    public var paths: Paths
    /// Base environment: the environment of every ssh child (and `PATH` for
    /// finding ssh). Never contains a password.
    public var environment: [String: String]
    /// The ssh program (PATH-resolved when it has no '/').
    public var sshExecutable: String = "ssh"
    public var prober: HostProber = SocketHostProber()
    public var passwordStore: PasswordStore? = nil
    /// Name of the password store for the "client started" log line.
    public var passwordStoreName: String? = nil
    /// The macOS Local Network handling (X-40, X-41); nil turns it off.
    public var localNetwork: LocalNetworkProber? = DarwinLocalNetworkProber()
    public var timing = ConnectionTiming()
    /// For the "client started" log line.
    public var version: String = ""
    /// First run (deviation 5): with no config.json of ours, import the
    /// profiles (not passwords) from the first of these that exists.
    public var electronConfigCandidates: [String] = Paths.electronConfigCandidates()
    /// Invoked on engine threads with no lock held; hop to the main queue.
    public var onEvent: (@Sendable (ConnectionEvent) -> Void)? = nil

    public init(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = environment
    }
}

public struct EngineError: Error, CustomStringConvertible {
    public let description: String
}

public final class ConnectionEngine: @unchecked Sendable {
    public let paths: Paths
    public let log: ConnectionLog
    public let timing: ConnectionTiming
    let environment: [String: String]
    let sshPath: String
    let askpassPath: String
    let prober: HostProber
    let passwordStore: PasswordStore?
    let localNetwork: LocalNetworkProber?
    /// macOS gates LAN connections behind a per-app grant; the probe and the
    /// hint exist only when a `LocalNetworkProber` is configured.
    var lanGated: Bool { localNetwork != nil }
    private let onEvent: (@Sendable (ConnectionEvent) -> Void)?
    private let continuation: AsyncStream<ConnectionEvent>.Continuation
    /// Every event, for `for await`; the same events as `onEvent`.
    public let events: AsyncStream<ConnectionEvent>

    private let lock = NSLock()
    private let store: ConfigStore
    private var conns: [ConnectionSupervisor] = []
    /// disconnected connections whose threads may still be tearing down
    private var dying: [ConnectionSupervisor] = []
    private var workers: [RestartWorker] = []
    private var lanWarmed: Set<String> = []
    let quitPipe = WakePipe()
    private var _quitting = false
    var quitting: Bool { lock.withLock { _quitting } }
    private var shutDown = false

    /// Load config.json, open the log file, write the askpass helper, log
    /// "client started", import Electron profiles on a first run. No
    /// connection is started (connecting is the user's call).
    public init(options: EngineOptions) throws {
        signal(SIGPIPE, SIG_IGN)
        paths = options.paths
        environment = options.environment
        timing = options.timing
        prober = options.prober
        passwordStore = options.passwordStore
        localNetwork = options.localNetwork
        onEvent = options.onEvent
        sshPath = SSHCommand.resolveExecutable(options.sshExecutable, environment: options.environment)
        let (stream, cont) = AsyncStream<ConnectionEvent>.makeStream()
        events = stream
        continuation = cont
        log = ConnectionLog()
        log.openFile(inDirectory: paths.logsDir)
        try? Util.makePath(paths.runDir, mode: 0o700)
        do {
            try Util.ensurePrivateDir(paths.runDir)
        } catch {
            log.error(nil, "run dir is not a private directory of ours — refusing to use it", [LogField("dir", paths.runDir), LogField("error", "\(error)")])
            throw EngineError(description: "the run directory \(paths.runDir) is not a private directory of ours")
        }
        askpassPath = (try? SSHCommand.ensureAskpass(dir: paths.runDir)) ?? paths.askpassFile
        store = ConfigStore(file: paths.configFile)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        log.info(nil, "client started", [
            LogField("version", options.version), LogField("platform", "darwin-\(arch)"),
            LogField("passwordStore", optional: options.passwordStoreName), LogField("logFile", optional: log.filePath),
        ])
        let firstRun = !Util.fileExists(paths.configFile)
        store.load()
        if let r = store.loadReport {
            if let why = r.unreadable {
                log.error(nil, "config.json unreadable", [LogField("error", why), LogField("file", paths.configFile), LogField("keptAs", optional: r.keptAs)])
            }
            for repair in r.repairs {
                log.warn(nil, "config.json repaired", [LogField("repair", repair), LogField("file", paths.configFile)])
            }
        }
        if firstRun { importElectronProfiles(candidates: options.electronConfigCandidates) }
    }

    /// Quit: log "client quitting", stop every connection (kills its ssh
    /// children) and wait for all engine threads. Idempotent.
    public func shutdown() {
        var live: [ConnectionSupervisor] = []
        var ws: [RestartWorker] = []
        let n: Int = lock.withLock {
            if shutDown { return -1 }
            shutDown = true
            _quitting = true
            return conns.count
        }
        if n < 0 { return }
        quitPipe.wake()
        log.info(nil, "client quitting", [LogField("connections", n)])
        lock.withLock {
            live = conns + dying
            conns.removeAll()
            dying.removeAll()
            ws = workers
            workers.removeAll()
        }
        for c in live { c.requestQuit() }
        for c in live { c.join() }
        for w in ws { w.join() }
        continuation.finish()
    }

    deinit {
        if !shutDown { continuation.finish() }
    }

    /// The monotonic clock `ConnectionStatus.retryDeadlineMs` is on.
    public static func nowMs() -> Int64 { Util.monoMs() }
    public func nowMs() -> Int64 { Util.monoMs() }

    func emit(_ ev: ConnectionEvent) {
        onEvent?(ev)
        continuation.yield(ev)
    }

    /// Join and free connections whose teardown finished. Caller holds lock.
    private func reap() {
        dying.removeAll { c in
            if c.isFinished {
                c.join()
                return true
            }
            return false
        }
        workers.removeAll { w in
            if w.isDone {
                w.join()
                return true
            }
            return false
        }
    }

    private func findConn(_ name: String) -> ConnectionSupervisor? {
        conns.first { $0.name == name }
    }

    // -- profiles (main.js profiles:*) ---------------------------------------

    /// Profiles in store order, lastProfile, and the config file path.
    public func listProfiles() -> (profiles: [Profile], lastProfile: String?, file: String) {
        lock.withLock { (store.profiles, store.lastProfile, store.file) }
    }

    public var profiles: [Profile] { lock.withLock { store.profiles } }
    public var lastProfile: String? { lock.withLock { store.lastProfile } }

    public func profile(named name: String) -> Profile? {
        lock.withLock { store.find(name) }
    }

    /// profiles:save: trim, validate (instance rule, name+host required,
    /// unique name), insert or replace (`originalName` = the profile being
    /// edited, nil for new), carry over id and downloadDir, follow a rename
    /// into lastProfile and a live connection (which keeps its tunnel; new
    /// fields apply from its next attempt), save atomically. Returns a
    /// user-facing error, or nil.
    @discardableResult
    public func saveProfile(_ input: ProfileInput, originalName: String? = nil) -> String? {
        lock.withLock {
            reap()
            if let msg = store.save(input, originalName: originalName) { return msg }
            let name = Util.trim(input.name)
            // A live connection for this profile keeps its current tunnel; the
            // new fields take effect on its next connect or reconnect (which
            // re-read the store); automatic retries keep what the live tunnel
            // holds (the socket is the host+instance, so a retry must not
            // move it). The name follows at once.
            if let c = findConn(originalName ?? name), let orig = originalName, orig != name { c.rename(name) }
            return store.save()
        }
    }

    /// The checks `saveProfile` makes, without saving (so the app can store a
    /// password first and reject the whole save if that fails).
    public func validateProfile(_ input: ProfileInput, originalName: String? = nil) -> String? {
        lock.withLock { store.validate(input, originalName: originalName) }
    }

    /// A fresh profile id (16 hex chars) for `ProfileInput.id`.
    public func newProfileID() -> String {
        lock.withLock { store.uniqueID() }
    }

    /// profiles:delete: remove, clear lastProfile if it was this one,
    /// disconnect it ('profile deleted'), save. The app forgets the Keychain item.
    @discardableResult
    public func deleteProfile(_ name: String) -> String? {
        lock.withLock { store.delete(name) }
        disconnect(name, why: "profile deleted")
        return lock.withLock { store.save() }
    }

    /// The download hook: remember where this profile last saved a file.
    @discardableResult
    public func setDownloadDir(_ name: String, _ dir: String) -> String? {
        lock.withLock {
            guard let p = store.find(name) else { return "no such profile" }
            if p.downloadDir == dir { return nil }
            _ = store.setDownloadDir(name, dir)
            return store.save()
        }
    }

    /// Path of config.json (for "Open Config File").
    public var configPath: String { paths.configFile }

    /// If config.json existed but could not be read, parsed or used as is at
    /// startup: a user-facing sentence saying so and where the original was
    /// kept (it is never overwritten). Nil when the config loaded fine.
    public var configProblem: String? { lock.withLock { store.problem } }

    /// Every profile id a stored secret may still belong to (profiles, and
    /// ids in config files kept aside).
    public func referencedIDs() -> [String] { lock.withLock { store.referencedIDs() } }

    /// Profile ids that config.json gave to more than one profile (they were
    /// re-issued at load): the app must forget the secrets stored under them.
    public var droppedPasswordIDs: [String] { lock.withLock { store.droppedIDs } }

    /// The payload directory found at startup, or nil.
    public var payloadDir: String? { paths.payloadDir }

    /// First run: import profiles (never passwords) from the Electron client.
    @discardableResult
    public func importElectronProfiles(candidates: [String]) -> Int {
        for path in candidates where Util.fileExists(path) {
            let result: (imported: Int, refused: [(name: String, error: String)])? = lock.withLock { store.importElectronProfiles(from: path) }
            guard let r = result else {
                log.warn(nil, "could not import the Electron client's profiles", [LogField("file", path), LogField("error", "not a JSON object")])
                return 0
            }
            for (name, err) in r.refused { log.warn(name, "profile not imported", [LogField("error", err)]) }
            if r.imported > 0 {
                lock.withLock { _ = store.save() }
                log.info(nil, "imported profiles from the Electron client", [LogField("file", path), LogField("profiles", r.imported)])
            }
            return r.imported
        }
        return 0
    }

    // -- settings --------------------------------------------------------------

    public var settings: Settings { lock.withLock { store.settings } }

    /// Merge a partial update (sanitized like main.js), save, and emit a
    /// `.settings` event. Returns the new settings.
    @discardableResult
    public func updateSettings(_ patch: Settings.Patch) -> Settings {
        let s: Settings = lock.withLock {
            store.settings = store.settings.sanitized(with: patch)
            _ = store.save()
            return store.settings
        }
        emit(.settings(s))
        return s
    }

    // -- connections --------------------------------------------------------------

    /// Deviation 8: one live connection per host+instance, because they
    /// would share one tunnel socket. A connection is keyed on what it
    /// holds: the host+instance of its current connect cycle (an edit to its
    /// profile applies only from its next connect or reconnect), and it
    /// holds it unless it is parked in `failed` with no tunnel. Caller holds lock.
    private func slugTaken(_ p: Profile, except: ConnectionSupervisor?) -> String? {
        let slug = p.hostSlug
        for c in conns where c !== except && c.holdsSocket && c.slug == slug {
            return "\"\(c.name)\" is already connected to this host and instance"
        }
        return nil
    }

    /// profiles:connect: start (or restart) the connection for a profile. A
    /// connection that is already connected is left alone. Records
    /// lastProfile. Errors: "no such profile", an invalid instance, or the
    /// host+instance already in use by another live connection.
    @discardableResult
    public func connect(_ name: String) -> String? { connect(name, why: "connect") }

    func connect(_ name: String, why: String) -> String? {
        lock.withLock {
            reap()
            if _quitting { return "quitting" }
            guard let p = store.find(name) else { return "no such profile" }
            if !p.instance.isEmpty && !Profile.validInstance(p.instance) { return "invalid instance name in profile" }
            if !Profile.validPort(p.sshPort) { return Profile.portError }
            let existing = findConn(name)
            if let c = existing, c.isConnected { return nil } // already connected and healthy
            if let msg = slugTaken(p, except: existing) { return msg }
            let c: ConnectionSupervisor
            if let e = existing {
                c = e
            } else {
                c = ConnectionSupervisor(engine: self, profile: p)
                conns.append(c)
                c.start()
            }
            c.setProfile(p)
            store.setLastProfile(name)
            _ = store.save() // lastProfile
            c.requestConnect(why)
            return nil
        }
    }

    /// Reconnect (⌘⇧R): re-read the profile and restart the connect cycle,
    /// whatever its state.
    @discardableResult
    public func reconnect(_ name: String) -> String? {
        lock.withLock {
            reap()
            guard let c = findConn(name) else { return "not connected" }
            if let p = store.find(name) {
                if !p.instance.isEmpty && !Profile.validInstance(p.instance) { return "invalid instance name in profile" }
                if !Profile.validPort(p.sshPort) { return Profile.portError }
                if let msg = slugTaken(p, except: c) { return msg }
                c.setProfile(p)
            }
            store.setLastProfile(name)
            _ = store.save()
            c.requestConnect("reconnect")
            return nil
        }
    }

    /// conns:disconnect: stop the connection and forget it. Returns at once;
    /// the connection vanishes from `snapshot` immediately and a `.removed`
    /// event follows when its ssh children are gone.
    public func disconnect(_ name: String) { disconnect(name, why: "user") }

    func disconnect(_ name: String, why: String) {
        let c: ConnectionSupervisor? = lock.withLock {
            reap()
            guard let i = conns.firstIndex(where: { $0.name == name }) else { return nil }
            let c = conns.remove(at: i)
            dying.append(c)
            return c
        }
        guard let c = c else { return }
        // Logged unlocked (log subscribers may call back into the engine).
        log.info(name, "disconnecting (\(why))", [LogField("state", c.stateName)])
        c.requestDisconnect(why)
    }

    /// Wake from sleep (the app calls this from NSWorkspace's
    /// didWakeNotification): kill every live tunnel (they are dead but don't
    /// know it yet) so reconnection starts now; the exit path decides what
    /// follows (auto-retry only if the cycle was ever connected).
    public func notifyResume() {
        let n = lock.withLock { conns.filter { $0.hasTunnel }.count }
        log.info(nil, "system resumed from sleep", [LogField("tunnelsKilled", n)])
        let cs = lock.withLock { conns }
        for c in cs { c.requestResume() }
    }

    /// conns:reorder: new order; unknown names are ignored, missing ones
    /// keep their relative order at the end.
    public func reorder(_ names: [String]) {
        lock.withLock {
            var ordered: [ConnectionSupervisor] = []
            for n in names {
                guard let c = findConn(n), !ordered.contains(where: { $0 === c }) else { continue }
                ordered.append(c)
            }
            for c in conns where !ordered.contains(where: { $0 === c }) { ordered.append(c) }
            conns = ordered
        }
    }

    /// Every connection's status in order.
    public func snapshot() -> [ConnectionStatus] {
        lock.withLock { conns.map { $0.status } }
    }

    /// One connection's status, or nil if it has none.
    public func status(_ name: String) -> ConnectionStatus? {
        lock.withLock { findConn(name)?.status }
    }

    // -- password ----------------------------------------------------------------

    /// Whether the store knows of a saved password (no prompt).
    func passwordStored(_ id: String) -> Bool {
        passwordStore?.has(profileID: id) ?? false
    }

    /// Ask the store. Never logs the password.
    func lookupPassword(_ p: Profile) -> PasswordState {
        guard let store = passwordStore else { return PasswordState() }
        switch store.lookup(profileID: p.id) {
        case .none: return PasswordState()
        case .found(let pw): return PasswordState(password: pw)
        case .unavailable(let why): return PasswordState(unavailable: why)
        }
    }

    func isLanWarmed(_ key: String) -> Bool { lock.withLock { lanWarmed.contains(key) } }
    func markLanWarmed(_ key: String) { lock.withLock { _ = lanWarmed.insert(key) } }

    // -- Restart Sessions -------------------------------------------------------

    /// profiles:restart-sessions: shut down the profile's remote pty host
    /// over a one-off ssh (every shell in it dies). Runs on a worker thread;
    /// the outcome arrives as a `.restartDone` event and in the log. Errors
    /// returned here: "no such profile", invalid instance.
    @discardableResult
    public func restartSessions(_ name: String) -> String? {
        lock.withLock {
            reap()
            guard let p = store.find(name) else { return "no such profile" }
            // The instance name lands in a remote shell command; saved profiles
            // are validated, but re-check in case config.json was edited by hand.
            if !p.instance.isEmpty && !Profile.validInstance(p.instance) { return "invalid instance name in profile" }
            let w = RestartWorker(engine: self, profile: p)
            workers.append(w)
            w.start()
            return nil
        }
    }
}

/// A Restart Sessions run on its own thread.
final class RestartWorker: @unchecked Sendable {
    unowned let engine: ConnectionEngine
    let profile: Profile
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _done = false
    private var errLines: [String] = []

    init(engine: ConnectionEngine, profile: Profile) {
        self.engine = engine
        self.profile = profile
    }

    var isDone: Bool { lock.withLock { _done } }

    func start() {
        let t = Thread { [self] in self.run() }
        t.name = "webmux.restart.\(profile.name)"
        t.start()
    }

    func join() { done.wait() }

    private func run() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &set, nil)
        let e = engine
        let name = profile.name
        let instance = profile.instanceOrDefault
        var result = RestartResult(name: name, ok: false, msg: "")
        defer {
            e.emit(.restartDone(result))
            lock.withLock { _done = true }
            done.signal()
        }
        var pw = e.lookupPassword(profile)
        if pw.unavailable != nil {
            result.msg = "saved password could not be decrypted — edit the profile and re-enter it"
            e.log.error(name, "restart sessions: \(result.msg)")
            return
        }
        e.log.info(name, "restart sessions requested", [LogField("instance", instance)])
        let outcome = runRestart(&pw)
        result.ok = outcome.ok
        result.msg = outcome.msg
        e.log.at(outcome.ok ? .info : .error, name, "restart sessions: \(outcome.msg)")
    }

    private func runRestart(_ pw: inout PasswordState) -> (ok: Bool, msg: String) {
        let e = engine
        let hashes = Deployer.manifestHashes(payloadDir: e.paths.payloadDir)
        let script = Deployer.restartScript(instance: profile.instanceOrDefault, hashes: hashes)
        let command = Deployer.shWrap(script)
        let argv = SSHCommand.commandArgv(ssh: e.sshPath, profile, hasPassword: pw.has, command: command)
        let env = SSHCommand.childEnvironment(base: e.environment, askpassPath: e.askpassPath, password: pw.password)
        pw.wipe()
        let hooks = RunHooks(wakeFD: e.quitPipe.r,
                             shouldCancel: { [self] in self.engine.quitting },
                             stderrLine: { [self] l in self.lock.withLock { self.errLines.append(l) } })
        do {
            let res = try runChild(argv: argv, env: env, hooks: hooks, options: RunOptions(timeoutMs: Int64(e.timing.restartTimeoutMs)))
            return Deployer.restartOutcome(stdout: res.stdout, exit: res.exit, stderrLines: lock.withLock { errLines })
        } catch RunError.spawn(let se) {
            return (false, se.text(program: e.sshPath))
        } catch RunError.cancelled {
            return (false, "cancelled (quitting)")
        } catch {
            return (false, "\(error)")
        }
    }
}
