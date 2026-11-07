import XCTest
@testable import WebmuxConnection

final class LocalNetworkTests: XCTestCase {
    func testLocalAddressRanges() {
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.1.1", "fe80::1", "FE80::abcd", "fc00::1", "fd12::1", "::ffff:192.168.0.1"] {
            XCTAssertTrue(LocalNetwork.isLocalAddress(ip), ip)
        }
        for ip in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "2001:db8::1", "::1", "::ffff:8.8.8.8", "not-an-ip", ""] {
            XCTAssertFalse(LocalNetwork.isLocalAddress(ip), ip)
        }
    }

    func testSshTarget() {
        XCTAssertEqual(LocalNetwork.sshTarget(Profile(name: "n", host: "me@box.local"))?.host, "box.local")
        XCTAssertEqual(LocalNetwork.sshTarget(Profile(name: "n", host: "me@box.local"))?.port, 22)
        XCTAssertEqual(LocalNetwork.sshTarget(Profile(name: "n", host: "a@b@c", sshPort: 2222))?.host, "c")
        XCTAssertEqual(LocalNetwork.sshTarget(Profile(name: "n", host: "a@b@c", sshPort: 2222))?.port, 2222)
        XCTAssertNil(LocalNetwork.sshTarget(Profile(name: "n", host: "box", extraOptions: "-o ProxyJump=bastion")))
        XCTAssertNil(LocalNetwork.sshTarget(Profile(name: "n", host: "box", extraOptions: "-J bastion")))
        XCTAssertNil(LocalNetwork.sshTarget(Profile(name: "n", host: "box", extraOptions: "-o ProxyCommand=nc")))
        XCTAssertNotNil(LocalNetwork.sshTarget(Profile(name: "n", host: "box", extraOptions: "-4 -Jx"))) // not a bare -J
        XCTAssertNil(LocalNetwork.sshTarget(Profile(name: "n", host: "me@")))
    }

    func testGrantPendingAndLooksDenied() {
        XCTAssertTrue(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "EHOSTUNREACH"), host: "10.0.0.5"))
        XCTAssertTrue(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "ENOTFOUND"), host: "box.local"))
        XCTAssertTrue(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "EAI_AGAIN"), host: "Box.LOCAL."))
        XCTAssertFalse(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "ENOTFOUND"), host: "box.example.com"))
        XCTAssertFalse(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "ECONNREFUSED"), host: "box.local"))
        XCTAssertFalse(LocalNetwork.grantPending(LANProbeResult(ok: false, code: "ETIMEDOUT"), host: "10.0.0.5"))
        XCTAssertFalse(LocalNetwork.grantPending(LANProbeResult(ok: true), host: "10.0.0.5"))
        XCTAssertTrue(LocalNetwork.looksDenied(["ssh: connect to host box port 22: No route to host"]))
        XCTAssertTrue(LocalNetwork.looksDenied(["x", "Undefined error: 0"]))
        XCTAssertFalse(LocalNetwork.looksDenied(["Connection refused"]))
        XCTAssertTrue(LocalNetwork.hint.hasPrefix("macOS blocked local network access for webmux — allow it under System Settings › Privacy & Security › Local Network;"))
    }

    func testDarwinProberLiteralsAndLoopback() {
        let p = DarwinLocalNetworkProber()
        XCTAssertTrue(p.isLocalTarget(host: "printer.local"))
        XCTAssertTrue(p.isLocalTarget(host: "PRINTER.LOCAL."))
        XCTAssertTrue(p.isLocalTarget(host: "192.168.7.7"))
        XCTAssertFalse(p.isLocalTarget(host: "1.1.1.1"))
        XCTAssertFalse(p.isLocalTarget(host: "127.0.0.1"))
        // a loopback connect to a closed port: a verdict on the host, not the grant
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(fd) // bound but never listened, now closed: refused
        let r = p.probe(host: "127.0.0.1", port: port, timeoutMs: 1000)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.code, "ECONNREFUSED")
        XCTAssertFalse(LocalNetwork.grantPending(r, host: "127.0.0.1"))
        // and one that listens: reachable
        let srv = socket(AF_INET, SOCK_STREAM, 0)
        var a2 = sockaddr_in()
        a2.sin_family = sa_family_t(AF_INET)
        a2.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a2) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(srv, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(srv, 1)
        _ = withUnsafeMutablePointer(to: &a2) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(srv, $0, &len) } }
        let r2 = p.probe(host: "127.0.0.1", port: Int(UInt16(bigEndian: a2.sin_port)), timeoutMs: 1000)
        close(srv)
        XCTAssertTrue(r2.ok, "\(r2)")
    }
}
