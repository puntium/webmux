import XCTest
@testable import WebmuxConnection

final class SSHCommandTests: XCTestCase {
    let common = ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=10"]

    func testArgvKeyAuthPasswordAuthAndEachOptionalField() {
        let base = Profile(name: "n", host: "me@box")
        XCTAssertEqual(SSHCommand.commandArgv(ssh: "ssh", base, hasPassword: false, command: "uname"),
                       ["ssh", "-o", "BatchMode=yes"] + common + ["me@box", "uname"])
        XCTAssertEqual(SSHCommand.commandArgv(ssh: "ssh", base, hasPassword: true, command: "uname"),
                       ["ssh", "-o", "NumberOfPasswordPrompts=1"] + common + ["me@box", "uname"])

        var full = base
        full.sshPort = 2222
        full.identityFile = "/k/id_ed25519"
        full.extraOptions = "  -o ProxyJump=bastion\t-4 "
        XCTAssertEqual(SSHCommand.commandArgv(ssh: "ssh", full, hasPassword: false, command: "cmd"),
                       ["ssh", "-o", "BatchMode=yes"] + common + ["-p", "2222", "-i", "/k/id_ed25519", "-o", "ProxyJump=bastion", "-4", "me@box", "cmd"])
        var portOnly = base
        portOnly.sshPort = 22
        XCTAssertEqual(SSHCommand.commandArgv(ssh: "ssh", portOnly, hasPassword: false, command: "c"),
                       ["ssh", "-o", "BatchMode=yes"] + common + ["-p", "22", "me@box", "c"])
        var idOnly = base
        idOnly.identityFile = "k"
        XCTAssertEqual(SSHCommand.commandArgv(ssh: "ssh", idOnly, hasPassword: false, command: "c"),
                       ["ssh", "-o", "BatchMode=yes"] + common + ["-i", "k", "me@box", "c"])

        // the tunnel: unix-socket local end, stale-socket unlink
        XCTAssertEqual(SSHCommand.tunnelArgv(ssh: "ssh", full, hasPassword: true, localSocket: "/Users/me/Library/Application Support/x/run/box-1.sock", remoteSocket: "/run/user/9/webmux/default.http.sock"),
                       ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "NumberOfPasswordPrompts=1"] + common
                           + ["-p", "2222", "-i", "/k/id_ed25519", "-o", "ProxyJump=bastion", "-4", "-L", "/Users/me/Library/Application Support/x/run/box-1.sock:/run/user/9/webmux/default.http.sock", "me@box"])
        let argv = SSHCommand.tunnelArgv(ssh: "/x/ssh", base, hasPassword: false, localSocket: "/l.sock", remoteSocket: "/r.sock")
        XCTAssertEqual(SSHCommand.joinForLog(argv), "ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectTimeout=10 -L /l.sock:/r.sock me@box")
    }

    func testEnvironmentCarriesThePasswordOnlyWithAskpass() {
        let base = ["PATH": "/bin", "WEBMUX_SSH_PASSWORD": "inherited-must-not-leak"]
        let keyOnly = SSHCommand.childEnvironment(base: base, askpassPath: "/r/askpass.sh", password: nil)
        XCTAssertNil(keyOnly["SSH_ASKPASS"])
        XCTAssertNil(keyOnly["WEBMUX_SSH_PASSWORD"])
        XCTAssertEqual(keyOnly["PATH"], "/bin")
        let pw = SSHCommand.childEnvironment(base: base, askpassPath: "/r/askpass.sh", password: "hunter2")
        XCTAssertEqual(pw["SSH_ASKPASS"], "/r/askpass.sh")
        XCTAssertEqual(pw["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(pw["WEBMUX_SSH_PASSWORD"], "hunter2")
        XCTAssertNotNil(pw["DISPLAY"])
        XCTAssertEqual(SSHCommand.askpassScript, "#!/bin/sh\nprintf '%s' \"$WEBMUX_SSH_PASSWORD\"\n")
    }

    func testAskpassHelperIsWrittenPrivate() throws {
        let dir = "/tmp/wm-ap-\(Util.randomHex(bytes: 4))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try SSHCommand.ensureAskpass(dir: dir)
        XCTAssertEqual(path, dir + "/askpass.sh")
        XCTAssertEqual(Util.readString(path), SSHCommand.askpassScript)
        var st = stat()
        stat(path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        stat(dir, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        // the helper really answers with the env var
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.environment = ["WEBMUX_SSH_PASSWORD": "pw with spaces"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "pw with spaces")
    }

    func testResolveExecutable() {
        XCTAssertEqual(SSHCommand.resolveExecutable("/x/ssh", environment: [:]), "/x/ssh")
        XCTAssertEqual(SSHCommand.resolveExecutable("sh", environment: ["PATH": "/nonexistent:/bin"]), "/bin/sh")
        XCTAssertEqual(SSHCommand.resolveExecutable("nope-nope", environment: ["PATH": "/bin"]), "/usr/bin/nope-nope")
    }
}
