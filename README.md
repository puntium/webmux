# webmux

Tiled terminal sessions with **persistent server-side state**, driven from a
native macOS client over SSH. Shells run on a remote host inside a small pty
daemon and keep running — with their full screen buffer — when no client is
attached; the client tiles them tmux-style in xterm.js panes and repaints
each one from a snapshot on reattach.

There is no browser deployment: the UI ships inside the Electron client
(`electron/`), which serves it locally and reaches the server's unix socket
through a supervised SSH tunnel. Only API and WebSocket traffic crosses the
wire, and the host needs nothing but sshd — connecting pushes the server
there.

## Architecture

```
macOS: Electron client (electron/)
  main.js ── per profile: ssh -N -L 127.0.0.1:<port>:<remote http socket> <host>
     │       + one WebContentsView loading webmux://<host-slug>/?port=<port>
     │         (ui/ + @xterm served from the app bundle)
     └── header strip: one pill per connected host (⌘1…⌘9), Connections page
                                │  /api/* and /ws over the tunnel
remote host: ~/.webmux/dist     ▼
  server.js ── thin, restartable: JSON API + WebSocket termination
     │          unix socket $XDG_RUNTIME_DIR/webmux/<name>.http.sock (0600)
     └── ptyhost.js ── long-lived daemon owning the shells
                       unix socket $XDG_RUNTIME_DIR/webmux/<name>.sock
```

- **Pty host** (`ptyhost.js`): owns the sessions. Each pairs a PTY
  (`node-pty`) with a headless terminal (`@xterm/headless`); all PTY output
  is mirrored into the headless terminal, so buffer, cursor, colors, and
  modes live in the daemon. It speaks newline-delimited JSON that mirrors
  the WebSocket protocol, runs detached, and stops only on an explicit
  shutdown — restarting or upgrading anything else never kills a shell.
- **Server** (`server.js`): a thin proxy between WebSockets and the pty
  host plus a small JSON API (sessions, file browser, clipboard/paste
  shims, browser-open relay). It listens on a unix socket only — filesystem
  permissions and sshd are the whole access story; no TCP port, no TLS, no
  auth. It spawns the pty host on demand at startup and writes an advert
  (`~/.webmux/<name>.json`: socket path, payload hash, pid) that the client
  reads to know where to tunnel. This is where feature churn lands, and it
  is replaced freely: the client pushes a new one on connect whenever the
  bundled payload hash differs (`docs/push-deploy.md`).
- **Client** (`electron/`): `main.js` supervises one ssh tunnel per
  connected profile, hosts the header strip and the connection manager
  (client-owned pages — a remote server never learns about other hosts),
  and serves the frontend on the `webmux://` scheme. `ui/app.js` is the
  frontend: a tmux-style split layout (binary tree of panes with
  drag-resizable dividers), tabbed panes, one xterm.js per terminal tab on
  its own WebSocket. The fit addon reports pane sizes back; the server
  resizes both the PTY and the headless mirror. The layout tree lives in
  localStorage keyed by the `webmux://<host-slug>` origin, so each client
  keeps its own arrangement per host, matching its own screen.
- **Persistence**: on every attach the pty host serializes the headless
  buffer (`@xterm/addon-serialize`) and sends it as a `snapshot`; the client
  renders exactly what the session looks like now, scrollback included.

Design notes: `docs/electron-client.md` (client, tunnel supervision,
liveness), `docs/push-deploy.md` (connect-is-deploy flow),
`docs/restart-resilience.md` (why the pty host exists).

## Build and run

```sh
make client-deps   # cd electron && npm install
make client        # harness → server payload → electron/dist/webmux-<version>-arm64-mac.zip
```

`make client` cross-builds from Linux (no native modules in the client).
The zip is unsigned: unzip, then right-click → Open once, or
`xattr -dr com.apple.quarantine webmux.app`.

In the app: **Connections** (⌘⇧O) → add a profile — a name and an ssh host,
optionally port, identity file, extra ssh options, a saved password
(Keychain-encrypted; otherwise key auth via BatchMode), and an instance
name — then **Connect**. The first connect to a host pushes a node runtime
(~25 MB, cached locally per platform) and the server payload over ssh,
starts the server, and tunnels to it; later connects reuse what's there.
Several hosts can be connected at once; pills in the header (drag to
reorder) or ⌘1…⌘9 switch between them. ⌘⇧R reconnects the current host.

Instances: a profile's instance name (blank = `default`) selects which
named server/pty-host pair it talks to. Distinct instances on one host are
fully independent — own sockets, own sessions — so several webmux setups
can coexist.

### Connection resilience

Sessions survive everything short of a pty-host shutdown: tunnel drops,
laptop sleep, network changes, and server upgrades all just detach the
socket, and reattach replays a snapshot. On the client side:

