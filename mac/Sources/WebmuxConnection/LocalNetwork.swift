// macOS Local Network privacy, seen from a process that spawns ssh: the
// port of electron/lan.js (PARITY X-40, X-41; kept for the Mac client).
//
// Since macOS 15 a connection to a host on the LAN — RFC 1918 / link-local
// addresses, `.local` names — is gated behind a per-app grant in System
// Settings › Privacy & Security › Local Network. A denied connect fails
// instantly with EHOSTUNREACH, which ssh prints as "No route to host":
// indistinguishable from a real routing failure except by timing.
//
//   probe()        — the app opens (and immediately closes) a TCP connection
//                    to the target from its own process before spawning ssh,
//                    so the prompt lands on the process that owns the ssh
//                    children (the app needs NSLocalNetworkUsageDescription).
//   looksDenied()  — when ssh still reports "No route to host", say what it
//                    almost certainly means and where the toggle is.
import Foundation

public struct LANProbeResult: Sendable, Equatable {
    public var ok: Bool
    /// the socket error name ('EHOSTUNREACH' is the denial signature), or
    /// 'ETIMEDOUT' / a getaddrinfo code ('ENOTFOUND', 'EAI_AGAIN', …)
    public var code: String?
    public var ms: Int64
    public init(ok: Bool, code: String? = nil, ms: Int64 = 0) {
        self.ok = ok
        self.code = code
        self.ms = ms
    }
}

/// The two network calls the supervisor makes, injectable for tests.
public protocol LocalNetworkProber: Sendable {
    /// Whether a connection to `host` would be subject to the Local Network
    /// grant. May resolve the name (blocking); called on a supervisor thread.
    func isLocalTarget(host: String) -> Bool
    /// One TCP connect to host:port from this process, torn down as soon as
    /// it resolves either way. Never throws.
    func probe(host: String, port: Int, timeoutMs: Int) -> LANProbeResult
}

public enum LocalNetwork {
    public static let hint = "macOS blocked local network access for webmux — allow it under "
        + "System Settings › Privacy & Security › Local Network; webmux reconnects by itself once it is allowed. "
        + "If it is already allowed, toggle it off and on (or launch webmux from Terminal once)."

    /// The direct ssh hop for a profile: (host, port), or nil when ssh won't
    /// connect to the profile's host itself (a ProxyJump goes via the jump
    /// host, and macOS attributes that connection to the jump, not to us).
    public static func sshTarget(_ p: Profile) -> (host: String, port: Int)? {
        let extra = p.extraOptions
        if extra.contains("ProxyJump=") || extra.contains("ProxyCommand=") { return nil }
        if extra.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).contains("-J") { return nil }
        var host = Util.trim(p.host)
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.isEmpty { return nil }
        return (host, p.sshPort != 0 ? p.sshPort : 22)
    }

    /// 4 or 6 for an IP literal, else nil (net.isIP).
    public static func ipVersion(_ s: String) -> Int? {
        var a4 = in_addr()
        if inet_pton(AF_INET, s, &a4) == 1 { return 4 }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, s, &a6) == 1 { return 6 }
        return nil
    }

    /// IPv4/IPv6 literal in a range macOS treats as "local network".
    public static func isLocalAddress(_ ip: String) -> Bool {
        switch ipVersion(ip) {
        case 4:
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            let (a, b) = (parts[0], parts[1])
            return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254)
        case 6:
            let lower = ip.lowercased()
            if lower.hasPrefix("::ffff:") { return isLocalAddress(String(lower.dropFirst(7))) }
            let first = Int(lower.split(separator: ":", omittingEmptySubsequences: false).first ?? "0", radix: 16) ?? 0
            return (first & 0xffc0) == 0xfe80 || (first & 0xfe00) == 0xfc00 // fe80::/10 link-local, fc00::/7 unique-local
        default:
            return false
        }
    }

    /// A probe outcome that means "the grant isn't there (yet)": the denial
    /// itself, or — for a `.local` name — a failed lookup, since mDNS
    /// resolution is gated by the same permission and fails first while the
    /// prompt is up. Anything else (connected, refused, timed out, a
    /// non-.local resolve failure) is a verdict on the host, not the grant.
    public static func grantPending(_ r: LANProbeResult, host: String) -> Bool {
        if r.ok { return false }
        if r.code == "EHOSTUNREACH" { return true }
        let h = host.lowercased()
        let isLocalName = h.hasSuffix(".local") || h.hasSuffix(".local.")
        return isLocalName && ["ENOTFOUND", "EAI_AGAIN", "EAI_NONAME", "EAI_NODATA"].contains(r.code ?? "")
    }

    /// ssh stderr that reads like a Local Network denial. "Undefined error:
    /// 0" is what some tools print for the same condition.
    public static func looksDenied(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("No route to host") || $0.contains("Undefined error: 0") }
    }
}

