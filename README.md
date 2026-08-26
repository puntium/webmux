# webmux

A quick prototype: multiple tiled xterm.js terminal sessions with
**persistent server-side state** — sessions keep running and keep their full
screen buffer when no client is attached. The UI is a web frontend, but it is
served over a unix socket and reached through the macOS Electron client
(`electron/`), which tunnels the socket over SSH — there is no browser/TCP
deployment mode.

## How it works

- **Pty host** (`ptyhost.js`): a small long-lived daemon that owns the shells.
  Each session pairs a PTY (`node-pty`) with a headless terminal
  (`@xterm/headless`); all PTY output is mirrored into the headless terminal,
  so the buffer, cursor, colors, and modes live in the daemon. It listens on a
  named unix socket (`$XDG_RUNTIME_DIR/webmux/<name>.sock`) speaking
  newline-delimited JSON that mirrors the WebSocket protocol.
- **Web server** (`server.js`): a thin restartable proxy — static files and
  WebSocket termination, forwarding frames to the pty host. It listens on a
  unix socket of its own (`$XDG_RUNTIME_DIR/webmux/<name>.http.sock`, 0600 in
  a 0700 dir), so filesystem permissions are the whole access story — no TCP
  port, no TLS, no auth. It spawns the host on demand at startup (detached),
  so restarting or killing the web server never kills a shell; the client
  reconnects with backoff and repaints from a fresh snapshot. Nearly all code
  churn is in the server/frontend, so in practice the host almost never needs
  restarting.
- **Persistence**: when a client attaches (or the page reloads), the host
  serializes the headless buffer with `@xterm/addon-serialize` and sends it as a
  `snapshot` — the client renders exactly what the session looks like now,
  including scrollback.
- **Client** (`public/`): a tmux-style split layout — a binary tree where leaves
  are panes and internal nodes are horizontal/vertical splits with a drag-resizable
  divider. One xterm.js instance per pane, each on its own WebSocket. The fit
  addon reports pane resizes back to the server, which resizes both the PTY and
  the headless terminal. The layout tree is saved to localStorage — keyed by
  origin, so each client keeps its own layout per host, matching its own
  screen — and a reload restores the arrangement while the headless
  snapshots restore each screen.

## Run

```sh
npm install   # needs make + g++ for node-pty
npm start     # listens on $XDG_RUNTIME_DIR/webmux/default.http.sock
```

The server listens on a unix socket only. To use it, connect from a Mac with
the Electron client (see below); for a quick local check,
`curl --unix-socket $XDG_RUNTIME_DIR/webmux/default.http.sock http://localhost/api/sessions`.

Optional config lives in `config.yaml` (gitignored; copy
`config.example.yaml`):

- `ptyhost: <name>` picks which pty host the server fronts (default
  `default`; env `WEBMUX_PTYHOST` overrides). Different names are fully
  independent daemons — own pty socket, own http socket
  (`<name>.http.sock`) — so several webmux instances can run side by side.
- `socket: /path/to.sock` overrides the http socket path.

### macOS client (Electron over SSH)

`electron/` holds the native macOS client: an Electron shell that forwards a
local port to the server's remote unix socket over a supervised SSH tunnel
(`ssh -L 127.0.0.1:<port>:<remote socket> host`) — no exposed port anywhere;
your SSH key is the front door. Connecting **is** deploying: the client
pushes a node runtime and the server itself to the host over ssh (the host
needs nothing but sshd) and keeps it up to date, so a profile is just a
name and an ssh host — there is no server to install or start manually.
Several hosts can be connected at once — each gets a pill in the client's
header strip (⌘1…⌘9 switch between them). Sessions survive disconnects and
server updates alike (they live in the pty host), and the client reconnects
automatically on network drops and laptop wake.
Design and setup: `docs/electron-client.md`; deploy flow: `docs/push-deploy.md`.

### Pty host lifecycle

`npm start` spawns the named pty host automatically if it isn't running
(detached, logging to `$XDG_RUNTIME_DIR/webmux/<name>.log`). Killing or
restarting the web server leaves the host — and every shell in it — running;
open pages reconnect on their own. The host only stops on an explicit
shutdown:

