# webmux

A quick prototype: multiple tiled xterm.js terminal sessions in the browser, with
**persistent server-side state** — sessions keep running and keep their full screen
buffer when no browser is attached.

## How it works

- **Server** (`server.js`): each session pairs a PTY (`node-pty`) with a headless
  terminal (`@xterm/headless`). All PTY output is mirrored into the headless
  terminal, so the buffer, cursor, colors, and modes live on the server.
- **Persistence**: when a client attaches (or the page reloads), the server
  serializes the headless buffer with `@xterm/addon-serialize` and sends it as a
  `snapshot` — the client renders exactly what the session looks like now,
  including scrollback.
- **Client** (`public/`): a tmux-style split layout — a binary tree where leaves
  are panes and internal nodes are horizontal/vertical splits with a drag-resizable
  divider. One xterm.js instance per pane, each on its own WebSocket. The fit
  addon reports pane resizes back to the server, which resizes both the PTY and
  the headless terminal. The layout tree is saved to localStorage, so a reload
  restores the arrangement and the headless snapshots restore each screen.

## Run

```sh
npm install   # needs make + g++ for node-pty
npm start     # http://localhost:5000 (override with PORT=...)
```

Optional config lives in `config.yaml` (gitignored; copy
`config.example.yaml`). An `auth` section with `username` and `password`
enables HTTP Basic auth on everything — pages, API, and WebSocket upgrades;
without it the server is open. Plain http sends Basic credentials in the
clear, so put anything non-local behind TLS.

- **+ New terminal** adds a pane by splitting the whole layout (`POST /api/sessions`).
- **↔ / ↕** on a pane splits it side-by-side / stacked with a new session.
- Drag the divider between panes to resize them.
- **✕** on a pane kills that session (`DELETE /api/sessions/:id`).
- Reload the page: all live sessions reattach with state and layout intact.

## File browser

Panes aren't limited to terminals: **+ Files** in the header opens a
Finder-style Miller-columns file browser tab (one column per directory level,
rooted at `/`, starting in `$HOME`) in the focused pane. Click to drill down,
or navigate with the arrow keys / `hjkl` like yazi. Selecting a file shows a
preview column — text (first 64 KB), images, or size/mtime for binaries — via
`GET /api/fs/list`, `/api/fs/preview`, and `/api/fs/raw`. Files dragged onto
a column upload into that column's directory, and files or images pasted
while the browser is focused upload into the rightmost directory shown
(`POST /api/fs/upload`, colliding names deduped Finder-style). Browser tabs
are client-side widgets (no server session) implemented in
`public/files-widget.js`; their path and cursor persist in localStorage
alongside the layout, and they drag between panes like any other tab.

## Protocol

WebSocket at `/ws?session=<id>`, JSON messages:

| direction | type | payload |
|---|---|---|
| server → client | `snapshot` | serialized buffer + cols/rows (sent on attach) |
| server → client | `output` | raw PTY output |
| server → client | `exit` | shell exit code |
| client → server | `input` | keystrokes |
| client → server | `resize` | cols/rows |

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
the native paste event that follows carries the clipboard (works on plain
http, no permission needed): image → upload flow, text → xterm's normal
paste. If no paste event follows (macOS, where Ctrl+V isn't a paste
shortcut), the client falls back to `navigator.clipboard.read()`, which needs
a secure context (localhost/https) plus clipboard permission. Ctrl+Alt+V
sends a literal `^V` (vim visual-block). The clipboard image is also
proactively synced to the server slot on window focus where the async API is
available (browsers have no clipboardchange event).

Prototype caveats: one shared resize (last attached client wins),
sessions die with the server process (no on-disk persistence), and the
clipboard slot is global (one clipboard for all panes, like a real desktop).
