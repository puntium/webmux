// ssh command lines and environment (main.js sshBaseArgs, sshTunnelArgs,
// sshEnvFor, ensureAskpass), with the tunnel's local end changed to a unix
// socket (docs/macos-client.md › deviation 2).
//
// The password never appears in argv: with one, ssh is told to make one
// password attempt and to ask the askpass helper, which echoes
// `$WEBMUX_SSH_PASSWORD` from the child's own environment.
import Foundation

public enum SSHCommand {
    public static let askpassScript = "#!/bin/sh\nprintf '%s' \"$WEBMUX_SSH_PASSWORD\"\n"
    public static let passwordEnv = "WEBMUX_SSH_PASSWORD"

    /// Options shared by the tunnel and the deploy steps: auth, endpoint and
    /// timeouts, but no forwarding.
    public static func baseArgs(_ p: Profile, hasPassword: Bool) -> [String] {
        var out: [String] = []
        // Key-only auth unless a password is saved: BatchMode forbids prompts,
        // which would otherwise hang a headless spawn. With a password the
        // askpass helper answers the one permitted prompt — one, so a wrong
        // password fails fast instead of re-prompting.
        if hasPassword {
            out += ["-o", "NumberOfPasswordPrompts=1"]
        } else {
            out += ["-o", "BatchMode=yes"]
        }
        // Never ride a ControlMaster from ~/.ssh/config: a mux client ignores
        // the keepalives below.
        out += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        // Dead-link detection bound: 10s × (2+1) ≈ 30s.
        out += ["-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=10"]
        if p.sshPort != 0 { out += ["-p", String(p.sshPort)] }
        if !p.identityFile.isEmpty { out += ["-i", p.identityFile] }
        out += p.extraOptions.split(whereSeparator: { " \t\r\n\u{0b}\u{0c}".contains($0) }).map(String.init)
        return out
    }

    /// `ssh <base> <host> <command>` for a deploy step / restart-sessions.
    public static func commandArgv(ssh: String, _ p: Profile, hasPassword: Bool, command: String) -> [String] {
        [ssh] + baseArgs(p, hasPassword: hasPassword) + [p.host, command]
    }

    /// The tunnel: `ssh -N -o ExitOnForwardFailure=yes -o
    /// StreamLocalBindUnlink=yes <base> -L <local.sock>:<remote.sock> <host>`.
    /// StreamLocalBindUnlink makes ssh remove a stale socket file left by an
    /// earlier tunnel before binding; the bind mask stays ssh's default 0177
    /// and the socket's directory is 0700.
    public static func tunnelArgv(ssh: String, _ p: Profile, hasPassword: Bool, localSocket: String, remoteSocket: String) -> [String] {
        [ssh, "-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes"]
            + baseArgs(p, hasPassword: hasPassword)
            + ["-L", "\(localSocket):\(remoteSocket)", p.host]
    }

    /// argv without argv[0], space-joined behind `ssh`: the `cmd` field of
    /// the "tunnel spawned" log line (`ssh ${args.join(' ')}`).
    public static func joinForLog(_ argv: [String]) -> String {
        (["ssh"] + argv.dropFirst()).joined(separator: " ")
    }

    /// Child environment: the base env plus, with a password, the askpass
    /// trio. A password never leaks in from our own environment.
    public static func childEnvironment(base: [String: String], askpassPath: String, password: String?) -> [String: String] {
        var env = base
        env.removeValue(forKey: passwordEnv)
        if let pw = password {
            env["SSH_ASKPASS"] = askpassPath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            // OpenSSH before 8.4 only consults SSH_ASKPASS with a DISPLAY set;
            // any value does (macOS has none). Harmless with `force`.
            if env["DISPLAY"] == nil { env["DISPLAY"] = "webmux-askpass:0" }
            env[passwordEnv] = pw
        }
        return env
    }

    /// Write the askpass helper (0700) into `dir` (created 0700) and return its path.
    public static func ensureAskpass(dir: String) throws -> String {
        try Util.makePath(dir, mode: 0o700)
        let path = Util.join(dir, "askpass.sh")
        try Util.atomicWrite(path, askpassScript, mode: 0o700)
        return path
    }

    /// The ssh program to spawn: a path as given, or a bare name found on
    /// `PATH` (falling back to /usr/bin/ssh so a spawn failure names a path).
    public static func resolveExecutable(_ ssh: String, environment: [String: String]) -> String {
        if ssh.contains("/") { return ssh }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let cand = Util.join(String(dir), ssh)
            if access(cand, X_OK) == 0 { return cand }
        }
        return Util.join("/usr/bin", ssh)
    }
}
