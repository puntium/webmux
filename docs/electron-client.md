# Electron client over SSH

The native macOS client for webmux — and the only way to connect from
another machine: an Electron shell that reaches the web server through an
SSH tunnel to its unix socket. server.js stays the remote API surface (file
browser, paste/clipboard shims, future endpoints); ptyhost stays the session
owner; the frontend is unchanged.

## Topology

```
Electron main process (macOS)
  ├─ spawns/supervises: ssh -N -L 127.0.0.1:<local>:<remote socket> <host>
  └─ BrowserWindow → http://127.0.0.1:<local>
                          │  (page, /api/*, /ws all ride the tunnel)
      (remote) server.js — plain http on a unix socket
                           ($XDG_RUNTIME_DIR/webmux/<name>.http.sock,
                            0600 in a 0700 dir)
                          └─ ptyhost daemon (unchanged)
```

Design decisions, and why:

- **Tunnel the whole HTTP server; don't talk to ptyhost directly.** Keeps
  server.js as the extension point for remote features and requires zero
  frontend or protocol changes. The machine-local endpoints (fs browser,
  paste slot, /proc foreground detection) keep working as-is.
- **SSH is the transport and the auth; the filesystem is the local access
  control.** The server has no TCP listener at all — it serves plain http on
  a unix socket whose permissions (0600 in the 0700 runtime dir) mean only
  the owning user can connect, even from other accounts on the same box.
  OpenSSH forwards local TCP to a remote unix socket natively, so the client
  side is just the `-L` argument. TLS, Basic auth, and bind-address config
  are gone; there is no browser/TCP deployment mode.
- **The remote socket path is auto-discovered.** sshd resolves the
  forwarded path literally (no `~`/`$VAR` expansion), and the default
  location embeds the remote uid (`/run/user/<uid>/…`), which the client
  can't know. So the server advertises its socket path in
  `~/.webmux/<name>.http.sock.path`, and before each tunnel attempt the
  client runs `ssh <host> cat .webmux/<name>.http.sock.path` (remote
  commands get the home dir as cwd) and forwards to whatever it reads —
  re-run on every retry, so a server restarted onto a different path heals
  automatically. The profile's socket field is normally blank (= discover
  instance `default`); a bare name discovers that named instance, an
  absolute path skips discovery entirely.
- **Fixed local port across tunnel respawns.** app.js already reconnects its
  WebSockets with backoff and repaints from ptyhost snapshots. If the tunnel
  comes back on the same port, the loaded page self-heals — no reload, no
  lost tile layout. The port is chosen once at startup (or pinned in config)
  and reused for every respawn.
- **Resume is ptyhost's job and is untouched.** Disconnect (tunnel death,
  sleep, network change) just detaches the socket; the headless mirror keeps
  recording; reattach replays a full snapshot.

## Components

### 1. Server: unix-socket listener (done)

`server.listen` takes the socket path (`$XDG_RUNTIME_DIR/webmux/
<ptyhost>.http.sock` by default, `socket:` in config to override), chmods it
0600, recovers a stale socket file left by a dead server (probe → remove →
relisten, same dance as ptyhost), and removes it on SIGINT/SIGTERM. On
listen it writes the advertisement file `~/.webmux/<name>.http.sock.path`
(0600 in a 0700 dir) that client discovery reads — this also tracks a
`socket:` override automatically. No TCP, TLS, or auth code remains.

### 2. Electron app: `electron/` (done)

A self-contained npm package so the server install never pulls Electron.

