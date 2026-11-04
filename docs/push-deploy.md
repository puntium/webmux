# Push-deploy: connecting IS deploying

Connecting to a host always deploys — it is the only connect mode. Any host
with nothing but sshd is a webmux host: on connect, the Electron client
pushes the server payload for the host's platform — one statically linked
`webmux-host` binary plus the shell shims — up over ssh (when the host
doesn't already have that exact payload), starts the server there, and
tunnels to it. No node, no compiler, no git checkout needed on the remote —
just a POSIX-ish shell, `tar`, `gzip`, and coreutils. A profile is a name,
an ssh host, and optionally an instance name (distinct instances get
independent servers and session sets on the same host).

The binary is the Go port of the old node server (`docs/native-host.md`);
earlier clients pushed a node runtime plus a JS payload instead.

## Connect flow (electron/deploy.js)

1. **Probe** — one ssh round trip: `uname -s/-m`, musl check, and a listing
   of which payloads `~/.webmux/dist/payload` already holds.
2. **Platform** — `electron/platforms.js` maps the probe to a payload key
   (`linux-x64`, `linux-arm64`). The binaries are static musl builds, so a
   row matches glibc and musl hosts alike; an unknown os/cpu fails with the
   list of supported targets.
3. **Payload** — the client ships one tarball per platform
   (`electron/payload/<key>/payload.tar.gz`, hashes in
   `electron/payload/payload.json`). If the host lacks that platform's hash,
   the tarball is streamed up and extracted to
   `~/.webmux/dist/payload/<hash>` (into a dot-tmp dir, then `mv` — the
   probe only believes fully materialized dirs). A push of a few MB once per
   payload version; no separate runtime step.
4. **Start** — `exec ~/.webmux/dist/payload/<hash>/webmux-host start --name <instance>`
   (cwd: the ssh login dir, `$HOME`). The starter prints a single JSON
   object as its last stdout line — `{ ok: true, action: 'reuse'|'started',
   advert }` or `{ ok: false, error, logTail }` (exit 1) — and:
   - if the advert (`~/.webmux/<instance>.json`) says this exact payload is
     already running, reuse it (a reconnect costs ~2s total);
   - otherwise SIGTERM the old **server** (never the pty host — sessions
     live there and survive every upgrade). The advert's pid is the first
     candidate; if the instance's canonical socket still answers afterwards
     (a stale advert — e.g. a server that died without cleanup), any live
     server — native `webmux-host serve` or a legacy node `server.js` —
     whose `WEBMUX_PTYHOST` is this instance is stopped too, so the new
     server can bind. Then start `webmux-host serve` detached (cwd: the
     payload dir) and wait for the new advert.
5. **Tunnel** — the standard `ssh -L` forward to the advertised socket.

Every ssh child parks in the connection's cancellation slot, so Cancel /
Disconnect kills whatever step is in flight.

The pty-host protocol did not change with the native port, so the first
native deploy onto a host running the node payload replaces only the
server: the node pty host and its sessions keep running behind the new
binary.

## Remote layout

```
~/.webmux/
  <instance>.json             advert: { socket, payloadHash, protocol, pid, startedAt }
  <instance>.server.log       server stdout/stderr
  dist/
    payload/<hash>/           extracted payload: webmux-host, shims/, PAYLOAD_HASH
    node/…                    left over from pre-native clients (unused now)
```

Old payload dirs are not auto-deleted (an older server for another instance
may still be running from one); prune by hand if disk matters.

## The payload (deploy/build-payload.js)

```
make payload                                   # host/build.sh, then every platform
node deploy/build-payload.js                   # from existing host/dist/webmux-host-*
node deploy/build-payload.js --only linux-x64  # just one platform
```

Output:

```
electron/payload/payload.json              { platforms: { <key>: { hash, bytes } }, builtAt }
electron/payload/<key>/payload.tar.gz      webmux-host (0755) + shims/ + PAYLOAD_HASH
electron/payload/<key>/staging/            the staged tree (local testing; not packaged)
```

The binaries come from `host/dist/webmux-host-<key>` (built by
`host/build.sh`, `make host`); a missing one fails the build with a pointer
to `host/build.sh`, and `--only` builds just the platforms you have.
`WEBMUX_HOST_BIN_DIR` / `WEBMUX_PAYLOAD_OUT_DIR` redirect input and output
(the local test uses both). No frontend: the UI (`electron/ui/` + the
@xterm browser packages) ships inside the Electron client and is served
locally on the `webmux://` scheme.

Each payload hash is a deterministic content hash (sorted relative paths +
file bytes, excluding `PAYLOAD_HASH`), stamped into `PAYLOAD_HASH`; the
running server reports it back through its advert, which is how the client
decides whether to re-push. Platforms have distinct hashes (their binaries
differ), so they coexist on a shared `$HOME`.

Rebuild after changing anything under `host/` or `shims/`, or the app will
keep deploying the stale payload it has.

## Testing

- `node electron/test/deploy-fake.js` (part of `make client-test`) — the
  whole flow without ssh: builds payloads from stand-in `webmux-host`
  scripts, then runs `deploy()` with every "ssh" command executed by a
  local `sh -c` against a scratch `$HOME` (probe parsing, glibc/musl
  resolution, push, push-skip, start result parsing, failures, cancel).
- `node electron/test/deploy-cli.js user@host [instance] [-- extra ssh args]`
  — the real thing against any host you can ssh to, no Electron needed.

## Adding a platform

1. Build it: a target in `host/build.sh` producing
   `host/dist/webmux-host-<key>`.
2. Add `<key>` to `PLATFORMS` in `deploy/build-payload.js`.
3. Add a row to `electron/platforms.js` (os/cpus, and `musl: null` for a
   static binary, true/false to restrict a dynamically linked one).
4. Test with `deploy-fake.js` and then the CLI harness.

Note for future macOS targets: the server's `/proc`-based foreground
detection degrades gracefully (image pastes fall back to path-typing), and
`runDir()` already falls back to a tmpdir when `XDG_RUNTIME_DIR` is unset.

## Versioning

- **Payload**: content hash, compared advert-vs-client on every connect.
- **Pty-host protocol**: `PROTOCOL` (`ptyhost-client.js`, and its Go port in
  `host/internal/protocol`), baked into the
  pty-host socket name for versions > 1. Bump it on incompatible control
  protocol changes: a new server then spawns a fresh pty host beside an old
  one instead of corrupting it — old sessions keep running on the old host
  (reachable by an old client) rather than breaking.
- The client↔server HTTP/WS protocol needs no versioning here: the client
  ships the frontend and *pushes the server binary built from the same
  tree* (hash-checked on every connect), so the two ends always come from
  the same build.
