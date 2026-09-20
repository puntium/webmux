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
  frontend: a scrolling column layout in the style of niri / PaperWM (a
  horizontal strip of columns, each a stack of panes, keyboard-driven), one
  xterm.js per terminal pane on its own WebSocket. The fit addon reports pane sizes back; the server
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

`make client` cross-builds from Linux (no native modules in the client)
and signs the app there with [rcodesign](https://github.com/indygreg/apple-platform-rs)
if it is on PATH — with the certificate at `SIGN_PEM`
(`~/.config/webmux/codesign.pem` by default; the Makefile shows how to
generate a self-signed one) for an identity that stays the same across
builds, ad-hoc otherwise. Signing is not cosmetic: macOS 26.5+/27
identifies an app by its code signature for Local Network privacy and
Keychain access, and an app it cannot validate is silently denied every LAN
connection (`ssh: No route to host`) even with its toggle on. Install:

```sh
# unzip, drag webmux.app to /Applications in Finder (the drag is what
# defeats App Translocation), then clear the download quarantine:
xattr -dr com.apple.quarantine /Applications/webmux.app
```

First launch asks for Local Network access (allow it) and Keychain access
to the saved-password store (Always Allow). With a certificate-signed build
that happens once; an ad-hoc build is a new identity every time, so it asks
again after each update. The build refuses to run without rcodesign rather
than ship an unsigned app that would install fine and then fail every
connection. `make client APP_ID=me.example.webmux2` builds under another bundle
identifier, which macOS treats as a brand-new app. The zip keeps the
bundle's symlinks (electron-builder's own zip target flattens them on
Linux, which breaks the frameworks' layout so badly that codesign refuses
the app — see `electron/pack-mac.js`).

In the app: **Connections** (⌘⇧O) → add a profile — a name and an ssh host,
optionally port, identity file, extra ssh options, a saved password
(Keychain-encrypted; otherwise key auth via BatchMode), and an instance
name — then **Connect**. The first connect to a host pushes a node runtime
(~25 MB, cached locally per platform) and the server payload over ssh,
starts the server, and tunnels to it; later connects reuse what's there.
Several hosts can be connected at once; pills in the header (drag to
reorder), ⌘1…⌘9, or ⌘⇧[ / ⌘⇧] (previous / next) switch between them. ⌘⇧R
reconnects the current host.

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
- macOS Local Network privacy (macOS 15+, stricter on 26.5+/27) gates ssh
  to LAN hosts (`.local` names, RFC 1918 / link-local addresses) behind a
  per-app grant, and a denied connect fails instantly with `No route to
  host`. The grant is attributed per process, and Electron helper processes
  get their own entries, so the prompt can land on the wrong one and leave
  the ssh children denied. Before the first ssh to a LAN host per app run,
  main.js opens and closes one TCP connection to it from its own process
  (`lan.js`), so the prompt is attributed to the process that owns the ssh
  children. A denied probe (or, for a `.local` name, a failed lookup — mDNS
  is gated too) holds the attempt for up to 20 s while the prompt is up, so
  clicking Allow lets that same connect proceed. If ssh still reports `No
  route to host`, the connection page says so in those words and points at
  System Settings › Privacy & Security › Local Network instead of showing a
  bare exit code, and the parked connection keeps probing for three minutes
  and reconnects by itself once a connection goes through.
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
- `WEBMUX_SOCKET=/path/to.sock` overrides the http socket path. Such a run
  is a dev server on a private socket and does not write the advert.

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

The workspace is a horizontal strip of **columns**, each a vertical stack of
one or more **panes** (a terminal or a file browser), like niri or PaperWM.
Column widths follow two settings, in characters: *Minimum terminal width*
(default 90) and *Maximum terminal width* (default 200). As many columns as
fit the window at the minimum share it exactly, so a wide window shows
three, four or five whole columns; fewer columns than that grow to share
the window up to the maximum and sit centred; open more and the strip
scrolls sideways, following the focused pane. The focused pane wears an
accent border; its title bar spans the pane's width.