/// The real prober: getaddrinfo + a non-blocking connect.
public struct DarwinLocalNetworkProber: LocalNetworkProber {
    public init() {}

    public func isLocalTarget(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasSuffix(".local") { return true }
        if LocalNetwork.ipVersion(h) != nil { return LocalNetwork.isLocalAddress(h) }
        guard let addrs = DarwinLocalNetworkProber.resolve(h, port: 0).addrs else { return false }
        return addrs.contains { LocalNetwork.isLocalAddress($0.ip) }
    }

    struct Resolved {
        var ip: String
        var storage: sockaddr_storage
        var len: socklen_t
    }

    /// All addresses of `host` (numeric text and sockaddr), or the
    /// getaddrinfo error as a Node-style code.
    static func resolve(_ host: String, port: Int) -> (addrs: [Resolved]?, code: String?) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        if rc != 0 {
            let code: String
            switch rc {
            case EAI_NONAME: code = "ENOTFOUND"
            case EAI_AGAIN: code = "EAI_AGAIN"
            case EAI_NODATA: code = "EAI_NODATA"
            default: code = "EAI_FAIL"
            }
            return (nil, code)
        }
        defer { freeaddrinfo(res) }
        var out: [Resolved] = []
        var p = res
        while let ai = p {
            var storage = sockaddr_storage()
            memcpy(&storage, ai.pointee.ai_addr, Int(ai.pointee.ai_addrlen))
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var ip = ""
            if ai.pointee.ai_family == AF_INET {
                var a = sockaddr_in()
                memcpy(&a, ai.pointee.ai_addr, MemoryLayout<sockaddr_in>.size)
                inet_ntop(AF_INET, &a.sin_addr, &buf, socklen_t(buf.count))
                ip = String(cString: buf)
            } else if ai.pointee.ai_family == AF_INET6 {
                var a = sockaddr_in6()
                memcpy(&a, ai.pointee.ai_addr, MemoryLayout<sockaddr_in6>.size)
                inet_ntop(AF_INET6, &a.sin6_addr, &buf, socklen_t(buf.count))
                ip = String(cString: buf)
            }
            out.append(Resolved(ip: ip, storage: storage, len: ai.pointee.ai_addrlen))
            p = ai.pointee.ai_next
        }
        return (out, nil)
    }

    public func probe(host: String, port: Int, timeoutMs: Int) -> LANProbeResult {
        let started = Util.monoMs()
        let (addrs, code) = DarwinLocalNetworkProber.resolve(host, port: port)
        guard let first = addrs?.first else {
            return LANProbeResult(ok: false, code: code ?? "ENOTFOUND", ms: Util.monoMs() - started)
        }
        let family = Int32(first.storage.ss_family)
        let fd = socket(family, SOCK_STREAM, 0)
        if fd < 0 { return LANProbeResult(ok: false, code: errnoName(errno), ms: Util.monoMs() - started) }
        defer { close(fd) }
        Util.setNonblock(fd)
        var storage = first.storage
        let rc = withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, first.len) }
        }
        if rc == 0 { return LANProbeResult(ok: true, ms: Util.monoMs() - started) }
        if errno != EINPROGRESS { return LANProbeResult(ok: false, code: errnoName(errno), ms: Util.monoMs() - started) }
        var fds = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
        let n = poll(&fds, 1, Int32(timeoutMs))
        if n == 0 { return LANProbeResult(ok: false, code: "ETIMEDOUT", ms: Util.monoMs() - started) }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if err == 0 { return LANProbeResult(ok: true, ms: Util.monoMs() - started) }
        return LANProbeResult(ok: false, code: errnoName(err), ms: Util.monoMs() - started)
    }

    func errnoName(_ e: Int32) -> String {
        switch e {
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ECONNREFUSED: return "ECONNREFUSED"
        case ETIMEDOUT: return "ETIMEDOUT"
        case ENETUNREACH: return "ENETUNREACH"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case ECONNRESET: return "ECONNRESET"
        default: return "E\(e)"
        }
    }
}
