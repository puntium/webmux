// Engine tests through the fake ssh (the port of conn/test.zig's engine,
// deploy, supervisor and restart tests), plus the Mac-only pieces: the
// Local Network flow, the Electron import and the default socket prober.
import XCTest
@testable import WebmuxConnection

final class EngineTests: XCTestCase {
    var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture()
    }

    override func tearDown() {
        f.cleanup()
        f = nil
    }

    func testConfigRoundTripSettingsLastProfilePayloadLookup() throws {
        var e = try f.start()
        XCTAssertEqual(e.payloadDir, f.path("payload"))
        f.addProfile("box", "me@box", "")
        XCTAssertEqual(e.saveProfile(ProfileInput(name: "box", host: "x")), "a profile named \"box\" already exists")
        let s = e.updateSettings(Settings.Patch(theme: "light", minCols: 120))
        XCTAssertEqual(s.theme, "light")
        XCTAssertEqual(f.settingsEvents, 1)
        XCTAssertNotNil(e.connect("nope"))
        f.stop()
        // reload from disk
        e = try f.start()
        let list = e.listProfiles()
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.profiles[0].host, "me@box")
        XCTAssertTrue(list.file.hasSuffix("/app/config.json"))
        XCTAssertEqual(e.settings.minCols, 120)
        XCTAssertEqual(e.settings.theme, "light")
        XCTAssertTrue(f.read("app/config.json").contains("\"lastProfile\": null"))
        // the log file exists under Application Support
        XCTAssertTrue(f.exists("app/logs/webmux.log"))
        // askpass helper in the run dir, which is private
        XCTAssertEqual(f.read("app/run/askpass.sh"), SSHCommand.askpassScript)
        var st = stat()
        stat(f.path("app/run"), &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        f.expectLog("client started version=test platform=darwin-")
        f.expectLog("passwordStore=memory")
    }

    func testDeployFreshPushReuseReplaceAndFailures() throws {
        let h1 = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "inst1")

        // 1. fresh host: probe + push + start, then tunnel and connected
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        do {
            let st = e.status("box")!
            XCTAssertTrue(st.socketPath!.hasSuffix(".sock"))
            XCTAssertTrue(st.socketPath!.hasPrefix(f.root))
            XCTAssertEqual(st.remoteSocket, "/remote/inst1.http.sock")
            XCTAssertEqual(st.msg, "")
            XCTAssertTrue(st.hadConnection)
            XCTAssertEqual(st.step, .tunnel)
            XCTAssertNotNil(st.tunnelPID)
        }
        let remoteDir = "remote/.webmux/dist/payload/\(h1)"
        XCTAssertTrue(f.exists("\(remoteDir)/webmux-host"))
        XCTAssertTrue(f.exists("\(remoteDir)/shims/xdg-open"))
        XCTAssertEqual(f.read("remote/fake-host.log"), "\(f.root)/remote/.webmux/dist/payload/\(h1)/webmux-host start --name inst1 cwd=\(f.root)/remote\n") // exact start command line
        var sl = f.sshLog()
        XCTAssertEqual(sl.components(separatedBy: "ARGV ").count - 1, 4) // probe + push + start + tunnel
        XCTAssertTrue(sl.contains("-N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o BatchMode=yes"))
        XCTAssertFalse(sl.contains("PWENV"))
        XCTAssertTrue(f.read("remote/last-forward").trimmingCharacters(in: .newlines).hasSuffix(".sock:/remote/inst1.http.sock"))
        f.expectLog("[box] connect requested host=me@box instance=inst1 socket=")
        f.expectLog("auth=key")
        f.expectLog("[box] deploy: probing host…")
        f.expectLog("[box] deploy: pushing webmux… ")
        f.expectLog("[box] deploy: starting server…")
        f.expectLog("[box] deploy done: server started ms=")
        f.expectLog("[box] tunnel spawned pid=")
        f.expectLog("[box] probe: server answered through the tunnel afterMs=")
        f.expectLog("[box] state connecting → connected")
        XCTAssertEqual(f.logCount("deploy: pushing"), 1) // one line despite many progress updates

        // 2. reconnect: the hash is present → probe + start only, server reused
        f.removeFile("ssh.log")
        XCTAssertNil(e.reconnect("box"))
        f.waitLog("deploy done: server reuse", 8000)
        f.waitLog("probe: server answered through the tunnel", 8000, count: 2)
        f.waitState("box", .connected, 8000)
        sl = f.sshLog()
        XCTAssertEqual(sl.components(separatedBy: "ARGV ").count - 1, 3) // probe + start + tunnel
        f.expectLog("[box] tunnel killed (reconnect)")
        f.expectLog("[box] tunnel exited (superseded)")
        f.expectLog("[box] reconnect requested")

        // 3. a new client build: push v2, the old server is replaced
        let h2 = try f.buildPayload("v2")
        XCTAssertNotEqual(h1, h2)
        f.removeFile("ssh.log")
        XCTAssertNil(e.reconnect("box"))
        f.waitLog("deploy done: server started ms=", 8000, count: 2)
        f.waitLog("probe: server answered through the tunnel", 8000, count: 3)
        f.waitState("box", .connected, 8000)
        XCTAssertEqual(f.sshLog().components(separatedBy: "ARGV ").count - 1, 4)
        let hl = f.read("remote/fake-host.log")
        XCTAssertTrue(hl.contains("replacing {\"payloadHash\":\""))
        XCTAssertTrue(hl.contains(h1))
        XCTAssertTrue(hl.contains("payload/\(h2)/webmux-host start --name inst1"))

        // 4. starter failure: error and logTail surface; never connected → failed
        e.disconnect("box")
        f.waitFor(5000) { self.f.removedCount == 1 }
        try f.writeFile("remote/fail-start", "")
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .failed, 8000)
        do {
            let st = e.status("box")!
            XCTAssertEqual(st.msg, "connection failed")
            XCTAssertTrue(st.stderr.contains("tail one\ntail two\nserver start failed: boom"), st.stderr)
            XCTAssertNil(st.socketPath)
        }
        f.expectLog("[box] deploy failed ms=")
        f.expectLog("error=\"server start failed: boom\"")
        f.expectLog("[box] state connecting → failed msg=\"connection failed\"")
        f.removeFile("remote/fail-start")

        // 5. a platform this build has no payload for → clear error, only the probe ran
        try f.writeFile("payload/payload.json", "{\"platforms\":{\"linux-arm64\":{\"hash\":\"bad\"}}}")
        f.removeFile("ssh.log")
        XCTAssertNil(e.reconnect("box"))
        f.waitLog("this client build has no linux-", 8000)
        f.waitState("box", .failed, 8000)
        XCTAssertEqual(f.sshLog().components(separatedBy: "ARGV ").count - 1, 1)
    }

    func testConnectThatNeverSucceedsParksAsFailedWithStderrNoRetry() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("typo", "badhost", "")
        XCTAssertNil(e.connect("typo"))
        f.waitState("typo", .failed, 5000)
        let st = e.status("typo")!
        XCTAssertEqual(st.msg, "connection failed")
        XCTAssertTrue(st.stderr.contains("ssh: Could not resolve hostname badhost: Name or service not known"))
        XCTAssertTrue(st.stderr.contains("ssh exited (255)"))
        XCTAssertFalse(st.hadConnection)
        XCTAssertEqual(st.step, .idle)
        // nothing churns in the background
        let probes = f.probeCount
        sleepMs(800)
        XCTAssertEqual(f.stateOf("typo"), .failed)
        XCTAssertFalse(f.sawState(.retry))
        XCTAssertEqual(probes, f.probeCount)
        f.expectLog("[typo] ssh: ssh: Could not resolve hostname badhost")
        // disconnect from failed
        e.disconnect("typo")
        f.waitFor(3000) { self.f.removedCount == 1 }
        f.expectLog("[typo] disconnecting (user) state=failed")
        XCTAssertNil(e.status("typo"))
        XCTAssertEqual(e.snapshot().count, 0)
    }

    func testInterruptedConnectionRetriesWithBackoffAndRecovers() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "")
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)

        // the link drops and ssh can't get back in for a while
        try f.writeFile("remote/ssh-down", "")
        try f.writeFile("remote/drop-tunnel", "")
        f.waitState("box", .retry, 5000)
        do {
            let st = e.status("box")!
            XCTAssertEqual(st.msg, "ssh exited (255)")
            XCTAssertEqual(st.step, .waitingRetry)
            XCTAssertGreaterThan(st.retryDeadlineMs, 0)
            XCTAssertLessThanOrEqual(st.retryRemainingMs(now: e.nowMs()), 1200)
            XCTAssertTrue(st.stderr.contains("client_loop: send disconnect: Broken pipe"))
        }
        f.waitLog("[box] tunnel exited pid=", 3000)
        f.waitLog("[box] interrupted — retry in 0.3s exitCode=255", 3000)
        // retries fail (ssh-down) and the delay doubles: 0.3 → 0.6 → 1.2 (cap)
        f.waitLog("[box] interrupted — retry in 0.6s", 5000)
        f.waitLog("[box] interrupted — retry in 1.2s", 5000)
        f.expectLog("[box] retrying")
        f.expectLog("[box] deploy failed")
        XCTAssertFalse(f.sawState(.failed)) // an established cycle never parks
        // the host comes back: the next retry heals it
        f.removeFile("remote/ssh-down")
        f.waitState("box", .connected, 8000)
        f.expectLog("[box] state retry → connecting")
    }

    func testProbeMissesKillTheTunnelAndAFreshTunnelThatNeverAnswersIsKilledToo() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "")
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)

        // the remote server dies; ssh -N stays up
        try f.writeFile("remote/server-dead", "")
        f.waitLog("[box] probe missed (1/3) error=ConnectionRefused", 3000)
        f.waitLog("[box] probe missed (3/3)", 3000)
        f.waitLog("[box] probe: server unreachable through the tunnel — reconnecting misses=3", 3000)
        f.waitState("box", .retry, 3000)
        do {
            let st = e.status("box")!
            XCTAssertEqual(st.msg, "ssh exited (SIGTERM)")
            XCTAssertTrue(st.stderr.contains("server unreachable through the tunnel — reconnecting"))
        }
        // killed link → retry at once (delay reset to 0, then the 0.3 minimum)
        f.waitLog("[box] interrupted — retry in 0.3s exitCode=SIGTERM", 3000)
        // the retry deploys and tunnels, but the server never answers → first-answer deadline
        f.waitLog("[box] probe: server did not answer through the tunnel", 6000)
        XCTAssertFalse(f.sawState(.failed))
        f.removeFile("remote/server-dead")
        f.waitState("box", .connected, 8000)
        f.expectLog("[box] state retry → connecting")
    }

    func testNotifyResumeKillsLiveTunnelsAndTheCycleReconnects() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "")
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        f.clearStates()
        e.notifyResume()
        f.waitLog("system resumed from sleep tunnelsKilled=1", 2000)
        f.waitLog("[box] killing pre-sleep tunnel to reconnect now pid=", 2000)
        f.waitLog("[box] interrupted — retry in 0.3s", 3000)
        f.waitState("box", .connected, 8000)
        XCTAssertTrue(f.sawState(.retry))
    }

    func testDisconnectDuringDeployConnectedRetryAndFailed() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "")

        // during a (slow) deploy step
        try f.writeFile("remote/slow", "")
        XCTAssertNil(e.connect("box"))
        f.waitLog("[box] deploy step: ssh pid=", 3000)
        sleepMs(100)
        let t0 = Util.monoMs()
        e.disconnect("box")
        XCTAssertNil(e.status("box")) // gone from the snapshot at once
        f.waitFor(4000) { self.f.removedCount >= 1 }
        XCTAssertLessThan(Util.monoMs() - t0, 3000) // did not wait out the 30 s step
        f.expectLog("[box] disconnecting (user) state=connecting")
        f.expectLog("[box] deploy step killed (user) pid=")
        f.removeFile("remote/slow")

        // while connected
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        e.disconnect("box")
        f.waitFor(4000) { self.f.removedCount >= 2 }
        f.expectLog("[box] disconnecting (user) state=connected")
        f.expectLog("[box] tunnel killed (user) pid=")
        // the tunnel's local socket is cleaned up
        XCTAssertFalse(f.exists("app/run/\(Profile.hostSlug(host: "me@box", instance: "")).sock"))

        // while waiting to retry
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        try f.writeFile("remote/ssh-down", "")
        try f.writeFile("remote/drop-tunnel", "")
        f.waitState("box", .retry, 5000)
        e.disconnect("box")
        f.waitFor(4000) { self.f.removedCount >= 3 }
        f.expectLog("[box] disconnecting (user) state=retry")
        f.waitLog("[box] pending retry cancelled (user)", 2000)
        f.removeFile("remote/ssh-down")

        // while parked as failed
        try f.writeFile("remote/ssh-down", "")
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .failed, 5000)
        e.disconnect("box")
        f.waitFor(4000) { self.f.removedCount >= 4 }
        f.removeFile("remote/ssh-down")

        // deleting a connected profile disconnects it
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        XCTAssertNil(e.deleteProfile("box"))
        f.waitFor(4000) { self.f.removedCount >= 5 }
        f.expectLog("[box] disconnecting (profile deleted) state=connected")
        XCTAssertNil(e.profile(named: "box"))

        // quitting with a live connection tears it down and logs it
        f.addProfile("q", "me@box", "")
        XCTAssertNil(e.connect("q"))
        f.waitState("q", .connected, 8000)
        let logFile = e.log.filePath!
        f.stop()
        let file = Util.readString(logFile)!
        XCTAssertTrue(file.contains("client quitting connections=1"))
        XCTAssertTrue(file.contains("[q] tunnel killed (quit)"))
    }

    func testPasswordAuthViaAskpassNeverInArgvOrTheLog() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("pw", "me@pwbox", "")
        let id = e.profile(named: "pw")!.id
        try f.passwords.set(profileID: id, label: "webmux: pw", password: "s3cr3t-pw")
        XCTAssertNil(e.connect("pw"))
        f.waitState("pw", .connected, 8000)
        f.expectLog("auth=password")
        var sl = f.sshLog()
        XCTAssertTrue(sl.contains("-o NumberOfPasswordPrompts=1"))
        XCTAssertFalse(sl.contains("BatchMode"))
        XCTAssertTrue(sl.contains("PWENV set"))
        XCTAssertFalse(sl.contains("s3cr3t"))
        // wrong password: one attempt, fails fast into failed with ssh's verdict
        try f.passwords.set(profileID: id, label: "webmux: pw", password: "wrong-one")
        XCTAssertNil(e.reconnect("pw"))
        f.waitState("pw", .failed, 5000)
        do {
            let st = e.status("pw")!
            XCTAssertTrue(st.stderr.contains("Permission denied (publickey,password)."))
            XCTAssertFalse(st.stderr.contains("wrong-one"))
        }
        // keychain refuses: park with main.js's message, no ssh spawned
        f.passwords.unavailable = "keychain locked"
        f.removeFile("ssh.log")
        XCTAssertNil(e.reconnect("pw"))
        f.waitLog("[pw] saved password could not be decrypted error=\"keychain locked\"", 3000)
        f.waitState("pw", .failed, 3000)
        // a stored password is password auth even when it cannot be read (C-7)
        f.waitLog("[pw] reconnect requested host=me@pwbox", 3000)
        let last = f.logText().split(separator: "\n").last { $0.contains("[pw] reconnect requested") }!
        XCTAssertTrue(last.contains("auth=password"))
        XCTAssertEqual(e.status("pw")!.msg, "saved password could not be decrypted — edit the profile and re-enter it")
        XCTAssertFalse(f.exists("ssh.log"))
        // a password cleared mid-attempt never reaches the tunnel
        f.passwords.unavailable = nil
        try f.passwords.set(profileID: id, label: "webmux: pw", password: "s3cr3t-pw")
        try f.writeFile("remote/slow", "")
        XCTAssertNil(e.reconnect("pw"))
        f.waitLog("[pw] deploy step: ssh pid=", 3000, count: 1)
        try f.passwords.delete(profileID: id)
        f.removeFile("remote/slow")
        // (the slow step is already sleeping; cancel it by reconnecting)
        XCTAssertNil(e.reconnect("pw"))
        f.waitLog("[pw] reconnect requested host=me@pwbox", 5000, count: 3)
        f.waitState("pw", .connected, 8000)
        sl = f.sshLog()
        XCTAssertTrue(sl.contains("BatchMode=yes"))
        // the password never reached the log ring or the log file
        let t = f.logText()
        XCTAssertFalse(t.contains("s3cr3t"))
        XCTAssertFalse(t.contains("wrong-one"))
        let logFile = e.log.filePath!
        f.stop()
        let file = Util.readString(logFile)!
        XCTAssertFalse(file.contains("s3cr3t"))
        XCTAssertFalse(file.contains("wrong-one"))
        XCTAssertTrue(file.contains("client quitting connections=1"))
    }

    func testRenameFollowsALiveConnectionAndCollisionsAreRefused() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("a", "me@box", "")
        f.addProfile("b", "me@box", "default") // same host+instance as "a"
        f.addProfile("c", "me@box", "other")
        XCTAssertNil(e.connect("a"))
        f.waitState("a", .connected, 8000)
        XCTAssertEqual(e.connect("b"), "\"a\" is already connected to this host and instance")
        XCTAssertNil(e.connect("c"))
        f.waitState("c", .connected, 8000)
        // connect on a connected profile is a no-op
        XCTAssertNil(e.connect("a"))
        // rename keeps the connection and its position
        XCTAssertNil(e.saveProfile(ProfileInput(name: "a2", host: "me@box"), originalName: "a"))
        XCTAssertEqual(f.stateOf("a2"), .connected)
        XCTAssertNil(f.stateOf("a"))
        e.reorder(["c", "zzz"])
        let snap = e.snapshot()
        XCTAssertEqual(snap.map { $0.name }, ["c", "a2"])
        XCTAssertEqual(e.lastProfile, "c")
    }

    func testALiveConnectionKeepsWhatItHolds() throws {
        _ = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("a", "me@box", "")
        f.addProfile("b", "me@box", "")
        XCTAssertNil(e.connect("a"))
        f.waitState("a", .connected, 8000)
        // edit a's host while connected: the tunnel (and its socket) stay
        XCTAssertNil(e.saveProfile(ProfileInput(name: "a", host: "me@other"), originalName: "a"))
        XCTAssertEqual(e.status("a")!.host, "me@box")
        // so b, on a's old host, is still refused
        XCTAssertEqual(e.connect("b"), "\"a\" is already connected to this host and instance")
        // an interruption retries what a holds, not the edit
        try f.writeFile("remote/drop-tunnel", "")
        f.waitState("a", .retry, 3000)
        f.waitState("a", .connected, 8000)
        XCTAssertEqual(e.status("a")!.host, "me@box")
        XCTAssertEqual(e.connect("b"), "\"a\" is already connected to this host and instance")
        // reconnect adopts the edit and releases the old host
        XCTAssertNil(e.reconnect("a"))
        f.waitLog("[a] reconnect requested host=me@other", 3000)
        f.waitState("a", .connected, 8000)
        XCTAssertNil(e.connect("b"))
        f.waitState("b", .connected, 8000)
        XCTAssertNotEqual(e.status("a")!.socketPath, e.status("b")!.socketPath)
        // and a reconnect onto a host another connection holds is refused
        XCTAssertNil(e.saveProfile(ProfileInput(name: "a", host: "me@box"), originalName: "a"))
        XCTAssertEqual(e.reconnect("a"), "\"b\" is already connected to this host and instance")
        // a failed connection holds nothing
        e.disconnect("b")
        XCTAssertNil(e.saveProfile(ProfileInput(name: "b", host: "badhost"), originalName: "b"))
        XCTAssertNil(e.connect("b"))
        f.waitState("b", .failed, 5000)
        XCTAssertNil(e.saveProfile(ProfileInput(name: "b", host: "me@third"), originalName: "b"))
        XCTAssertNil(e.saveProfile(ProfileInput(name: "c", host: "badhost")))
        XCTAssertNil(e.connect("c"))
    }

    func testBrokenConfigIsKeptAsideLoggedNeverOverwritten() throws {
        try f.writeFile("app/config.json", "{\"profiles\":[{\"name\":\"keepme\",\"host\":\"h\"}],,,\n")
        let e = try f.start()
        XCTAssertNotNil(e.configProblem)
        XCTAssertTrue(e.configProblem!.contains("config.json.broken-"), e.configProblem!)
        f.expectLog("config.json unreadable error=\"not valid JSON\"")
        f.addProfile("n1", "h", "")
        // the original text survives next to the new file
        let names = try FileManager.default.contentsOfDirectory(atPath: f.path("app"))
        let aside = names.first { $0.hasPrefix("config.json.broken-") }!
        XCTAssertTrue(f.read("app/\(aside)").contains("keepme"))
        XCTAssertTrue(f.read("app/config.json").contains("n1"))
        // ids in the kept original count as referenced
        XCTAssertEqual(e.referencedIDs().count, 1)
    }

    func testRepairedConfigIsReportedKeptAndIDsReissued() throws {
        let orig = """
        {"profiles":[{"name":"one","host":"hostO","id":"0123456789abcdef"},
         {"name":"two","host":"hostT","id":"0123456789ABCDEF"},
         {"name":"three","host":42,"id":"zz"}, {"name":"one","host":"x"}, 7],
         "lastProfile":5,"settings":{"theme":3,"unfocusedFade":"x"}}
        """
        try f.writeFile("app/config.json", orig)
        let e = try f.start()
        let prob = e.configProblem!
        XCTAssertTrue(prob.contains("\"one\", \"two\" had the same id"), prob)
        XCTAssertTrue(prob.contains("before-repair-"), prob)
        f.expectLog("config.json repaired repair=\"\\\"three\\\": \\\"host\\\" is not text: cleared\"")
        XCTAssertEqual(e.droppedPasswordIDs.count, 2)
        f.expectLog("\\\"one (2)\\\" has no id: given one")
        // ids in the kept original still count as referenced (restoring it must find its passwords)
        XCTAssertTrue(e.referencedIDs().contains("0123456789ABCDEF"))
        let list = e.profiles
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[3].name, "one (2)")
        // nothing was written back yet; the original text is kept aside
        XCTAssertEqual(f.read("app/config.json"), orig)
        XCTAssertNil(e.saveProfile(ProfileInput(name: "n", host: "h", id: list[0].id)))
        XCTAssertNotEqual(e.profile(named: "n")!.id, list[0].id)
        XCTAssertFalse(f.read("app/config.json").contains("0123456789abcdef"))
    }

    func testOutOfRangePortRefusedAndTooLongRootParksWithAReason() throws {
        _ = try f.buildPayload("v1")
        try f.writeFile("app/config.json", "{\"profiles\":[{\"name\":\"p\",\"host\":\"me@box\",\"sshPort\":99999}]}\n")
        let e = try f.start()
        XCTAssertTrue(e.configProblem!.contains("is not a port"))
        XCTAssertEqual(e.saveProfile(ProfileInput(name: "x", host: "h", sshPort: 70000)), Profile.portError)
        f.stop()
        // an Application Support path long enough that no socket path fits
        let long = f.path("app/" + String(repeating: "d", count: 100))
        try Util.makePath(long, mode: 0o700)
        var o = EngineOptions(paths: Paths(root: long, payloadDir: f.path("payload")), environment: f.env)
        o.sshExecutable = f.path("bin/ssh")
        o.localNetwork = nil
        o.timing = Fixture.timing()
        let e2 = try ConnectionEngine(options: o)
        defer { e2.shutdown() }
        XCTAssertNil(e2.saveProfile(ProfileInput(name: "q", host: "me@box")))
        XCTAssertNil(e2.connect("q"))
        let deadline = Util.monoMs() + 3000
        while Util.monoMs() < deadline && e2.status("q")?.state != .failed { sleepMs(20) }
        let st = e2.status("q")!
        XCTAssertEqual(st.state, .failed)
        XCTAssertEqual(st.msg, "the run directory is too long for a socket path")
        XCTAssertTrue(st.stderr.contains("limited to 103 bytes"))
    }

    func testRestartSessionsRestartedNothingRunningNeverDeployed() throws {
        let h = try f.buildPayload("v1")
        let e = try f.start()
        f.addProfile("box", "me@box", "wmtest.inst")
        // never deployed
        XCTAssertNil(e.restartSessions("box"))
        f.waitFor(5000) { self.f.restarts.count >= 1 }
        XCTAssertFalse(f.restarts[0].ok)
        XCTAssertEqual(f.restarts[0].msg, "webmux has never been deployed to this host")
        XCTAssertEqual(f.restarts[0].name, "box")
        f.expectLog("[box] restart sessions requested instance=wmtest.inst")
        f.expectLog("ERROR [box] restart sessions: webmux has never been deployed to this host")

        // deployed and a pty host running → restarted, via the shipped payload's CLI
        XCTAssertNil(e.connect("box"))
        f.waitState("box", .connected, 8000)
        try f.writeFile("remote/ptyhost-running", "")
        XCTAssertNil(e.restartSessions("box"))
        f.waitFor(5000) { self.f.restarts.count >= 2 }
        XCTAssertTrue(f.restarts[1].ok)
        XCTAssertEqual(f.restarts[1].msg, "sessions restarted — all shells were stopped, fresh ones start on demand")
        XCTAssertTrue(f.read("remote/fake-host.log").contains("payload/\(h)/webmux-host ptyhost --name wmtest.inst shutdown"))
        // nothing running now
        XCTAssertNil(e.restartSessions("box"))
        f.waitFor(5000) { self.f.restarts.count >= 3 }
        XCTAssertTrue(f.restarts[2].ok)
        XCTAssertEqual(f.restarts[2].msg, "no sessions were running — nothing to restart")
        // unknown profile is refused up front
        XCTAssertEqual(e.restartSessions("nope"), "no such profile")
        // the connection is untouched
        XCTAssertEqual(f.stateOf("box"), .connected)
    }

    // -- Mac-only: Local Network (X-40, X-41) -------------------------------------

    func testLocalNetworkProbeWaitsForTheGrantThenConnects() throws {
        _ = try f.buildPayload("v1")
        let lan = FakeLAN()
        lan.result = LANProbeResult(ok: false, code: "EHOSTUNREACH", ms: 1)
        f.lan = lan
        let e = try f.start()
        f.addProfile("lan", "me@192.168.1.9", "")
        XCTAssertNil(e.connect("lan"))
        f.waitLog("[lan] local network probe: EHOSTUNREACH in 1ms — waiting for the macOS Local Network grant host=192.168.1.9 port=22", 3000)
        do {
            let st = e.status("lan")!
            XCTAssertEqual(st.state, .connecting)
            XCTAssertEqual(st.step, .checkingLocalNetwork)
            XCTAssertEqual(st.msg, "waiting for macOS Local Network permission — allow webmux in the prompt…")
        }
        XCTAssertFalse(f.logHas("deploy: probing host…")) // ssh waits for the grant
        // the user clicks Allow
        lan.result = LANProbeResult(ok: true, ms: 2)
        f.waitLog("[lan] local network probe: reachable host=192.168.1.9 port=22 ms=2", 3000)
        f.waitState("lan", .connected, 8000)
        // one success per target per app run: a reconnect does not probe again
        let probes = lan.probes
        XCTAssertNil(e.reconnect("lan"))
        f.waitLog("deploy done: server reuse", 8000)
        f.waitState("lan", .connected, 8000)
        XCTAssertEqual(lan.probes, probes)
        XCTAssertFalse(f.logHas("checking local network"))
        // a non-LAN target is never probed
        lan.local = false
        f.addProfile("wan", "me@box", "")
        XCTAssertNil(e.connect("wan"))
        f.waitState("wan", .connected, 8000)
        XCTAssertEqual(lan.probes, probes)
    }

    func testDeniedSshParksOnTheHintAndReconnectsWhenGranted() throws {
        _ = try f.buildPayload("v1")
        let lan = FakeLAN()
        lan.local = false // the first probe says "not local" so ssh runs at once…
        f.lan = lan
        let e = try f.start()
        f.addProfile("lan", "me@lanbox", "") // …and the fake ssh answers "No route to host"
        XCTAssertNil(e.connect("lan"))
        f.waitState("lan", .failed, 5000)
        do {
            let st = e.status("lan")!
            XCTAssertEqual(st.msg, LocalNetwork.hint)
            XCTAssertTrue(st.stderr.contains("No route to host"))
        }
        f.expectLog("[lan] ssh reported \"No route to host\" — on macOS this is usually the Local Network privacy grant, not routing")
        f.expectLog("[lan] state connecting → failed msg=\"macOS blocked local network access")
        // parked, but watching: the target is probed again and again
        lan.result = LANProbeResult(ok: false, code: "EHOSTUNREACH", ms: 1)
        f.waitFor(3000) { lan.probes >= 3 }
        XCTAssertEqual(e.status("lan")!.step, .waitingLocalNetworkGrant)
        XCTAssertEqual(e.status("lan")!.state, .failed)
        // a second profile on the same host+instance is refused meanwhile
        f.addProfile("dup", "me@lanbox", "")
        XCTAssertEqual(e.connect("dup"), "\"lan\" is already connected to this host and instance")
        // the grant arrives: a fresh attempt starts by itself (the fake ssh
        // still says "No route to host" for lanbox, so swap the host first)
        XCTAssertNil(e.saveProfile(ProfileInput(name: "lan", host: "me@box"), originalName: "lan"))
        // (the parked cycle keeps what it holds — the edit applies on the next
        // connect, so make the recovery attempt a reconnect by the user instead)
        lan.result = LANProbeResult(ok: true, ms: 1)
        f.waitLog("[lan] local network access granted — reconnecting host=lanbox port=22", 4000)
        f.waitLog("[lan] state failed → connecting", 4000)
        // disconnect while parked on the hint works too
        e.disconnect("lan")
        f.waitFor(4000) { self.f.removedCount >= 1 }
        XCTAssertNil(e.status("lan"))
    }

    // -- Mac-only: first-run import of Electron profiles (deviation 5) --------------

    func testFirstRunImportsElectronProfilesNotPasswords() throws {
        try f.writeFile("home/electron/config.json", """
        {"profiles":[{"name":"box","host":"me@box","sshPort":"2222","identityFile":"~/.ssh/k","instance":"dev","localPort":4000,"extraOptions":"-4","passwordEnc":"c2VjcmV0","downloadDir":"/dl"},
         {"name":"bad","host":"h","instance":"a b"}, {"name":"nohost"}, 7, {"name":"box","host":"dup"}],
         "lastProfile":"box","settings":{"theme":"light"}}
        """)
        f.electronCandidates = [f.path("home/nonexistent.json"), f.path("home/electron/config.json")]
        var e = try f.start()
        f.expectLog("imported profiles from the Electron client file=")
        f.expectLog("profiles=1")
        f.expectLog("[bad] profile not imported error=\"instance name must be blank (default) or letters, digits, . _ -\"")
        f.expectLog("[box] profile not imported error=\"a profile named \\\"box\\\" already exists\"")
        let p = e.profile(named: "box")!
        XCTAssertEqual(p.host, "me@box")
        XCTAssertEqual(p.sshPort, 2222)
        XCTAssertEqual(p.identityFile, "~/.ssh/k")
        XCTAssertEqual(p.instance, "dev")
        XCTAssertEqual(p.extraOptions, "-4")
        XCTAssertEqual(p.downloadDir, "/dl")
        XCTAssertEqual(p.id.count, 16)
        XCTAssertEqual(e.profiles.count, 1)
        XCTAssertNil(e.lastProfile) // nothing else is migrated
        XCTAssertEqual(e.settings.theme, "dark")
        let cfg = f.read("app/config.json")
        XCTAssertFalse(cfg.contains("passwordEnc"))
        XCTAssertFalse(cfg.contains("c2VjcmV0"))
        XCTAssertFalse(cfg.contains("localPort"))
        XCTAssertFalse(f.passwords.has(profileID: p.id))
        // only on a first run: a second start leaves the store alone
        f.stop()
        try f.writeFile("home/electron/config.json", "{\"profiles\":[{\"name\":\"later\",\"host\":\"h\"}]}")
        e = try f.start()
        XCTAssertNil(e.profile(named: "later"))
        XCTAssertEqual(e.profiles.count, 1)
    }

    // -- the default prober: GET / over a unix socket --------------------------------

    func testSocketHostProberAgainstAUnixSocketServer() throws {
        let sock = f.path("run/p.sock")
        let prober = SocketHostProber()
        XCTAssertNotNil(prober.probe(socketPath: sock, timeoutMs: 300)) // nothing there
        // a server that answers with a status line
        let srv = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { dst in sock.utf8CString.withUnsafeBytes { src in dst.copyBytes(from: src) } }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(srv, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(srv, 4)
        let answer = NSLock()
        var reply = true
        let t = Thread {
            while true {
                let c = accept(srv, nil, nil)
                if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 512)
                _ = read(c, &buf, buf.count)
                let req = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
                if answer.withLock({ reply }) && req.hasPrefix("GET / HTTP/1.0\r\n") {
                    let resp = Array("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
                    _ = resp.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
                    close(c)
                } else if answer.withLock({ reply }) {
                    _ = Array("nope".utf8).withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
                    close(c)
                } else {
                    sleepMs(600) // never answers within the timeout
                    close(c)
                }
            }
        }
        t.start()
        defer { close(srv) }
        XCTAssertNil(prober.probe(socketPath: sock, timeoutMs: 1000))
        XCTAssertNil(prober.probe(socketPath: sock, timeoutMs: 1000))
        answer.withLock { reply = false }
        XCTAssertEqual(prober.probe(socketPath: sock, timeoutMs: 200), "Timeout")
        XCTAssertEqual(prober.probe(socketPath: String(repeating: "x", count: 200), timeoutMs: 200), "PathTooLong")
    }
}
