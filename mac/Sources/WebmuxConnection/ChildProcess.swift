// Child processes for the supervisor (proc.zig): Foundation `Process`
// spawns, a pollable exit fd (a self-pipe written by the termination
// handler), interruptible I/O loops, and kill-then-reap (SIGTERM, SIGKILL
// after a grace period).
//
// Every blocking wait here polls a "wake" fd as well, so a command from the
// app (disconnect, reconnect, quit) interrupts it promptly.
import Foundation

public enum ExitStatus: Equatable, Sendable, CustomStringConvertible {
    case code(Int32)
    case signal(Int32)
    case unknown

    /// `code ?? signal` as main.js formats it: `255`, `SIGTERM`.
    public var description: String {
        switch self {
        case .code(let n): return String(n)
        case .signal(let s): return ChildProcess.signalName(s)
        case .unknown: return "null"
        }
    }

    public var ok: Bool { self == .code(0) }

    var logCode: LogValue {
        if case .code(let n) = self { return .int(Int64(n)) }
        return .null
    }

    var logSignal: LogValue {
        if case .signal(let s) = self { return .string(ChildProcess.signalName(s)) }
        return .null
    }

    /// main.js's `exitCode` (`code ?? signal`) as a log value.
    var logExitCode: LogValue {
        switch self {
        case .code(let n): return .int(Int64(n))
        case .signal(let s): return .string(ChildProcess.signalName(s))
        case .unknown: return .null
        }
    }
}

public enum SpawnError: Error, Equatable, Sendable {
    case fileNotFound
    case accessDenied
    case failed(String)

    /// "spawn ssh ENOENT"-style text (Node's wording).
    public func text(program: String) -> String {
        let code: String
        switch self {
        case .fileNotFound: code = "ENOENT"
        case .accessDenied: code = "EACCES"
        case .failed: code = "failed"
        }
        return "spawn \(Util.basename(program)) \(code)"
    }
}

enum Stdio { case pipe, ignore }

/// A self-pipe used to interrupt polls from other threads.
final class WakePipe: @unchecked Sendable {
    let r: Int32
    let w: Int32

    init() {
        var fds: [Int32] = [0, 0]
        _ = pipe(&fds)
        r = fds[0]
        w = fds[1]
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            Util.setNonblock(fd)
        }
    }

    deinit {
        close(r)
        close(w)
    }

    func wake() {
        var b: UInt8 = 1
        _ = write(w, &b, 1)
    }

    /// Drain (non-blocking).
    func drain() {
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            let n = read(r, &buf, buf.count)
            if n <= 0 { return }
        }
    }

    /// Wait until readable or `timeoutMs` (-1 = forever).
    func wait(timeoutMs: Int32) {
        var fds = [pollfd(fd: r, events: Int16(POLLIN), revents: 0)]
        _ = poll(&fds, 1, timeoutMs)
    }
}

/// Read what is available. nil on EAGAIN, 0 on EOF (or error).
func readSome(_ fd: Int32, _ buf: inout [UInt8]) -> Int? {
    while true {
        let n = read(fd, &buf, buf.count)
        if n >= 0 { return n }
        switch errno {
        case EINTR: continue
        case EAGAIN: return nil
        default: return 0
        }
    }
}

/// Splits a byte stream into lines (no empty lines, as main.js filters
/// them), carrying partial lines across reads.
struct LineSplitter {
    private var buf: [UInt8] = []
    private let max = 4096

    mutating func feed(_ bytes: ArraySlice<UInt8>, _ onLine: (String) -> Void) {
        for b in bytes {
            if b == 0x0a {
                flush(onLine)
                continue
            }
            if buf.count == max { flush(onLine) }
            buf.append(b)
        }
    }

    mutating func flush(_ onLine: (String) -> Void) {
        var line = buf
        buf.removeAll(keepingCapacity: true)
        while line.last == 0x0d { line.removeLast() }
        if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
    }
}

/// One spawned child.
final class ChildProcess {
    let process: Process
    let pid: pid_t
    private let exitPipe = WakePipe()
    private(set) var stdinFD: Int32?
    private(set) var stdoutFD: Int32?
    private(set) var stderrFD: Int32?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private(set) var reaped: ExitStatus?

    var exitFD: Int32 { exitPipe.r }

    private init(process: Process, stdin: FileHandle?, stdout: FileHandle?, stderr: FileHandle?) {
        self.process = process
        self.pid = process.processIdentifier
        stdinHandle = stdin
        stdoutHandle = stdout
        stderrHandle = stderr
        stdinFD = stdin?.fileDescriptor
        stdoutFD = stdout?.fileDescriptor
        stderrFD = stderr?.fileDescriptor
        for fd in [stdinFD, stdoutFD, stderrFD].compactMap({ $0 }) { Util.setNonblock(fd) }
    }

