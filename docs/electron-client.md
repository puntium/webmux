# Electron client over SSH

The native macOS client for webmux — and the only way to connect from
another machine: an Electron shell that reaches the web server through an
SSH tunnel to its unix socket. server.js stays the remote API surface (file
browser, paste/clipboard shims, future endpoints); ptyhost stays the session
owner; the frontend is unchanged.

## Topology

```
Electron main process (macOS)
  └─ BaseWindow
       ├─ header strip (header.html, client-owned): one pill per connection
       └─ per connected profile:
            ├─ spawns/supervises: ssh -N -L 127.0.0.1:<local>:<remote socket> <host>
            └─ WebContentsView → http://127.0.0.1:<local>
                                     │  (page, /api/*, /ws all ride the tunnel)
                 (remote) server.js — plain http on a unix socket
                                      ($XDG_RUNTIME_DIR/webmux/<name>.http.sock,
                                       0600 in a 0700 dir)
                                     └─ ptyhost daemon (unchanged)
```

Several profiles can be connected at once; the header pills (or ⌘1…⌘9)
switch which view fills the window, and hidden views keep their tunnels and
WebSockets alive (`backgroundThrottling: false`), so switching back is
instant. The pill strip lives in a client-owned view, not in the served
page: a remote server must never learn the other profiles or drive
switching.

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
- **Connecting IS deploying** (since the push-deploy change — see
  `docs/push-deploy.md`): before each tunnel attempt the client makes sure
  the host runs the server version it ships (pushing a node runtime and the
  payload over ssh when needed, restarting the server when it's outdated —
  sessions live in the pty host and survive that), then reads the socket
  path from the advert (`~/.webmux/<name>.json`) the starter prints. sshd
  resolves the forwarded path literally (no `~`/`$VAR` expansion) and the
  default location embeds the remote uid (`/run/user/<uid>/…`), which the
  client can't know — hence the advert rather than a computed path. This
  runs on every retry, so a server restarted onto a different path heals
  automatically. There is no separate "server already running" connect
  mode. The profile's instance field (blank = `default`) selects which
  named instance to run; distinct instances have independent servers and
  session sets.
- **Fixed local port — across tunnel respawns and app runs.** app.js
  already reconnects its WebSockets with backoff and repaints from ptyhost
  snapshots. If the tunnel comes back on the same port, the loaded page
  self-heals — no reload, no lost tile layout. The port is picked once per
  profile (or pinned in the profile) and then persisted (`savedPort` in
  config.json), so the profile keeps the same origin
  `http://127.0.0.1:<port>` across app runs: the page's origin-keyed
  localStorage — the layout tree and file-browser state — survives a
  close/reopen. Layouts thereby stay per client *and* per host, which is
  the right scoping: an arrangement fits the client's screen, not the
  server. If another program grabbed the saved port, a fresh one is picked
  (that stash of localStorage waits under the old origin until the port
  frees up again).
- **Resume is ptyhost's job and is untouched.** Disconnect (tunnel death,
  sleep, network change) just detaches the socket; the headless mirror keeps
  recording; reattach replays a full snapshot.

## Components

### 1. Server: unix-socket listener (done)

`server.listen` takes the socket path (`$XDG_RUNTIME_DIR/webmux/
<ptyhost>.http.sock` by default, `socket:` in config to override), chmods it
0600, recovers a stale socket file left by a dead server (probe → remove →
relisten, same dance as ptyhost), and removes it on SIGINT/SIGTERM. On
listen it writes the JSON advert `~/.webmux/<name>.json` (0600 in a 0700
dir; socket path, payload hash, protocol, pid) that the deploy flow reads —
this also tracks a `socket:` override automatically. No TCP, TLS, or auth
code remains.

### 2. Electron app: `electron/` (done)

A self-contained npm package so the server install never pulls Electron.

- `main.js` — tunnel supervision, profile store, window, menu.
  - **Profiles** at `<userData>/config.json` (`~/Library/Application
    Support/webmux/config.json` on macOS): `{ profiles: [{ name, host,
    sshPort, identityFile, instance, localPort, extraOptions,
    passwordEnc, savedPort }], lastProfile }`. `savedPort` is main's
    bookkeeping (the persisted auto-picked local port, see below), carried
    through edits rather than shown in the form. The pre-profiles single-host shape is
    migrated on first load; the pre-unix-socket `remotePort` field is
    dropped, and a legacy bare-name `remoteSocket` becomes the `instance`
    field (an absolute-path one falls back to `default`). `instance` is
    validated on save: blank or `[A-Za-z0-9._-]+` — it is interpolated
    into remote shell commands, so it must stay shell-inert. Startup always
    lands on the connection manager — connecting is the user's call; ⌘⇧O
    reopens it anytime.
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
  - **Window**: a `BaseWindow` holding a 38px header view (`header.html`)
    plus one `WebContentsView` per connection and one for the connection
    page (`connect.html`); exactly one content view is visible. Connecting
    reveals the host's view when the server first answers through the
    tunnel — unless the user explicitly navigated elsewhere meanwhile
    (explicit navigation cancels pending reveals). `did-fail-load` on a
    connection view falls back to the connection page (e.g. Cmd+R while the
    tunnel is down). While a view's app page is loaded, tunnel blips are
    *not* a view swap — app.js's own retry handles them, and failures of a
    background connection only recolor its pill.
  - **macOS niceties**: no Cmd+W accelerator (closing the window while
    typing in a terminal is the classic Electron footgun); links open in the
    default browser (`setWindowOpenHandler` + `will-navigate` guard);
    standard Edit menu so Cmd+C/V clipboard roles work.
- `connect.html` + `header.html` + `preload.js` — the connection manager
  (list / add / edit / delete profiles, per-profile connect/disconnect,
  live tunnel status with ssh stderr for diagnosis) and the pill strip.
  Both talk to main over a contextBridge IPC API that the preload exposes
  **only to `file:` pages** — the remote app pages must not be able to
  read or mutate profiles (they contain ssh arguments) or see the other
  connections.
- `package.json` — `electron` + `electron-builder`; `npm start` to run,
  `npm run dist` → zipped `.app` for Apple Silicon (`--x64`/`--universal`
  for Intel). Unsigned: first launch needs right-click → Open or
  `xattr -dr com.apple.quarantine`.

### 3. Remote setup

None — the host needs nothing but sshd. Connecting pushes a node runtime
and the server payload to `~/.webmux/dist` and starts the server (see
`docs/push-deploy.md`); the running server advertises its socket in
`~/.webmux/<instance>.json`. (`npm start` from a checkout still works for
local development of the server itself, but the client will replace such a
server with the deployed payload on its next connect.)

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
- Signing/notarization if the app is ever distributed.
