import XCTest
@testable import WebmuxConnection

final class DeployerTests: XCTestCase {
    func testProbeParsing() {
        let p = Deployer.parseProbe("Last login: yesterday\n@@os Linux\n@@cpu aarch64\n@@musl yes\n@@payload /home/u/.webmux/dist/payload/abc123/PAYLOAD_HASH\nnoise @@os Darwin\n")
        XCTAssertEqual(p.os, "Linux")
        XCTAssertEqual(p.cpu, "aarch64")
        XCTAssertTrue(p.musl)
        XCTAssertEqual(p.payloadHashes, ["abc123"])
        XCTAssertEqual(Deployer.resolvePlatform(p)?.key, "linux-arm64")
        XCTAssertEqual(Deployer.parseProbe("just noise\n").os, "")
        XCTAssertEqual(Deployer.probeScript, "echo \"@@os $(uname -s)\"; echo \"@@cpu $(uname -m)\"; (ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo \"@@musl yes\" || echo \"@@musl no\"; for f in $HOME/.webmux/dist/payload/*/PAYLOAD_HASH; do [ -f \"$f\" ] && echo \"@@payload $f\"; done; true")
    }

    func testPlatformResolution() {
        func key(_ os: String, _ cpu: String, _ musl: Bool) -> String? {
            Deployer.resolvePlatform(Deployer.Probe(os: os, cpu: cpu, musl: musl))?.key
        }
        XCTAssertEqual(key("Linux", "x86_64", false), "linux-x64")
        XCTAssertEqual(key("Linux", "x86_64", true), "linux-x64")
        XCTAssertEqual(key("Linux", "amd64", false), "linux-x64")
        XCTAssertEqual(key("Linux", "aarch64", true), "linux-arm64")
        XCTAssertNil(key("Linux", "armv7l", false))
        XCTAssertNil(key("Darwin", "arm64", false))
        XCTAssertEqual(Deployer.supportedSummary, "Linux x86_64, Linux aarch64")
    }

    func testLastJsonLineSkipsNoise() {
        let o = Deployer.lastJsonLine("chatter\n[1, 2]\n{\"ok\":true,\"advert\":{\"socket\":\"/tmp/x.sock\"}}\n\"str\"\n")
        XCTAssertEqual(o?["ok"], .bool(true))
        XCTAssertNil(Deployer.lastJsonLine("nope\n42\n"))
        if case .array? = Deployer.lastJsonLine("{\"ok\":true}\n[1]\n") {} else { XCTFail("array result should win") }
    }

    func testManifest() throws {
        let dir = "/tmp/wm-mf-\(Util.randomHex(bytes: 4))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Util.makePath(dir, mode: 0o700)
        let h = String(repeating: "a", count: 64)
        try Util.atomicWrite(Util.join(dir, "payload.json"), "{\"platforms\":{\"linux-x64\":{\"hash\":\"\(h)\",\"bytes\":1},\"linux-arm64\":{\"hash\":\"bad\"}},\"builtAt\":\"x\"}", mode: 0o644)
        XCTAssertEqual(Deployer.manifestHash(payloadDir: dir, key: "linux-x64"), h)
        XCTAssertNil(Deployer.manifestHash(payloadDir: dir, key: "linux-arm64"))
        XCTAssertNil(Deployer.manifestHash(payloadDir: nil, key: "linux-x64"))
        XCTAssertEqual(Deployer.manifestHashes(payloadDir: dir), [h])
    }

    func testRestartScriptMatchesMainJsByteForByte() {
        let s = Deployer.restartScript(instance: "default", hashes: [String(repeating: "a", count: 64)])
        // produced by node from main.js restartRemoteSessions with the same inputs
        XCTAssertEqual(s, "r=no-deploy; for f in $HOME/.webmux/dist/payload/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/webmux-host $(ls -t $HOME/.webmux/dist/payload/*/webmux-host 2>/dev/null); do [ -x \"$f\" ] || continue; if \"$f\" ptyhost --name default shutdown; then r=restarted; break; else r=not-running; fi; done; if [ \"$r\" != restarted ]; then node=$(ls -t $HOME/.webmux/dist/node/*/bin/node 2>/dev/null | head -1); ph=$(ls -t $HOME/.webmux/dist/payload/*/ptyhost.js 2>/dev/null | head -1); if [ -n \"$node\" ] && [ -n \"$ph\" ]; then if \"$node\" \"$ph\" --name default shutdown; then r=restarted; else r=not-running; fi; fi; fi; if [ \"$r\" = not-running ]; then pids=$(pgrep -u \"$(id -un)\" -f \"(ptyhost[.]js|webmux-host ptyhost) --name default$\" 2>/dev/null); [ -z \"$pids\" ] && pids=$(pgrep -u \"$(id -un)\" -f \"(ptyhost[.]js|webmux-host ptyhost)$\" 2>/dev/null); if [ -n \"$pids\" ]; then kill $pids && r=stale-killed; fi; fi; echo \"@@result $r\"")
        let s2 = Deployer.restartScript(instance: "a.b", hashes: [])
        XCTAssertTrue(s2.contains("--name a[.]b$"))
        XCTAssertFalse(s2.contains("[ -z \"$pids\" ]")) // the default-only fallback
    }

    func testRestartOutcomeMapping() {
        XCTAssertEqual(Deployer.restartOutcome(stdout: "motd\n@@result restarted\n", exit: .code(0), stderrLines: []).msg, "sessions restarted — all shells were stopped, fresh ones start on demand")
        XCTAssertEqual(Deployer.restartOutcome(stdout: "@@result stale-killed", exit: .code(0), stderrLines: []).ok, true)
        XCTAssertEqual(Deployer.restartOutcome(stdout: "@@result not-running", exit: .code(0), stderrLines: []).msg, "no sessions were running — nothing to restart")
        let nd = Deployer.restartOutcome(stdout: "@@result no-deploy", exit: .code(0), stderrLines: [])
        XCTAssertFalse(nd.ok)
        XCTAssertEqual(nd.msg, "webmux has never been deployed to this host")
        let e = Deployer.restartOutcome(stdout: "", exit: .code(255), stderrLines: ["a", "b", "c"])
        XCTAssertEqual(e.msg, "ssh exited (255) — b; c")
        XCTAssertEqual(Deployer.restartOutcome(stdout: "", exit: .signal(SIGTERM), stderrLines: []).msg, "ssh exited (SIGTERM)")
    }

    func testLineSplitterAndStepKey() {
        var s = LineSplitter()
        var lines: [String] = []
        s.feed(Array("a\r\nb".utf8)[...]) { lines.append($0) }
        s.feed(Array("c\n\n\nd\n".utf8)[...]) { lines.append($0) }
        s.flush { lines.append($0) }
        XCTAssertEqual(lines, ["a", "bc", "d"])
        XCTAssertEqual(ConnectionSupervisor.stepKey("pushing webmux… 37% of 12.5 MB"), "pushing webmux…")
        XCTAssertEqual(ConnectionSupervisor.stepKey("probing host…"), "probing host…")
        XCTAssertEqual(ConnectionSupervisor.fmtSeconds(300), "0.3")
        XCTAssertEqual(ConnectionSupervisor.fmtSeconds(15000), "15")
    }
}