    static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGABRT: return "SIGABRT"
        case SIGKILL: return "SIGKILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        default: return "SIGNAL"
        }
    }

    /// Spawn `argv` (argv[0] a path) with exactly `env`.
    static func spawn(argv: [String], env: [String: String], stdin: Stdio, stdout: Stdio, stderr: Stdio) throws -> ChildProcess {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = env
        let inPipe = stdin == .pipe ? Pipe() : nil
        let outPipe = stdout == .pipe ? Pipe() : nil
        let errPipe = stderr == .pipe ? Pipe() : nil
        p.standardInput = inPipe ?? FileHandle.nullDevice
        p.standardOutput = outPipe ?? FileHandle.nullDevice
        p.standardError = errPipe ?? FileHandle.nullDevice
        let exitPipeHolder = Holder()
        p.terminationHandler = { _ in exitPipeHolder.pipe?.wake() }
        do {
            try p.run()
        } catch {
            if access(argv[0], F_OK) != 0 { throw SpawnError.fileNotFound }
            if access(argv[0], X_OK) != 0 { throw SpawnError.accessDenied }
            throw SpawnError.failed("\(error)")
        }
        let child = ChildProcess(process: p, stdin: inPipe?.fileHandleForWriting, stdout: outPipe?.fileHandleForReading, stderr: errPipe?.fileHandleForReading)
        exitPipeHolder.pipe = child.exitPipe
        // (the handler may already have fired for a child that died at once)
        if !p.isRunning { child.exitPipe.wake() }
        return child
    }

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pipe: WakePipe?
        var pipe: WakePipe? {
            get { lock.withLock { _pipe } }
            set { lock.withLock { _pipe = newValue } }
        }
    }

    func closeStdin() {
        if let h = stdinHandle {
            try? h.close()
            stdinHandle = nil
            stdinFD = nil
        }
    }

    func closeStdout() {
        if let h = stdoutHandle {
            try? h.close()
            stdoutHandle = nil
            stdoutFD = nil
        }
    }

    func closeStderr() {
        if let h = stderrHandle {
            try? h.close()
            stderrHandle = nil
            stderrFD = nil
        }
    }

    /// Send a signal (ignored once reaped).
    func signal(_ sig: Int32) {
        if reaped != nil { return }
        kill(pid, sig)
    }

    /// True once the child has exited (does not reap).
    func exited(timeoutMs: Int32) -> Bool {
        if reaped != nil { return true }
        if !process.isRunning { return true }
        var fds = [pollfd(fd: exitPipe.r, events: Int16(POLLIN), revents: 0)]
        let n = poll(&fds, 1, timeoutMs)
        return n > 0
    }

    /// Reap the child (blocks until it exits) and release its fds.
    func wait() -> ExitStatus {
        if let e = reaped { return e }
        process.waitUntilExit()
        let e: ExitStatus
        switch process.terminationReason {
        case .exit: e = .code(process.terminationStatus)
        case .uncaughtSignal: e = .signal(process.terminationStatus)
        @unknown default: e = .unknown
        }
        reaped = e
        return e
    }

    /// SIGTERM, then SIGKILL if it is still alive after `graceMs`; reaps.
    func terminate(graceMs: Int32) -> ExitStatus {
        if let e = reaped { return e }
        signal(SIGTERM)
        if !exited(timeoutMs: graceMs) { signal(SIGKILL) }
        return wait()
    }

    func releaseAll() {
        closeStdin()
        closeStdout()
        closeStderr()
    }
}

// ---------------------------------------------------------------------------
// run: a command to completion
// ---------------------------------------------------------------------------

struct RunHooks {
    /// Polled alongside the child's fds; when readable `shouldCancel` is
    /// asked (it should drain the fd).
    var wakeFD: Int32
    var shouldCancel: () -> Bool
    var stderrLine: (String) -> Void
    /// Push progress (stdin feeding): bytes sent / total.
    var progress: ((UInt64, UInt64) -> Void)? = nil
    var spawned: ((pid_t) -> Void)? = nil
}

struct RunResult {
    var stdout: String
    var exit: ExitStatus
    var pid: pid_t
}

enum RunError: Error {
    case cancelled
    case inputUnreadable
    case spawn(SpawnError)
}

struct RunOptions {
    /// Stream this file to the child's stdin (then close it).
    var stdinFile: String? = nil
    /// Kill the child (SIGTERM) after this long.
    var timeoutMs: Int64? = nil
    var maxStdout = 4 * 1024 * 1024
}

