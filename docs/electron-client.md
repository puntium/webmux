# Electron client over SSH

A native macOS client for webmux: an Electron shell that reaches the existing
web server through an SSH tunnel instead of an exposed port. server.js stays
the remote API surface (file browser, paste/clipboard shims, future
endpoints); ptyhost stays the session owner; the frontend is unchanged.

## Topology

```
Electron main process (macOS)
  ├─ spawns/supervises: ssh -N -L 127.0.0.1:<local>:127.0.0.1:<remote> <host>
  └─ BrowserWindow → http://127.0.0.1:<local>
                          │  (page, /api/*, /ws all ride the tunnel)
      (remote) server.js — plain http, no auth, bound to 127.0.0.1
                          └─ ptyhost daemon (unchanged)
```

Design decisions, and why:

- **Tunnel the whole HTTP server; don't talk to ptyhost directly.** Keeps
  server.js as the extension point for remote features and requires zero
  frontend or protocol changes. The machine-local endpoints (fs browser,
  paste slot, /proc foreground detection) keep working as-is.
- **SSH is the transport and the auth.** The remote server runs plain http
  with no Basic auth, bound to localhost so it is reachable *only* through
  sshd. TLS/self-signed certs disappear from this path entirely. (A second
  server.js instance with `tls`/`auth` on another port can still front the
  same ptyhost for browser/phone access.)
- **Fixed local port across tunnel respawns.** app.js already reconnects its
  WebSockets with backoff and repaints from ptyhost snapshots. If the tunnel
  comes back on the same port, the loaded page self-heals — no reload, no
  lost tile layout. The port is chosen once at startup (or pinned in config)
  and reused for every respawn.
- **Resume is ptyhost's job and is untouched.** Disconnect (tunnel death,
  sleep, network change) just detaches the socket; the headless mirror keeps
  recording; reattach replays a full snapshot.

## Components

### 1. Server: `bind` config (done)

`server.listen` gains a bind address from config (`bind: 127.0.0.1`),
default unchanged (all interfaces). This is the one server-side change; the
tunnel setup is otherwise pure config (`tls: false`, no `auth`).

### 2. Electron app: `electron/` (done)

A self-contained npm package so the server install never pulls Electron.

- `main.js` — tunnel supervision, profile store, window, menu.
  - **Profiles** at `<userData>/config.json` (`~/Library/Application
    Support/webmux/config.json` on macOS): `{ profiles: [{ name, host,
    sshPort, identityFile, remotePort, localPort, extraOptions,
    passwordEnc }], lastProfile }`. The pre-profiles single-host shape is
    migrated on first load. Startup always lands on the connection manager
    — connecting is the user's call; ⌘⇧O reopens it anytime.
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
    127.0.0.1:<local>:127.0.0.1:<remote> <host>`. BatchMode means key auth
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

On the box, in `config.yaml`:

```yaml
tls: false
bind: 127.0.0.1
# no auth: section — sshd is the front door
```

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