- ssh runs with keepalives (`ServerAliveInterval=10`, `CountMax=2`, so a
  dead link is noticed within ~30 s) and with `ControlMaster` forced off, so
  a mux master from `~/.ssh/config` can't defeat them.
- main.js probes the server through the tunnel every 5 s for as long as the
  tunnel is up. A dead or restarted remote server (or a half-open link)
  fails three probes in a row, which kills the tunnel and triggers the
  retry path — and every retry re-runs the deploy step, which restarts a
  dead server before tunnelling again.
- Auto-retry (backoff 1 s → 15 s) only happens for a connection that was
  established and then interrupted. A connect that never succeeded (typo'd
  host, wrong password) parks as *failed* with ssh's stderr and waits for
  you; nothing churns in the background while you edit profiles.
- Lid-open kills pre-sleep tunnels immediately rather than waiting out the
  keepalives.
- The page itself marks its title `· offline` while any session socket is
  down and retrying; the client shows that as an amber *degraded* pill, so
  the chrome never claims "connected" over a terminal that says
  "disconnected".

### Running the server by hand (development)

```sh
npm install   # needs make + g++ for node-pty
npm start     # listens on $XDG_RUNTIME_DIR/webmux/default.http.sock
```

Useful for hacking on `server.js`/`ptyhost.js` locally — poke it with
`curl --unix-socket $XDG_RUNTIME_DIR/webmux/default.http.sock http://localhost/api/sessions`.
Note that the client replaces a hand-started server with its bundled
payload on the next connect. Config is env vars only (a deployed payload
has no config file):

- `WEBMUX_PTYHOST=<name>` picks which pty host the server fronts (default
  `default`).
- `WEBMUX_SOCKET=/path/to.sock` overrides the http socket path.

### Pty host lifecycle

The server spawns the named pty host if it isn't running (detached, logging
to `$XDG_RUNTIME_DIR/webmux/<name>.log`). Killing or restarting the server
leaves the host — and every shell in it — running; clients reconnect on
their own. The host only stops on an explicit shutdown:

```sh
npm run stop                        # shut down the default host (kills its shells)
node ptyhost.js --name X shutdown   # shut down a specific host
node ptyhost.js --name X list       # list a host's sessions
node ptyhost.js --name X            # run a host standalone in the foreground
```

On a deployed host these run under the pushed node:
`~/.webmux/dist/node/<platform>/bin/node ~/.webmux/dist/payload/<hash>/ptyhost.js …`.

## Using the layout

- **+ New terminal** / **+ Files** in the header open a tab in the focused
  pane (`POST /api/sessions` for terminals); **+** on a pane's tab bar does
  the same for that pane.
- **↔ / ↕** on a pane split it side-by-side / stacked with a new terminal.
  Shift-click moves the pane's current tab into the new split instead.
- Drag tabs between panes or reorder them within one; drag the divider
  between panes to resize. Dropping never creates a split.
- **✕** on a tab closes it — for terminals that kills the session
  (`DELETE /api/sessions/:id`); a shell exiting closes its tab on its own.
