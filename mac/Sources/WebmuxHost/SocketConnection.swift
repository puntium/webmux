// A connected unix stream socket with a read buffer, a deadline on every
// blocking operation, and `interrupt()`: a thread-safe way to make a read or
// write that is blocked in another task return promptly with
// `HostError.cancelled`. Port of the fork's `src/webmux/net/Conn.zig`.
//
// The socket is non-blocking. Every syscall runs on the connection's serial
// queue (so `close` never races a read); every wait for readiness is a
// `DispatchSource` armed only while a task is waiting, bounded by the
// caller's deadline. Task cancellation is treated like `interrupt`.
//
// Threading: one task reads, one task writes at a time (the WebSocket layer
// serializes its writers through its actor), and anyone may call
// `interrupt`. `close` is called once by the owner.
import Darwin
import Dispatch
import Foundation

/// An absolute deadline. `nil` time: wait indefinitely.
struct Deadline: Sendable {
    var time: DispatchTime?

    static let never = Deadline(time: nil)

    /// `d` from now; `nil` stays "never".
    static func after(_ d: Duration?) -> Deadline {
        guard let d else { return .never }
        return Deadline(time: .now() + .nanoseconds(d.nanosecondsClamped))
    }

    var hasPassed: Bool {
        guard let t = time else { return false }
        return t.uptimeNanoseconds <= DispatchTime.now().uptimeNanoseconds
    }
}

extension Duration {
    var nanosecondsClamped: Int {
        let (s, atto) = components
        let ns = s.multipliedReportingOverflow(by: 1_000_000_000)
        if ns.overflow { return s < 0 ? Int.min : Int.max }
        return Int(clamping: ns.partialValue + atto / 1_000_000_000)
    }
}

final class SocketConnection: @unchecked Sendable {
    static let readBufferSize = 64 * 1024

    private let fd: Int32
    private let queue = DispatchQueue(label: "me.puntium.webmux.mac.host.socket")
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite

    // Queue-only state.
    private enum Kind { case read, write }
    private enum Wake { case ready, timeout, cancelled }
    private final class Waiter {
        let continuation: CheckedContinuation<Wake, Never>
        var timer: DispatchWorkItem?
        init(_ c: CheckedContinuation<Wake, Never>) { continuation = c }
    }
    private var readWaiter: Waiter?
    private var writeWaiter: Waiter?
    private var readArmed = false
    private var writeArmed = false
    /// Set when the Task was cancelled before its waiter registered.
    private var readCancelPending = false
    private var writeCancelPending = false
    private var interrupted = false
    private var closed = false

    // Reader-owned buffer (touched on the queue, by one reader at a time).
    private var rbuf = [UInt8](repeating: 0, count: SocketConnection.readBufferSize)
    private var rstart = 0
    private var rend = 0

    // MARK: Connecting