| Keys | Action |
| --- | --- |
| ⌘↩ / ⌘⇧↩ | new terminal / new file browser, as a new column right of the focused one (`POST /api/sessions` for terminals) |
| ⌥⌘↩ | new terminal stacked directly below the focused pane |
| ⌘W | close the focused pane (kills a terminal's session, no confirmation) |
| ⌘F | toggle the focused pane to the whole window; a stacked pane first splits out into its own column |
| ⌘← → ↑ ↓ or ⌘h j k l | move focus between columns / within a stack (each column remembers its active pane) |
| ⇧⌘← → | a pane sharing a column splits out into its own column on that side; a pane alone in its column moves the whole column left / right |
| ⇧⌘↑ ↓ or ⌥⌘↑ ↓ | move the pane up / down within its stack |
| ⌥⌘← → | merge the pane into the neighbouring column on that side (leaving its stack in one step; a column it empties goes away); with no column there, a stacked pane splits out instead |

The same commands sit in the client's **Pane** menu. In the client, ⌘H /
⌥⌘H (Hide) and ⌘⇧L (Connection Log, now ⌃⌘L) gave up their shortcuts to
make room for the vim keys. Other pointers:

- **+ New terminal** / **+ Files** in the header do what ⌘↩ / ⌘⇧↩ do.
- Drag the divider between stacked panes to resize them; widths follow the
  column rule. Two-finger horizontal scrolling pans the strip.
- **✕** in a pane's title bar closes it — for terminals that kills the
  session (`DELETE /api/sessions/:id`); a shell exiting closes its pane on
  its own. A closing column shrinks away and its neighbours slide in; a
  closing stacked pane collapses while the rest of its stack grows into
  its place from above and below. Focus moves to the next pane in the
  stack, else to a neighbour.
- ⌘R reloads the page: live sessions reattach with state and layout intact.
  Sessions opened elsewhere (another client) appear as columns on the right.
- **⚙** in the header (⌘, in the client) opens the settings panel: the color
  scheme (*Dark mode default* or *Light mode*), how much unfocused panes
  fade, and the minimum and maximum terminal widths. These are client-wide — the client keeps them in its `config.json`
  and every connected host page follows a change at once (the page reads and
  writes them at `/settings.json` on its own `webmux://` origin; served
  directly by the server instead, they fall back to localStorage).
- **Open log…** in that panel (also ⌘⇧L, the *Log* button on the
  connection page, or *Connection Log…* in the app menu) opens the client's
  connection log: every tunnel setup, deploy step, probe miss, tunnel exit,
  retry, and — reported by each host page over `POST /log` on its own
  origin — every session-socket drop and reconnect. Live tail, filter by
  host/level/text, *Copy visible* / *Copy all* for pasting into a bug
  report; the same lines go to `<userData>/logs/webmux.log` (rotated at
  1 MB). Passwords never appear — only which auth mode was used.
- Click a URL in a terminal (plain text, via `@xterm/addon-web-links`, or an
  OSC 8 hyperlink such as Claude Code's `/login` link) to open it in your
  default browser. Shift-click copies it to the clipboard instead.
- Programs that try to launch a browser on the host (`xdg-open`,
  `sensible-browser`, `x-www-browser`, `$BROWSER` — e.g. `gh pr view --web`,
  OAuth logins) hit shims in `shims/` instead: the URL is spooled to the
  server, which forwards it to the client viewing that session
  (`WEBMUX_SESSION`), which pops up an open/copy chooser.

## File browser

Panes aren't limited to terminals: **+ Files** opens a Finder-style
Miller-columns file browser pane (one column per directory level, rooted at
`/`, starting in `$HOME`). Click to drill down, or navigate with the arrow
keys / `hjkl` like yazi; drilling back into a directory visited earlier in
the session re-selects the entry the cursor was on there. The pane's title
bar shows the path to the selection (`$HOME` as `~`), collapsing parent
directories to `…` before it would cut into the file name. Columns size
themselves to their longest name (200–420 px). Selecting a file shows a
preview column — text (first 64 KB), images, a zip's table of contents as
a `tree`-style listing (read from the central directory, nothing
inflated), or just size/mtime in a narrow column for binaries — via
`GET /api/fs/list`, `/api/fs/preview`, and `/api/fs/raw`. `→` on a file
drills into its preview: the header takes the selection highlight and
`↑`/`↓` (PageUp/PageDown, Home/End) scroll the content; `←` steps back
to the listing. Listings stay live: the cursor's directory and the
folder it points at are watched (`GET /api/fs/watch`, a server-sent-events
stream over `fs.watch`) and re-list on change, and a pane regaining focus
re-lists every column shown. Markdown files render by default
(client-side, via `marked`, with raw HTML shown as text) with a Rendered /
Source toggle in the preview header; relative images load through
`/api/fs/raw`, web links open in the browser (shift-click copies), and
relative links navigate the browser to that entry. The preview header's ⤓
button (or `D`) downloads the file to the local machine (`/api/fs/raw?download=1`
serves it as an attachment; the Electron client shows the usual save
dialog and notes the outcome in the connection log). Files or folders dragged onto a column
upload into that column's directory — multiple at once is fine, and folders
recreate their directory tree (empty subdirectories are skipped). Files or
images pasted while the browser is focused upload into the rightmost
directory shown (`POST /api/fs/upload`, colliding names deduped
Finder-style). The selected entry can be renamed (`r`/`F2`, inline,
`POST /api/fs/rename`) or deleted (`d`/`Delete`, after a confirmation
centred in the pane — directories recursively; `POST /api/fs/delete`), via keyboard or the ✎/✕
buttons on the row. Browser panes are client-side widgets (no server
session) implemented in `electron/ui/files-widget.js`; their path and
cursor persist in localStorage alongside the layout, and they move around
the strip like any other pane.

## Protocol

WebSocket at `/ws?session=<id>`, JSON messages; the pty host speaks the
same frames over its unix socket, and server.js forwards them verbatim.

| direction | type | payload |
|---|---|---|
| server → client | `snapshot` | serialized buffer + cols/rows + title + shell pid (sent on attach) |
| server → client | `output` | raw PTY output |
| server → client | `title` | this session's terminal title changed (OSC 0/2) |
| server → client | `session-title` | any session's title changed — fanned out on every open socket so every pane stays current |
| server → client | `exit` | shell exit code |
| server → client | `error` | session doesn't exist (the pane is dropped) |
| server → client | `paste-result` | how a pasted image was delivered (`claude` or `path`) |
| server → client | `open-url` | a program in the session asked for a browser (see shims) |
| client → server | `input` | keystrokes |
| client → server | `resize` | cols/rows |
| client → server | `paste-image` | base64 image for the clipboard slot |
| client → server | `clipboard-sync` | base64 image copied on the client, mirrored into the slot |

Panes are titled with the terminal title when the running program sets one
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
                 lan.js (macOS Local Network probe + hint), connect.html /
                 header.html (client-owned pages), ui/ (the frontend), test/
                 (headless harness + lan.js unit tests), pack-mac.js (symlink-
                 keeping zip of the signed .app), payload/ (built)
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