- ⌘R reloads the page: live sessions reattach with state and layout intact.
- Click a URL in a terminal (plain text, via `@xterm/addon-web-links`, or an
  OSC 8 hyperlink such as Claude Code's `/login` link) for a chooser: open
  it in your default browser or copy it. Shift-click opens without asking.
- Programs that try to launch a browser on the host (`xdg-open`,
  `sensible-browser`, `x-www-browser`, `$BROWSER` — e.g. `gh pr view --web`,
  OAuth logins) hit shims in `shims/` instead: the URL is spooled to the
  server, which forwards it to the client viewing that session
  (`WEBMUX_SESSION`), and the same chooser pops up there.

## File browser

Panes aren't limited to terminals: **+ Files** opens a Finder-style
Miller-columns file browser tab (one column per directory level, rooted at
`/`, starting in `$HOME`). Click to drill down, or navigate with the arrow
keys / `hjkl` like yazi. Selecting a file shows a preview column — text
(first 64 KB), images, or size/mtime for binaries — via `GET /api/fs/list`,
`/api/fs/preview`, and `/api/fs/raw`. Files or folders dragged onto a column
upload into that column's directory — multiple at once is fine, and folders
recreate their directory tree (empty subdirectories are skipped). Files or
images pasted while the browser is focused upload into the rightmost
directory shown (`POST /api/fs/upload`, colliding names deduped
Finder-style). The selected entry can be renamed (`r`/`F2`, inline,
`POST /api/fs/rename`) or deleted (`d`/`Delete`, after a confirmation —
directories recursively; `POST /api/fs/delete`), via keyboard or the ✎/✕
buttons on the row. Browser tabs are client-side widgets (no server
session) implemented in `electron/ui/files-widget.js`; their path and
cursor persist in localStorage alongside the layout, and they drag between
panes like any other tab.

## Protocol

WebSocket at `/ws?session=<id>`, JSON messages; the pty host speaks the
same frames over its unix socket, and server.js forwards them verbatim.

| direction | type | payload |
|---|---|---|
| server → client | `snapshot` | serialized buffer + cols/rows + title + shell pid (sent on attach) |
| server → client | `output` | raw PTY output |
| server → client | `title` | this session's terminal title changed (OSC 0/2) |
| server → client | `session-title` | any session's title changed — fanned out on every open socket so background tabs stay current |
| server → client | `exit` | shell exit code |
| server → client | `error` | session doesn't exist (the tab is dropped) |
| server → client | `paste-result` | how a pasted image was delivered (`claude` or `path`) |
| server → client | `open-url` | a program in the session asked for a browser (see shims) |
| client → server | `input` | keystrokes |
| client → server | `resize` | cols/rows |
| client → server | `paste-image` | base64 image for the clipboard slot |
| client → server | `clipboard-sync` | base64 image copied on the client, mirrored into the slot |

Tabs are labeled with the terminal title when the running program sets one
(OSC 0/2, e.g. shell prompts or vim), tracked in the pty host so titles
survive reattach. Programs copying via OSC 52 write through to the client's
clipboard (see below); clipboard *reads* via OSC 52 are ignored.

## Copying to the system clipboard (OSC 52)

Any program that copies via OSC 52 (vim/neovim clipboard providers, Claude
Code's copy actions, `tmux set-buffer -w`) lands on the Mac's clipboard: the
escape sequence travels through the PTY to the client unmodified, and the
page writes it with `navigator.clipboard.writeText` (the `webmux://` scheme
is registered as secure, so the API is available).

**Running tmux inside a webmux pane** needs one line of tmux config to pass
copies through:

```tmux
set -s set-clipboard on
```

tmux intercepts OSC 52 from its inner programs rather than forwarding it.
What reaches webmux depends on `set-clipboard` (verified with tmux 3.5a):

| `set-clipboard` | action inside tmux | tmux buffer | forwarded to webmux |
|---|---|---|---|
| `on` | program emits OSC 52 | ✅ | ✅ |
| `external` (default) | program emits OSC 52 | ❌ dropped | ❌ |
| `on` / `external` | `tmux set-buffer -w` / copy-mode copy | ✅ | ✅ |
| `on` / `external` | `tmux set-buffer` (no `-w`) | ✅ | ❌ |

So with the default `external`, a copy from e.g. Claude Code running inside
tmux is silently discarded; with `on`, tmux stores it as a buffer *and*
re-emits the OSC 52 outward, where webmux picks it up.

One more prerequisite (satisfied on most systems): tmux only forwards if the
outer terminal's terminfo advertises the `Ms` capability. webmux sessions run
with `TERM=xterm-256color`, whose standard terminfo entry includes it; if
yours doesn't (`infocmp -x xterm-256color | grep Ms` prints nothing), add:

```tmux
set -as terminal-overrides ',xterm-256color:Ms=\E]52;%p1%s;%p2%s\007'
```

## Image paste

Pasting an image into a pane uploads it to the server, which writes it to the
"clipboard slot" served by the `xclip`/`xsel` shims in `shims/` (prepended to
each session's PATH). Then:

- If the pane's foreground process is Claude Code, the raw Ctrl+V byte is
  forwarded — Claude reads "the clipboard" via the shim and attaches the image
  natively.
- Otherwise the image's temp-file path is typed at the prompt.

Foreground detection reads the shell's tpgid from `/proc` and checks whether
the process's argv looks like `claude`.

Ctrl+V is suppressed at the xterm key-handler level (xterm would otherwise
send a bare `^V`) and the client reads the clipboard through
`navigator.clipboard.read()`: image → upload flow, text → xterm's normal
paste, empty → a literal `^V`. Ctrl+Alt+V always sends a literal `^V` (vim
visual-block). The clipboard image is also proactively synced to the server
slot on window focus (there is no clipboardchange event), so a plain ⌘V
into Claude Code finds it too.

## Repository layout

```
electron/        macOS client: main.js (tunnels, views, IPC), deploy.js (push flow),
                 connect.html / header.html (client-owned pages), ui/ (the frontend),
                 test/harness.js (headless state-machine tests), payload/ (built)
server.js        remote API + WebSocket proxy (pushed to hosts as part of the payload)
ptyhost.js       pty daemon; ptyhost-client.js is its control-socket client
deploy/          build-payload.js (server tarball), remote-start.js (runs on the host)
shims/           xdg-open / xclip / xsel … stand-ins put on each session's PATH
docs/            design notes
Makefile         deps · start · stop · payload · client-deps · client-test · client
```

Known limitations: one shared size per session (the last attached client's
resize wins), sessions die with the pty host process (no on-disk
persistence), and the clipboard slot is global (one clipboard for all panes,
like a real desktop).
