// WebmuxConnection: everything between "the user clicked Connect on a
// profile" and "there is a live tunnel to the host's HTTP socket, and it
// stays live" — the port of electron/main.js's profile store and
// connections section, electron/deploy.js, electron/lan.js and
// electron/log.js, mirroring the pure-Zig reference package
// gtk/ghostty/src/webmux/conn (docs/macos-client.md).
//
// Threading (docs/macos-client.md › Rules 4): every `ConnectionEngine`
// method is a non-blocking call meant for the main thread (it may do a
// small file write, e.g. saving config.json, but never waits on the network
// or a child process). Each connection runs its own supervisor thread;
// state changes, deploy progress and Restart Sessions results arrive
// through the engine's event sink, and log entries through
// `ConnectionLog.subscribe`, both invoked on engine threads — the app hops
// to the main queue before touching AppKit and must not block in them.
//
// No AppKit, no GhosttyKit, no WebmuxHost: Foundation, Security and Darwin
// only. The liveness probe through the tunnel is a `HostProber` the app may
// replace with its WebmuxHost client; the default does a minimal `GET /`
// over the unix socket.
import Foundation
import os

/// The app's logger for this area (subsystem = bundle id, category = area).
let logger = Logger(subsystem: "me.puntium.webmux.mac", category: "connection")

/// The bundle id: Application Support directory and Keychain service name.
public let webmuxBundleID = "me.puntium.webmux.mac"

/// main.js's timing constants (overridable for tests only). Milliseconds.
public struct ConnectionTiming: Sendable, Equatable {
    /// per liveness request (PROBE_TIMEOUT)
    public var probeTimeoutMs: Int = 2000
    /// between probes once connected (PROBE_INTERVAL)
    public var probeIntervalMs: Int = 5000
    /// between probes before the server first answers (PROBE_RETRY)
    public var probeRetryMs: Int = 500
    /// consecutive misses while connected → the tunnel is dead (PROBE_MISSES)
    public var probeMisses: Int = 3
    /// for a fresh tunnel to reach the server at all (PROBE_FIRST_ANSWER)
    public var probeFirstAnswerMs: Int = 20000
    /// auto-retry backoff: doubles from min to max (scheduleRetry)
    public var retryMinMs: Int = 1000
    public var retryMaxMs: Int = 15000
    /// Restart Sessions' ssh is killed after this long
    public var restartTimeoutMs: Int = 30000
    /// SIGTERM → SIGKILL grace when killing an ssh child
    public var killGraceMs: Int = 2000
    /// macOS Local Network (lan.js / main.js): one TCP connect's timeout, the
    /// re-probe period and total wait while the permission prompt may be up,
    /// and the re-probe period and total wait of a connection parked on the hint.
    public var lanProbeTimeoutMs: Int = 3000
    public var lanGrantReprobeMs: Int = 1000
    public var lanGrantWaitMs: Int = 20000
    public var lanRecoverReprobeMs: Int = 2000
    public var lanRecoverWaitMs: Int = 180000

    public init() {}
}
