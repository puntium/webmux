// The liveness probe through the tunnel (main.js probeLoop's `GET /`). The
// app may satisfy `HostProber` with its WebmuxHost client; the default here
// speaks just enough HTTP/1.0 over the unix socket to see a status line, so
// the package tests run without WebmuxHost.
import Foundation

public protocol HostProber: Sendable {
    /// `GET /` on the local unix socket: nil if the server answered (any HTTP
    /// status) within `timeoutMs`, else a short static reason (an error
    /// name) for the `probe missed` log line. Called on the supervisor
    /// thread; may block up to the timeout.
    func probe(socketPath: String, timeoutMs: Int) -> String?
}

/// A closure prober (tests, or the app wrapping WebmuxHost).
public struct ClosureHostProber: HostProber {
    public let fn: @Sendable (String, Int) -> String?
    public init(_ fn: @escaping @Sendable (String, Int) -> String?) { self.fn = fn }
    public func probe(socketPath: String, timeoutMs: Int) -> String? { fn(socketPath, timeoutMs) }
}

/// Minimal `GET / HTTP/1.0` over the unix socket with Darwin sockets.
public struct SocketHostProber: HostProber {
    public init() {}

    public func probe(socketPath: String, timeoutMs: Int) -> String? {
        let deadline = Util.monoMs() + Int64(timeoutMs)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return "SocketFailed" }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Util.setNonblock(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        if bytes.count >= cap { return "PathTooLong" }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            if errno != EINPROGRESS { return errnoReason(errno) }
            var fds = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
            if poll(&fds, 1, Int32(max(0, deadline - Util.monoMs()))) <= 0 { return "Timeout" }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { return errnoReason(err) }
        }
        let req = Array("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)
        var off = 0
        while off < req.count {
            let n = req.withUnsafeBufferPointer { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    var fds = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                    if poll(&fds, 1, Int32(max(0, deadline - Util.monoMs()))) <= 0 { return "Timeout" }
                    continue
                }
                return errnoReason(errno)
            }
            off += n
        }
        var buf = [UInt8](repeating: 0, count: 16)
        var got = 0
        while got < 5 {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 1, Int32(max(0, deadline - Util.monoMs()))) <= 0 { return "Timeout" }
            let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress! + got, $0.count - got) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return errnoReason(errno)
            }
            if n == 0 { return "BadResponse" }
            got += n
        }
        return Array(buf[0..<5]) == Array("HTTP/".utf8) ? nil : "BadResponse"
    }

    private func errnoReason(_ e: Int32) -> String {
        switch e {
        case ECONNREFUSED: return "ConnectionRefused"
        case ENOENT: return "SocketMissing"
        case ETIMEDOUT: return "Timeout"
        case ECONNRESET: return "ConnectionReset"
        case EPIPE: return "BrokenPipe"
        default: return String(cString: strerror(e)).replacingOccurrences(of: " ", with: "")
        }
    }
}
