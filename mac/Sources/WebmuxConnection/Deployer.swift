// Connecting IS deploying: the port of electron/deploy.js + platforms.js.
//
//   1. probe   — one ssh round trip: uname, libc flavor, which payloads
//                ~/.webmux/dist already holds
//   2. payload — pick this host's platform payload from payload.json; if
//                the host lacks that hash, stream the tarball up and
//                extract it to ~/.webmux/dist/payload/<hash> (.tmp + mv)
//   3. start   — `<payload>/webmux-host start --name <instance>`; the
//                last JSON line of its stdout is the result, whose
//                advert.socket is what the tunnel forwards to
//
// Remote scripts are byte-for-byte deploy.js's (POSIX sh, double quotes,
// $HOME, wrapped in `exec sh -c '…'`).
import Foundation

public enum Deployer {
    public static let remoteBase = "$HOME/.webmux/dist"

    public static let probeScript = "echo \"@@os $(uname -s)\"; "
        + "echo \"@@cpu $(uname -m)\"; "
        + "(ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo \"@@musl yes\" || echo \"@@musl no\"; "
        + "for f in \(remoteBase)/payload/*/PAYLOAD_HASH; do [ -f \"$f\" ] && echo \"@@payload $f\"; done; "
        + "true"

    public static func shWrap(_ script: String) -> String { "exec sh -c '\(script)'" }

    // -- platforms (platforms.js) ----------------------------------------------

    public struct Platform: Sendable, Equatable {
        public let key: String
        public let os: String
        public let cpus: [String]
        /// nil = libc-agnostic (static musl build)
        public let musl: Bool?
    }

    public static let platforms: [Platform] = [
        Platform(key: "linux-x64", os: "Linux", cpus: ["x86_64", "amd64"], musl: nil),
        Platform(key: "linux-arm64", os: "Linux", cpus: ["aarch64", "arm64"], musl: nil),
    ]

    public struct Probe: Sendable, Equatable {
        public var os = ""
        public var cpu = ""
        public var musl = false
        /// payload hashes present on the host (dir names)
        public var payloadHashes: [String] = []
        public init(os: String = "", cpu: String = "", musl: Bool = false, payloadHashes: [String] = []) {
            self.os = os
            self.cpu = cpu
            self.musl = musl
            self.payloadHashes = payloadHashes
        }
    }

    public static func resolvePlatform(_ probe: Probe) -> Platform? {
        platforms.first { p in
            p.os == probe.os && p.cpus.contains(probe.cpu) && (p.musl == nil || p.musl == probe.musl)
        }
    }

    public static var supportedSummary: String {
        platforms.map { p in
            p.os + " " + p.cpus[0] + (p.musl == true ? " (musl)" : p.musl == false ? " (glibc)" : "")
        }.joined(separator: ", ")
    }