```sh
npm run stop                        # shut down the default host (kills its shells)
node ptyhost.js --name X shutdown   # shut down a specific host
node ptyhost.js --name X list       # list a host's sessions
node ptyhost.js --name X            # run a host standalone in the foreground
```

- **+ New terminal** adds a pane by splitting the whole layout (`POST /api/sessions`).
- **↔ / ↕** on a pane splits it side-by-side / stacked with a new session.
- Drag the divider between panes to resize them.
- **✕** on a pane kills that session (`DELETE /api/sessions/:id`).
- Reload the page: all live sessions reattach with state and layout intact.
- Click a URL in a terminal (underlined on hover, via `@xterm/addon-web-links`)
  to get a chooser: copy it to the clipboard or open it in a new browser tab.
- Programs that try to launch a browser (`xdg-open`, `sensible-browser`,
  `x-www-browser`, `$BROWSER` — e.g. `gh pr view --web`, OAuth logins) hit
  shims in `shims/` instead: the URL is spooled through the paste dir to the server,
  which forwards it to the client viewing that session (`WEBMUX_SESSION`),
  and the same copy/open chooser pops up there.

## File browser

Panes aren't limited to terminals: **+ Files** in the header opens a
Finder-style Miller-columns file browser tab (one column per directory level,
rooted at `/`, starting in `$HOME`) in the focused pane. Click to drill down,
or navigate with the arrow keys / `hjkl` like yazi. Selecting a file shows a
preview column — text (first 64 KB), images, or size/mtime for binaries — via
`GET /api/fs/list`, `/api/fs/preview`, and `/api/fs/raw`. Files or folders
dragged onto a column upload into that column's directory — multiple at
once is fine, and folders recreate their directory tree (empty
subdirectories are skipped). Files or images pasted while the browser is
focused upload into the rightmost directory shown (`POST /api/fs/upload`,
colliding names deduped Finder-style). The selected entry can be renamed
(`r`/`F2`, inline, `POST /api/fs/rename`) or deleted (`d`/`Delete`, after a
confirmation — directories recursively; `POST /api/fs/delete`), via keyboard
or the ✎/✕ buttons on the row. Browser tabs
are client-side widgets (no server session) implemented in
`public/files-widget.js`; their path and cursor persist in localStorage
alongside the layout, and they drag between panes like any other tab.

## Protocol

WebSocket at `/ws?session=<id>`, JSON messages:

| direction | type | payload |
|---|---|---|
| server → client | `snapshot` | serialized buffer + cols/rows + title (sent on attach) |
| server → client | `output` | raw PTY output |
| server → client | `title` | terminal title change (OSC 0/2) — shown on the tab |
| server → client | `exit` | shell exit code |
| client → server | `input` | keystrokes |
| client → server | `resize` | cols/rows |

Tabs are labeled with the terminal title when the running program sets one
(OSC 0/2, e.g. shell prompts or vim), tracked server-side so titles survive
reattach. Programs copying via OSC 52 write through to the browser's
clipboard (see below); clipboard *reads* via OSC 52 are ignored.

## Copying to the system clipboard (OSC 52)

Any program that copies via OSC 52 (vim/neovim clipboard providers, Claude
Code's copy actions, `tmux set-buffer -w`) lands on the browser's system
clipboard: the escape sequence travels through the PTY to the client
unmodified, and the browser-side handler writes it with
`navigator.clipboard.writeText`. The write needs the tab to be focused and a
secure context — satisfied in the Electron client, whose page origin is
`http://127.0.0.1:<port>` (localhost counts).

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
send a bare `^V`), but the browser default is left alone — on Windows/Linux
the native paste event that follows carries the clipboard (no permission
needed): image → upload flow, text → xterm's normal paste. If no paste event
follows (macOS, where Ctrl+V isn't a paste shortcut), the client falls back
to `navigator.clipboard.read()`, which needs clipboard permission plus a
secure context (the `http://127.0.0.1` tunnel origin qualifies). Ctrl+Alt+V
sends a literal `^V` (vim visual-block). The clipboard image is also
proactively synced to the server slot on window focus where the async API is
available (browsers have no clipboardchange event).

Prototype caveats: one shared resize (last attached client wins),
sessions die with the pty host process (no on-disk persistence), and the
clipboard slot is global (one clipboard for all panes, like a real desktop).