/// Run a command to completion: collect stdout, hand stderr lines to the
/// hooks, optionally feed a file to stdin, honour cancellation and a
/// timeout. A cancelled run kills the child and throws `.cancelled`.
func runChild(argv: [String], env: [String: String], hooks: RunHooks, options: RunOptions) throws -> RunResult {
    var inputFD: Int32 = -1
    var inputTotal: UInt64 = 0
    if let path = options.stdinFile {
        guard let size = Util.fileSize(path) else { throw RunError.inputUnreadable }
        inputTotal = size
        inputFD = open(path, O_RDONLY | O_CLOEXEC)
        if inputFD < 0 { throw RunError.inputUnreadable }
    }
    defer { if inputFD >= 0 { close(inputFD) } }

    let p: ChildProcess
    do {
        p = try ChildProcess.spawn(argv: argv, env: env, stdin: .pipe, stdout: .pipe, stderr: .pipe)
    } catch let e as SpawnError {
        throw RunError.spawn(e)
    }
    defer { p.releaseAll() }
    hooks.spawned?(p.pid)
    var out: [UInt8] = []
    var errSplit = LineSplitter()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var inBuf = [UInt8](repeating: 0, count: 65536)
    var inLen = 0
    var inOff = 0
    var sent: UInt64 = 0
    var inputEOF = inputFD < 0
    let deadline: Int64? = options.timeoutMs.map { Util.monoMs() + $0 }
    var timedOut = false

    if inputFD < 0 {
        p.closeStdin() // child.stdin.end()
    } else {
        hooks.progress?(0, inputTotal)
    }

    func drainOut() {
        guard let fd = p.stdoutFD else { return }
        while let got = readSome(fd, &chunk) {
            if got == 0 {
                p.closeStdout()
                break
            }
            if out.count + got <= options.maxStdout { out.append(contentsOf: chunk[0..<got]) }
        }
    }
    func drainErr() {
        guard let fd = p.stderrFD else { return }
        while let got = readSome(fd, &chunk) {
            if got == 0 {
                errSplit.flush(hooks.stderrLine)
                p.closeStderr()
                break
            }
            errSplit.feed(chunk[0..<got], hooks.stderrLine)
        }
    }

    loop: while true {
        var fds: [pollfd] = [
            pollfd(fd: hooks.wakeFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: p.stdoutFD ?? -1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: p.stderrFD ?? -1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: p.exitFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: p.stdinFD ?? -1, events: Int16(POLLOUT), revents: 0),
        ]
        var timeout: Int32 = -1
        if let d = deadline {
            let left = d - Util.monoMs()
            if left <= 0 {
                if !timedOut {
                    timedOut = true
                    p.signal(SIGTERM)
                }
                timeout = 200
            } else {
                timeout = Int32(min(left, 60_000))
            }
        }
        _ = poll(&fds, nfds_t(fds.count), timeout)

        if fds[0].revents != 0 {
            if hooks.shouldCancel() {
                _ = p.terminate(graceMs: 2000)
                throw RunError.cancelled
            }
        }
        if fds[1].revents != 0 { drainOut() }
        if fds[2].revents != 0 { drainErr() }
        if fds[4].revents != 0, let fd = p.stdinFD {
            if fds[4].revents & Int16(POLLERR | POLLHUP) != 0 {
                // remote side gone (EPIPE) — the exit status reports it
                p.closeStdin()
            } else {
                while true {
                    if inOff == inLen && !inputEOF {
                        let r = read(inputFD, &inBuf, inBuf.count)
                        if r <= 0 {
                            inputEOF = true
                        } else {
                            inLen = r
                            inOff = 0
                        }
                    }
                    if inOff == inLen {
                        if inputEOF { p.closeStdin() }
                        break
                    }
                    let w = inBuf.withUnsafeBufferPointer { buf in write(fd, buf.baseAddress! + inOff, inLen - inOff) }
                    if w < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        if e != EAGAIN { p.closeStdin() }
                        break
                    }
                    inOff += w
                    let before = sent
                    sent += UInt64(w)
                    if let f = hooks.progress, inputTotal > 0, sent * 100 / inputTotal != before * 100 / inputTotal { f(sent, inputTotal) }
                }
            }
        }

        let childGone = fds[3].revents != 0 || !p.process.isRunning
        if childGone || (p.stdoutFD == nil && p.stderrFD == nil && p.stdinFD == nil) {
            if p.stdoutFD == nil && p.stderrFD == nil { break loop }
            if childGone {
                // Exited, but a grandchild may hold the pipes open: take what
                // is buffered and stop.
                drainOut()
                drainErr()
                errSplit.flush(hooks.stderrLine)
                break loop
            }
        }
    }
    let exit = p.wait()
    return RunResult(stdout: String(decoding: out, as: UTF8.self), exit: exit, pid: p.pid)
}
