# Electron client over SSH

The native macOS client for webmux — and the only way to connect from
another machine: an Electron shell that reaches the server through an SSH
tunnel to its unix socket. server.js stays the remote API surface (file
browser, paste/clipboard shims, future endpoints); ptyhost stays the session
owner; the frontend (`electron/ui/` + the @xterm browser packages) ships
inside the client and is served locally on the `webmux://` scheme — only
API and WebSocket traffic crosses the wire.

## Topology

```
Electron main process (macOS)
  └─ BaseWindow
       ├─ header strip (header.html, client-owned): one pill per connection
       └─ per connected profile:
            ├─ spawns/supervises: ssh -N -L 127.0.0.1:<local>:<remote socket> <host>
            └─ WebContentsView → webmux://<host-slug>/?port=<local>
                 │  (page + assets served from the app bundle)
                 └─ /api/* and /ws → http://127.0.0.1:<local>, riding the tunnel
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
  server.js as the extension point for remote features. The machine-local
  endpoints (fs browser, paste slot, /proc foreground detection) need a
  process on the host, and the thin restartable server is the right home
  for churny features (ptyhost stays frozen so sessions survive upgrades).
- **The frontend never crosses the wire.** The client serves `ui/` and its
  @xterm vendor packages from the app bundle via a `webmux://` protocol
  handler (registered standard+secure, so localStorage and the clipboard
  APIs work). Each connection loads `webmux://<host-slug>/?port=<local>`;
  the page reads the port and points its fetches and WebSockets at
  `http://127.0.0.1:<port>`. The server answers every request with
  permissive CORS — the unix socket's permissions and sshd are the access
  control, browser origin checks add nothing there. Versioning stays sound:
  the UI ships with the client, and connecting pushes the matching server
  payload (hash-checked), so both ends still come from the same build.
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
- **Stable local port within a run; origin independent of it.** app.js
  reconnects its WebSockets with backoff and repaints from ptyhost
  snapshots, so a tunnel that comes back on the same port heals the loaded
  page in place — no reload, no lost tile layout. The port is picked once
  per profile per app run (or pinned in the profile); nothing persists it,
  because the page's origin — and thus its localStorage (layout tree,
  file-browser state) — is the `webmux://<host-slug>` origin derived from
  the profile's host+instance, stable across app runs, port changes, and
  profile renames. Layouts thereby stay per client *and* per host, which
  is the right scoping: an arrangement fits the client's screen, not the
  server.
- **Resume is ptyhost's job and is untouched.** Disconnect (tunnel death,
  sleep, network change) just detaches the socket; the headless mirror keeps
  recording; reattach replays a full snapshot.

## Components

### 1. Server: unix-socket listener (done)

`server.listen` takes the socket path (`$XDG_RUNTIME_DIR/webmux/
<ptyhost>.http.sock` by default, env `WEBMUX_SOCKET` to override), chmods it
0600, recovers a stale socket file left by a dead server (probe → remove →
relisten, same dance as ptyhost), and removes it on SIGINT/SIGTERM. On
listen it writes the JSON advert `~/.webmux/<name>.json` (0600 in a 0700
dir; socket path, payload hash, protocol, pid) that the deploy flow reads —
this also tracks a socket override automatically. No TCP, TLS, or auth
code remains.

### 2. Electron app: `electron/` (done)

A self-contained npm package so the server install never pulls Electron.