    /// Connect to the unix socket at `path`. Unix connects do not block
    /// (the kernel answers at once), so no deadline applies.
    static func connect(path: String) throws -> SocketConnection {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw HostError.nameTooLong(path: path) }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.system(errno: errno) }
        var ok = false
        defer { if !ok { Darwin.close(fd) } }
        // No SOCK_CLOEXEC and no MSG_NOSIGNAL on Darwin: set the flag on the
        // descriptor and suppress SIGPIPE on this socket instead.
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw HostError.system(errno: errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw HostError.system(errno: errno)
        }
        while true {
            let rc = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { break }
            let e = errno
            switch e {
            case EINTR: continue
            case ENOENT, ENOTDIR: throw HostError.socketNotFound(path: path)
            case ECONNREFUSED, EAGAIN: throw HostError.connectionRefused(path: path)
            case EACCES, EPERM: throw HostError.accessDenied(path: path)
            default: throw HostError.system(errno: e)
            }
        }
        // Non-blocking from here on: every wait goes through a source.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw HostError.system(errno: errno) }
        ok = true
        return SocketConnection(fd: fd)
    }

    /// Adopt an already connected stream socket (tests: socketpair). The
    /// descriptor is made non-blocking and owned by the connection.
    init(fd: Int32) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.fired(.read) }
        writeSource.setEventHandler { [weak self] in self?.fired(.write) }
    }

    deinit {
        if !closed { closeOnQueue() }
    }

    // MARK: Lifecycle

    /// Close the socket. Blocked operations fail with `.cancelled`, as do
    /// later ones. Idempotent.
    func close() {
        queue.sync { closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        wake(.read, .cancelled)
        wake(.write, .cancelled)
        // Sources must be resumed when cancelled and released.
        if !readArmed { readSource.resume(); readArmed = true }
        if !writeArmed { writeSource.resume(); writeArmed = true }
        let fd = self.fd
        let remaining = ManagedCounter(2)
        let onCancel = { if remaining.decrement() == 0 { Darwin.close(fd) } }
        readSource.setCancelHandler(handler: onCancel)
        writeSource.setCancelHandler(handler: onCancel)
        readSource.cancel()
        writeSource.cancel()
    }

    /// Make any blocked or future read/write fail with `.cancelled`.
    /// Thread-safe and idempotent; nothing is sent to the peer beyond the
    /// FIN of `shutdown(2)`.
    func interrupt() {
        queue.async {
            self.interrupted = true
            if !self.closed { _ = Darwin.shutdown(self.fd, SHUT_RDWR) }
            self.wake(.read, .cancelled)
            self.wake(.write, .cancelled)
        }
    }

    var isInterrupted: Bool { queue.sync { interrupted } }

    /// Half-close the write side (the peer reads EOF).
    func shutdownWrite() {
        queue.sync { if !closed { _ = Darwin.shutdown(fd, SHUT_WR) } }
    }

    // MARK: Waiting for readiness

    private func fired(_ kind: Kind) {
        switch kind {
        case .read:
            guard readArmed else { return }
            readSource.suspend()
            readArmed = false
        case .write:
            guard writeArmed else { return }
            writeSource.suspend()
            writeArmed = false
        }
        wake(kind, .ready)
    }

    /// Resume the waiter of `kind`, if any, with `reason`. Queue only.
    private func wake(_ kind: Kind, _ reason: Wake) {
        let w: Waiter?
        switch kind {
        case .read: w = readWaiter; readWaiter = nil
        case .write: w = writeWaiter; writeWaiter = nil
        }
        guard let w else { return }
        w.timer?.cancel()
        disarm(kind)
        w.continuation.resume(returning: reason)
    }

    private func disarm(_ kind: Kind) {
        switch kind {
        case .read: if readArmed { readSource.suspend(); readArmed = false }
        case .write: if writeArmed { writeSource.suspend(); writeArmed = false }
        }
    }

    private func register(_ kind: Kind, _ cont: CheckedContinuation<Wake, Never>, _ deadline: Deadline) {
        let cancelPending = kind == .read ? readCancelPending : writeCancelPending
        if kind == .read { readCancelPending = false } else { writeCancelPending = false }
        if closed || interrupted || cancelPending {
            cont.resume(returning: .cancelled)
            return
        }
        if deadline.hasPassed {
            cont.resume(returning: .timeout)
            return
        }
        let w = Waiter(cont)
        if let t = deadline.time {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let current = kind == .read ? self.readWaiter : self.writeWaiter
                if current === w { self.wake(kind, .timeout) }
            }
            w.timer = item
            queue.asyncAfter(deadline: t, execute: item)
        }
        switch kind {
        case .read:
            precondition(readWaiter == nil, "SocketConnection: one reader at a time")
            readWaiter = w
            if !readArmed { readSource.resume(); readArmed = true }
        case .write:
            precondition(writeWaiter == nil, "SocketConnection: one writer at a time")
            writeWaiter = w
            if !writeArmed { writeSource.resume(); writeArmed = true }
        }
    }

    /// Suspend until the socket is ready for `kind`, the deadline passes
    /// (`.timeout`), or the connection is interrupted/closed or the Task
    /// cancelled (`.cancelled`).
    private func wait(_ kind: Kind, deadline: Deadline) async throws {
        let wake: Wake = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Wake, Never>) in
                queue.async { self.register(kind, cont, deadline) }
            }
        } onCancel: {
            queue.async {
                let hasWaiter = kind == .read ? self.readWaiter != nil : self.writeWaiter != nil
                if hasWaiter {
                    self.wake(kind, .cancelled)
                } else if kind == .read {
                    self.readCancelPending = true
                } else {
                    self.writeCancelPending = true
                }
            }
        }
        switch wake {
        case .ready: return
        case .timeout: throw HostError.timeout
        case .cancelled: throw HostError.cancelled
        }
    }

    // MARK: Raw I/O (queue only)

    private enum IOResult { case bytes(Int), wouldBlock }

    /// One non-blocking read into `rbuf[rend...]`. Queue only.
    private func rawReadIntoBuffer() throws -> IOResult {
        if closed || interrupted { throw HostError.cancelled }
        while true {
            let n = rbuf.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress! + rend, raw.count - rend)
            }
            if n >= 0 {
                if n == 0 && interrupted { throw HostError.cancelled }
                return .bytes(n)
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: return .wouldBlock
            case ECONNRESET: throw interrupted ? HostError.cancelled : HostError.connectionReset
            case EPIPE: throw interrupted ? HostError.cancelled : HostError.brokenPipe
            default: throw HostError.system(errno: errno)
            }
        }
    }

    private func rawWrite(_ data: Data, from offset: Int) throws -> IOResult {
        if closed || interrupted { throw HostError.cancelled }
        while true {
            let n = data.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, MSG_DONTWAIT)
            }
            if n >= 0 { return .bytes(n) }
            switch errno {
            case EINTR: continue
            case EAGAIN: return .wouldBlock
            case EPIPE: throw interrupted ? HostError.cancelled : HostError.brokenPipe
            case ECONNRESET: throw interrupted ? HostError.cancelled : HostError.connectionReset
            default: throw HostError.system(errno: errno)
            }
        }
    }

    // MARK: Buffered reading

    /// Bytes buffered and not yet consumed.
    var bufferedCount: Int { queue.sync { rend - rstart } }

    /// Read more from the socket into the buffer. Returns false on EOF.
    func fill(deadline: Deadline) async throws -> Bool {
        while true {
            let r: IOResult? = try queue.sync {
                if rstart > 0 {
                    let n = rend - rstart
                    if n > 0 {
                        rbuf.withUnsafeMutableBytes { raw in
                            _ = memmove(raw.baseAddress!, raw.baseAddress! + rstart, n)
                        }
                    }
                    rstart = 0
                    rend = n
                }
                if rend == rbuf.count { return nil } // full; caller consumes first
                let r = try rawReadIntoBuffer()
                if case .bytes(let n) = r { rend += n }
                return r
            }
            switch r {
            case nil: return true
            case .bytes(let n): return n > 0
            case .wouldBlock: try await wait(.read, deadline: deadline)
            }
        }
    }

    /// Up to `max` bytes: buffered bytes first, otherwise one socket read.
    /// Empty only at EOF.
    func readSome(max: Int, deadline: Deadline) async throws -> Data {
        if max <= 0 { return Data() }
        while true {
            let taken: Data? = queue.sync {
                guard rend > rstart else { return nil }
                let n = min(max, rend - rstart)
                let d = Data(rbuf[rstart..<rstart + n])
                rstart += n
                return d
            }
            if let taken { return taken }
            if try await !fill(deadline: deadline) { return Data() }
        }
    }

    /// Exactly `count` bytes, or `.endOfStream`.
    func readExact(_ count: Int, deadline: Deadline) async throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            let d = try await readSome(max: count - out.count, deadline: deadline)
            if d.isEmpty { throw HostError.endOfStream }
            out.append(d)
        }
        return out
    }

    /// One line terminated by "\n" (a preceding "\r" is stripped). Lines
    /// longer than `max` (or than the buffer) fail with `.lineTooLong`. At
    /// EOF with nothing buffered, returns nil; a partial last line at EOF is
    /// returned as is.
    func readLine(max: Int, deadline: Deadline) async throws -> Data? {
        var scanned = 0
        while true {
            enum Step { case line(Data), need(before: Int) }
            let step: Step = try queue.sync {
                let avail = rbuf[rstart..<rend]
                if let i = avail.dropFirst(scanned).firstIndex(of: UInt8(ascii: "\n")) {
                    var line = avail[avail.startIndex..<i]
                    rstart = i + 1
                    if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                    if line.count > max { throw HostError.protocolViolation(.lineTooLong) }
                    return .line(Data(line))
                }
                if avail.count > max || avail.count == rbuf.count { throw HostError.protocolViolation(.lineTooLong) }
                return .need(before: avail.count)
            }
            switch step {
            case .line(let d): return d
            case .need(let before):
                if try await !fill(deadline: deadline) {
                    return queue.sync {
                        if rend == rstart { return nil }
                        let d = Data(rbuf[rstart..<rend])
                        rstart = rend
                        return d
                    }
                }
                // fill() may have compacted the buffer: rescan from where we were.
                scanned = before
            }
        }
    }

    // MARK: Writing

    /// Write all of `data`. Never raises SIGPIPE.
    func writeAll(_ data: Data, deadline: Deadline) async throws {
        var off = 0
        while off < data.count {
            let r = try queue.sync { try rawWrite(data, from: off) }
            switch r {
            case .bytes(let n): off += n
            case .wouldBlock: try await wait(.write, deadline: deadline)
            }
        }
    }
}

/// A tiny thread-safe countdown (two cancel handlers share one fd close).
private final class ManagedCounter: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    init(_ v: Int) { value = v }
    func decrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        value -= 1
        return value
    }
}