- `main.js` — tunnel supervision, profile store, window, menu.
  - **Profiles** at `<userData>/config.json` (`~/Library/Application
    Support/webmux/config.json` on macOS): `{ profiles: [{ name, host,
    sshPort, identityFile, remoteSocket, localPort, extraOptions,
    passwordEnc }], lastProfile }`. The pre-profiles single-host shape is
    migrated on first load, and the pre-unix-socket `remotePort` field is
    dropped (such profiles fall back to auto-discovery). `remoteSocket` is
    validated on save: blank, an absolute path, or a `[A-Za-z0-9._-]+`
    instance name — the name is interpolated into the remote discovery
    command, so it must stay shell-inert. Startup always lands on the
    connection manager — connecting is the user's call; ⌘⇧O reopens it
    anytime.
  - **Passwords** (optional per profile): stored only as `safeStorage`
    ciphertext (macOS Keychain-backed) and never sent to the renderer —
    the bridge sees a `hasPassword` flag. At spawn time the password is
    decrypted into the ssh child's env and served by a tiny askpass script
    with `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4, i.e. macOS 12+),
    which also answers passphrase prompts for encrypted keys. With a
    password, BatchMode is dropped and `NumberOfPasswordPrompts=1` makes a
    wrong password fail fast into retry. Blank on edit keeps the stored
    password; a "clear saved" checkbox removes it.
  - **Tunnel**: `ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o
    ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ConnectTimeout=10 -L
    127.0.0.1:<local>:<remote socket> <host>`. BatchMode means key auth
    only — a passphrase prompt would hang a headless spawn; stderr is kept
    for the boot page.
  - **Supervision**: auto-retry (backoff 1s → 15s cap) happens *only* when
    an established connection is interrupted — a connect-cycle that reached
    'connected' and then dropped. A cycle that never connected (typo'd
    host, wrong password) parks in a 'failed' state with ssh's stderr and
    waits for the user; no background retry loop churns the UI while
    profiles are being edited. Keepalives bound dead-link detection to
    ~30s. `powerMonitor` `resume` kills the stale tunnel on lid-open so an
    interrupted session reconnects at once instead of waiting for the
    keepalive timeout.
  - **Window**: the connection page (`connect.html`) shows live status
    until the server first answers through the tunnel, then `loadURL`.
    `did-fail-load` falls back to it (e.g. Cmd+R while the tunnel is down).
    While the app page is loaded, tunnel blips are *not* a page swap —
    app.js's own retry handles them.
  - **macOS niceties**: no Cmd+W accelerator (closing the window while
    typing in a terminal is the classic Electron footgun); links open in the
    default browser (`setWindowOpenHandler` + `will-navigate` guard);
    standard Edit menu so Cmd+C/V clipboard roles work.
- `connect.html` + `preload.js` — the connection manager: list / add /
  edit / delete profiles, connect, live tunnel status with ssh stderr for
  diagnosis. Talks to main over a contextBridge IPC API that the preload
  exposes **only to `file:` pages** — the remote app page must not be able
  to read or mutate profiles (they contain ssh arguments).
- `package.json` — `electron` + `electron-builder`; `npm start` to run,
  `npm run dist` → zipped `.app` for Apple Silicon (`--x64`/`--universal`
  for Intel). Unsigned: first launch needs right-click → Open or
  `xattr -dr com.apple.quarantine`.

### 3. Remote setup

None needed — `npm start` on the box listens on
`$XDG_RUNTIME_DIR/webmux/default.http.sock` and advertises that path in
`~/.webmux/default.http.sock.path`, which the client discovers on its own.
`config.yaml` can override the path (`socket:`) or the pty host name
(`ptyhost:`); discovery follows either.

## Build & install

```sh
cd electron && npm install
npm start            # dev run (any platform with a display)
npm run dist         # dist/webmux-<version>-arm64-mac.zip
```

Cross-building the zip from Linux works (no native modules in the client;
electron-builder downloads the darwin Electron binary). Building on the Mac
itself is equally fine. No signing/notarization for personal use.

## Later / out of scope for now

- Frontend polish pass: make sure a failed `/api/sessions` poll during a
  tunnel outage can't wedge the UI (WS reconnect is already solid).
- Tray/dock badge for tunnel state.
- Simultaneous connections — one window per profile (profiles + switching
  exist; only one is active at a time today).
- Signing/notarization if the app is ever distributed.