- `main.js` — tunnel supervision, profile store, window, menu.
  - **Profiles** at `<userData>/config.json` (`~/Library/Application
    Support/webmux/config.json` on macOS): `{ profiles: [{ name, host,
    sshPort, identityFile, instance, localPort, extraOptions,
    passwordEnc }], lastProfile }`. The pre-profiles single-host shape is
    migrated on first load; the pre-unix-socket `remotePort` field is
    dropped, a legacy bare-name `remoteSocket` becomes the `instance`
    field (an absolute-path one falls back to `default`), and the
    pre-webmux://-origin `savedPort` field is dropped. `instance` is
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
    ControlMaster=no -o ControlPath=none -o ServerAliveInterval=10 -o
    ServerAliveCountMax=2 -o ConnectTimeout=10 -L
    127.0.0.1:<local>:<remote socket> <host>`. BatchMode means key auth
    only — a passphrase prompt would hang a headless spawn; stderr is kept
    for the boot page. ControlMaster is forced off: a mux client from
    `~/.ssh/config` would ignore the keepalive options and sit alive on a
    dead link for hours.
  - **Supervision**: auto-retry (backoff 1s → 15s cap) happens *only* when
    an established connection is interrupted — a connect-cycle that reached
    'connected' and then dropped. A cycle that never connected (typo'd
    host, wrong password) parks in a 'failed' state with ssh's stderr and
    waits for the user; no background retry loop churns the UI while
    profiles are being edited. Keepalives bound dead-link detection to
    ~30s. `powerMonitor` `resume` kills the stale tunnel on lid-open so an
    interrupted session reconnects at once instead of waiting for the
    keepalive timeout.
  - **Liveness**: `ssh -N` only knows about its own link — it stays alive
    (and used to look "connected") while the remote server was dead or
    restarted, or a half-open link waited out the keepalives. So main
    probes `GET /` through the tunnel every 5s for as long as the tunnel
    child lives (2s timeout; a dead link shows up as a timeout because ssh
    accepts the local connect regardless). Three consecutive misses kill
    the tunnel and let the ordinary exit → retry → redeploy path heal it —
    the remote starter restarts a dead server. A fresh tunnel that never
    reaches the server within 20s is killed the same way. Independently,
    the page marks its title `· offline` while any session socket is down
    and retrying; main parses that (it already harvests the tab count from
    the title, and remote pages have no IPC bridge) into a `degraded` pill
    state — amber — so the chrome never shows green over a terminal saying
    "disconnected".
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
- **Connection log** (`log.js`, `logs.html`): a client-wide record of
  connection setup, teardown, and recovery, for diagnosing the "why did
  my host go amber" class of question after the fact. Two sinks — a
  3000-entry in-memory ring the log window tails live, and an append-only
  `<userData>/logs/webmux.log` (rolled to `.1` at 1 MB) — fed from one
  `push()`; each entry is `{ seq, t, level, src, conn, msg, data }` and
  the file gets one `<iso> LEVEL [conn] msg k=v…` line per entry.
  - **Main logs**: connect/reconnect requests (host, instance, port, auth
    *mode* — never the password or the spawn env), each deploy step once
    (progress percentages collapse onto their step), ssh stderr lines,
    deploy result (reuse/started, socket, elapsed), tunnel spawn (pid,
    full argv) and exit (code/signal, uptime), every probe miss and the
    give-up that kills the tunnel, every state transition, retry
    scheduling and firing, the page's offline/online verdict, page load
    failures, user disconnects, lid-open tunnel kills, and quit.
  - **Pages log** over `POST /log` on their own `webmux://` origin
    (`ui/log.js`, batched): session-socket connecting/open/reopened,
    dropped (close code, reason, uptime, retry delay), session exit,
    link down/up transitions, and the initial session-list fetch. The
    bundle's protocol handler tags the batch with the connection that
    owns the origin, sanitizes it (level whitelist, clipped strings,
    plain keys only, 50 per batch), and merges it. Nothing flows back:
    the log names other hosts, which a page must never see — so the
    window is not a page, and `POST /log/open` (what the settings panel's
    *Open log…* hits) can only pop it, not read it.
  - **Log window** (`logs.html`, a client-owned `BrowserWindow` with the
    file:-only bridge; ⌘⇧L, the connect page's *Log* button, or the
    page settings panel): live tail with follow-on-scroll, host/level/text
    filters, *Copy visible* (⌘⇧C) / *Copy all* in file format, *Reveal
    file*, and *Clear* (ring only — the file is kept). One instance;
    opening again focuses it.
- `connect.html` + `header.html` + `preload.js` — the connection manager
  (list / add / edit / delete profiles, per-profile connect/disconnect,
  live tunnel status with ssh stderr for diagnosis) and the pill strip;
  `logs.html` is the log window. All three talk to main over a
  contextBridge IPC API that the preload exposes
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