    /// Parse the probe's output; shell-profile noise is ignored.
    public static func parseProbe(_ out: String) -> Probe {
        var probe = Probe()
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\u{0b}\u{0c}"))
            guard line.hasPrefix("@@"), let sp = line.firstIndex(of: " ") else { continue }
            let tag = String(line[line.index(line.startIndex, offsetBy: 2)..<sp])
            if tag.isEmpty || tag.contains("\t") { continue }
            let value = String(line[line.index(after: sp)...])
            let v = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            switch tag {
            case "os": probe.os = v
            case "cpu": probe.cpu = v
            case "musl": probe.musl = v == "yes"
            case "payload": probe.payloadHashes.append(Util.basename(Util.dirname(value))) // path.basename(path.dirname(value))
            default: break
            }
        }
        return probe
    }

    // -- manifest -----------------------------------------------------------------

    public static func isHash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `{ platforms: { <key>: { hash, bytes } }, builtAt }` as written by
    /// deploy/build-payload.js: the platform's hash, or nil when the manifest
    /// is missing/malformed or lacks a valid entry.
    public static func manifestHash(payloadDir: String?, key: String) -> String? {
        guard let dir = payloadDir, let data = try? Util.readFile(Util.join(dir, "payload.json")),
              let root = JSONValue.parse(data), case .object(let plats)? = root["platforms"],
              case .object(let entry)? = plats[key], let h = entry["hash"]?.stringValue, isHash(h) else { return nil }
        return h
    }

    /// All valid platform hashes in the manifest (restart-sessions prefers them).
    public static func manifestHashes(payloadDir: String?) -> [String] {
        guard let dir = payloadDir, let data = try? Util.readFile(Util.join(dir, "payload.json")),
              let root = JSONValue.parse(data), case .object(let plats)? = root["platforms"] else { return [] }
        return plats.keys.sorted().compactMap { k in
            guard case .object(let e)? = plats[k], let h = e["hash"]?.stringValue, isHash(h) else { return nil }
            return h
        }
    }

    // -- the flow -----------------------------------------------------------------

    public enum Step: Sendable { case probing, pushing, starting }

    /// What deploy needs from its caller (deploy.js `ctx`).
    struct Runner {
        /// Run one remote command over ssh (already parameterized for the
        /// profile), optionally streaming `stdinFile` with push progress.
        var run: (_ command: String, _ stdinFile: String?) throws -> RunResult
        /// Progress line for the connection UI (deploy.js ctx.status), plus
        /// the structured step and push progress.
        var status: (_ step: Step, _ msg: String, _ sent: UInt64, _ total: UInt64) -> Void
        /// Diagnostic tail line.
        var stderr: (String) -> Void
        /// false once this attempt is cancelled.
        var isLive: () -> Bool
    }

    public struct StartResult: Sendable, Equatable {
        /// "reuse" | "started" (or whatever the starter said)
        public var action: String
        public var socket: String
        public var pid: Int64?
        public var platform: String
        public var payloadHash: String
    }

    enum Outcome {
        case ok(StartResult)
        case failed(String)
        case cancelled
    }

    private enum SshOutcome {
        case ok(String)
        case failed(msg: String, stdout: String?)
        case cancelled
    }

    /// deploy.js runSsh: stdout on exit 0, otherwise `ssh exited (<code|signal>)`
    /// (keeping stdout for the starter).
    private static func runSsh(_ r: Runner, _ command: String, stdinFile: String?) -> SshOutcome {
        let res: RunResult
        do {
            res = try r.run(command, stdinFile)
        } catch RunError.cancelled {
            return .cancelled
        } catch RunError.inputUnreadable {
            return .failed(msg: "payload tarball unreadable", stdout: nil)
        } catch RunError.spawn(let e) {
            return .failed(msg: e.text(program: "ssh"), stdout: nil)
        } catch {
            return .failed(msg: "\(error)", stdout: nil)
        }
        if res.exit.ok { return .ok(res.stdout) }
        return .failed(msg: "ssh exited (\(res.exit))", stdout: res.stdout)
    }

    /// Run the whole flow.
    static func deploy(_ r: Runner, payloadDir: String?, instance: String) -> Outcome {
        r.status(.probing, "probing host…", 0, 0)
        let probeOut: String
        switch runSsh(r, shWrap(probeScript), stdinFile: nil) {
        case .ok(let o): probeOut = o
        case .failed(let f): return .failed(f.msg)
        case .cancelled: return .cancelled
        }
        let probe = parseProbe(probeOut)
        if probe.os.isEmpty || probe.cpu.isEmpty {
            return .failed("host probe failed — no uname output (unusual remote shell?)")
        }
        if !r.isLive() { return .cancelled }

        guard let platform = resolvePlatform(probe) else {
            return .failed("unsupported host platform '\(probe.os) \(probe.cpu)\(probe.musl ? " (musl)" : "")' — supported targets: \(supportedSummary)")
        }
        guard let hash = manifestHash(payloadDir: payloadDir, key: platform.key) else {
            return .failed("this client build has no \(platform.key) payload — run `node deploy/build-payload.js` (needs host/dist/webmux-host-\(platform.key)) and restart the app")
        }

        if !probe.payloadHashes.contains(hash) {
            let tarball = Util.join(payloadDir!, platform.key, "payload.tar.gz")
            if !Util.fileExists(tarball) { return .failed("payload tarball missing: \(tarball)") }
            let base = remoteBase + "/payload"
            let script = "rm -rf \(base)/.tmp-\(hash) && mkdir -p \(base)/.tmp-\(hash) && tar xzf - -C \(base)/.tmp-\(hash) && rm -rf \(base)/\(hash) && mv \(base)/.tmp-\(hash) \(base)/\(hash)"
            switch runSsh(r, shWrap(script), stdinFile: tarball) {
            case .ok: break
            case .failed(let f): return .failed(f.msg)
            case .cancelled: return .cancelled
            }
            if !r.isLive() { return .cancelled }
        }

        r.status(.starting, "starting server…", 0, 0)
        var res: StartResult
        switch remoteStart(r, hash: hash, instance: instance) {
        case .ok(let s): res = s
        case .failed(let f): return .failed(f)
        case .cancelled: return .cancelled
        }
        if !r.isLive() { return .cancelled }
        res.platform = platform.key
        res.payloadHash = hash
        return .ok(res)
    }

    /// deploy.js lastJsonLine: the last stdout line that parses as JSON and
    /// is an object — in JS terms, which includes arrays (an array result
    /// then reads as `ok: undefined`).
    static func lastJsonLine(_ out: String) -> JSONValue? {
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard let first = t.first, first == "{" || first == "[" else { continue }
            guard let v = JSONValue.parse(t) else { continue }
            switch v {
            case .object, .array: return v
            default: continue
            }
        }
        return nil
    }

    private static func remoteStart(_ r: Runner, hash: String, instance: String) -> Outcome {
        let cmd = "exec \(remoteBase)/payload/\(hash)/webmux-host start --name \(instance)"
        var exitMsg: String?
        let out: String
        switch runSsh(r, shWrap(cmd), stdinFile: nil) {
        case .ok(let o): out = o
        case .cancelled: return .cancelled
        case .failed(let f):
            guard let so = f.stdout else { return .failed("server start failed: \(f.msg)") }
            exitMsg = f.msg
            out = so
        }
        guard let resultV = lastJsonLine(out) else {
            if let m = exitMsg { return .failed("server start failed: \(m)") }
            return .failed("webmux-host start produced no result — see diagnostics")
        }
        guard case .object(let result) = resultV else { return .failed("server start failed: undefined") }
        let ok = result["ok"]?.truthy ?? false
        if !ok {
            if case .string(let lt)? = result["logTail"] {
                for line in lt.split(separator: "\n") where !line.isEmpty { r.stderr(String(line)) }
            }
            let e = result["error"]?.jsString ?? "undefined"
            return .failed("server start failed: \(e)")
        }
        if let m = exitMsg { return .failed("server start failed: \(m)") }
        guard case .object(let advert)? = result["advert"], let sock = advert["socket"]?.stringValue, !sock.isEmpty else {
            return .failed("webmux-host start returned no advert socket")
        }
        var pid: Int64?
        if case .integer(let p)? = advert["pid"] { pid = p }
        let action = result["action"]?.stringValue ?? "ready"
        return .ok(StartResult(action: action, socket: sock, pid: pid, platform: "", payloadHash: ""))
    }

    // -- Restart Sessions (main.js restartRemoteSessions) ----------------------

    /// The remote script, byte-for-byte main.js's. `instance` must already be
    /// validated (shell-inert).
    public static func restartScript(instance: String, hashes: [String]) -> String {
        let instRe = instance.replacingOccurrences(of: ".", with: "[.]") // regex-safe for pgrep -f
        let hostRe = "(ptyhost[.]js|webmux-host ptyhost)"
        var s = "r=no-deploy; for f in "
        for h in hashes { s += "$HOME/.webmux/dist/payload/\(h)/webmux-host " }
        s += "$(ls -t $HOME/.webmux/dist/payload/*/webmux-host 2>/dev/null); do "
        s += "[ -x \"$f\" ] || continue; "
        s += "if \"$f\" ptyhost --name \(instance) shutdown; then r=restarted; break; else r=not-running; fi; "
        s += "done; "
        s += "if [ \"$r\" != restarted ]; then "
        s += "node=$(ls -t $HOME/.webmux/dist/node/*/bin/node 2>/dev/null | head -1); "
        s += "ph=$(ls -t $HOME/.webmux/dist/payload/*/ptyhost.js 2>/dev/null | head -1); "
        s += "if [ -n \"$node\" ] && [ -n \"$ph\" ]; then "
        s += "if \"$node\" \"$ph\" --name \(instance) shutdown; then r=restarted; else r=not-running; fi; "
        s += "fi; fi; "
        s += "if [ \"$r\" = not-running ]; then "
        s += "pids=$(pgrep -u \"$(id -un)\" -f \"\(hostRe) --name \(instRe)$\" 2>/dev/null); "
        if instance == "default" {
            s += "[ -z \"$pids\" ] && pids=$(pgrep -u \"$(id -un)\" -f \"\(hostRe)$\" 2>/dev/null); "
        }
        s += "if [ -n \"$pids\" ]; then kill $pids && r=stale-killed; fi; fi; "
        s += "echo \"@@result $r\""
        return s
    }

    /// Interpret the restart run (main.js's result mapping).
    public static func restartOutcome(stdout: String, exit: ExitStatus, stderrLines: [String]) -> (ok: Bool, msg: String) {
        var result: String?
        for line in stdout.split(separator: "\n") where line.hasPrefix("@@result ") {
            let rest = line.dropFirst("@@result ".count)
            let word = rest.prefix { !" \t\r".contains($0) }
            if !word.isEmpty {
                result = String(word)
                break
            }
        }
        switch result {
        case "restarted": return (true, "sessions restarted — all shells were stopped, fresh ones start on demand")
        case "stale-killed": return (true, "an old session host did not answer the shutdown and was killed — fresh sessions start on demand")
        case "not-running": return (true, "no sessions were running — nothing to restart")
        case "no-deploy": return (false, "webmux has never been deployed to this host")
        default: break
        }
        var msg = "ssh exited (\(exit))"
        if !stderrLines.isEmpty {
            msg += " — " + stderrLines.suffix(2).joined(separator: "; ")
        }
        return (false, msg)
    }
}
