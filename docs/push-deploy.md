# Push-deploy: connecting IS deploying

Connecting to a host always deploys — it is the only connect mode. Any host
with nothing but sshd is a webmux host: on connect, the Electron client
pushes a node runtime and the server payload up over ssh (when the host
doesn't already have the right versions), starts the server there, and
tunnels to it. No node, no compiler, no git checkout needed on the remote —
just a POSIX-ish shell, `tar`, `gzip`, and coreutils. A profile is a name,
an ssh host, and optionally an instance name (distinct instances get
independent servers and session sets on the same host).

## Connect flow (electron/deploy.js)

1. **Probe** — one ssh round trip: `uname -s/-m`, musl check, and a listing
   of which node runtimes and payloads `~/.webmux/dist` already holds.
2. **Runtime** — if the host lacks the right node build, the client downloads
   the official tarball (verified against `SHASUMS256.txt`) into a local
   cache (`<userData>/node-cache`), extracts `bin/node`, and streams it up
   gzipped. ~25 MB once per host; cached locally per platform forever.
3. **Payload** — if the host's payload hash differs from the one the client
   ships (`electron/payload/payload.tar.gz`), it is streamed up and extracted to
   `~/.webmux/dist/payload/<hash>` (into a dot-tmp dir, then `mv` — the probe
   only believes fully materialized dirs).
4. **Start** — `deploy/remote-start.js` runs under the pushed node:
   - if the advert (`~/.webmux/<instance>.json`) says this exact payload is
     already running, reuse it (a reconnect costs ~2s total);
   - otherwise SIGTERM the old **server** (never the pty host — sessions
     live there and survive every upgrade), start `server.js` detached, and
     wait for the new advert.
5. **Tunnel** — the standard `ssh -L` forward to the advertised socket.

Every ssh child parks in the connection's cancellation slot, so Cancel /
Disconnect kills whatever step is in flight.

## Remote layout

```
~/.webmux/
  <instance>.json             advert: { socket, payloadHash, protocol, pid, startedAt }
  <instance>.server.log       server stdout/stderr
  dist/
    node/node-v<V>-<arch>/bin/node
    payload/<hash>/           extracted payload (server + node_modules + PAYLOAD_HASH)
```

Old payload dirs are not auto-deleted (an older server for another instance
may still be running from one); prune by hand if disk matters.

## The payload (deploy/build-payload.js)

```
node deploy/build-payload.js       # → electron/payload/payload.tar.gz + payload.json
```

Stages the server sources plus fresh production `node_modules`, with
`node-pty` swapped for `@homebridge/node-pty-prebuilt-multiarch` (prebuilt
`.node` binaries for linux x64/arm64/arm/ia32 — `ptyhost.js` prefers it when
present, so a dev checkout still uses plain node-pty). The payload hash is a
deterministic content hash, stamped into `PAYLOAD_HASH`; the running server
reports it back through its advert, which is how the client decides whether
to re-push. One payload serves all architectures.

Rebuild after changing any server-side file, or the app will keep deploying
the stale payload it has.

## Adding a platform

1. Add a row to `electron/platforms.js` (os/cpu/musl match → node tarball
   coordinates; `distBase` can point at unofficial-builds for armv6l, musl,
   etc. — see the comment there).
2. Make sure the payload carries a pty prebuild for it. The homebridge
   package covers linux x64/arm64/arm/ia32 today; darwin would need a
   prebuild source added in `deploy/build-payload.js`.
3. Test with the CLI harness, no Electron needed:
   `node electron/test/deploy-cli.js user@host [instance] [-- extra ssh args]`

Note for future macOS targets: `server.js`'s `/proc`-based foreground
detection degrades gracefully (image pastes fall back to path-typing), and
`runDir()` already falls back to a tmpdir when `XDG_RUNTIME_DIR` is unset.

## Versioning

- **Payload**: content hash, compared advert-vs-client on every connect.
- **Pty-host protocol**: `PROTOCOL` in `ptyhost-client.js`, baked into the
  pty-host socket name for versions > 1. Bump it on incompatible control
  protocol changes: a new server then spawns a fresh pty host beside an old
  one instead of corrupting it — old sessions keep running on the old host
  (reachable by an old client) rather than breaking.
- The client↔server HTTP/WS protocol needs no versioning here: the client
  loads the web frontend *served by the payload it just pushed*, so the two
  ends always come from the same build.
