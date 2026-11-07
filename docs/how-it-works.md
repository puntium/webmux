# How webmux works

The moving parts, what each owns, and how they talk. Deeper notes on each
part live in their own documents, linked where relevant.

## Topology

```
your machine: a client (electron/ or gtk/)
  per profile: ssh -N -L 127.0.0.1:<port>:<remote http socket> <host>
     │         one view / workspace per connected host
     │         Electron: webmux://<host-slug>/?port=<port> serving ui/ + @xterm from the app bundle
     │         GTK:      Ghostty's terminal core, fed straight from the WebSocket
     └── header: one pill per connected host, Connections page (client-owned — a host never learns about other hosts)
                                │  /api/* and /ws over the tunnel; nothing else crosses the wire
remote host: ~/.webmux/dist/payload/<hash>/webmux-host (one static binary)
                                ▼
  webmux-host serve ── thin, restartable: JSON API + WebSocket termination
     │          unix socket $XDG_RUNTIME_DIR/webmux/<name>.http.sock (0600)
     └── webmux-host ptyhost ── long-lived daemon owning the shells
                       unix socket $XDG_RUNTIME_DIR/webmux/<name>.sock
```

There is no browser deployment and no TCP listener: the server listens on
a unix socket only, so filesystem permissions and `sshd` are the whole
access story — no port, no TLS, no auth of its own. The UI ships inside
the client. The host needs nothing installed: connecting pushes the server
there ([push-deploy.md](push-deploy.md)).

## Components

### Pty host (`webmux-host ptyhost`, `host/internal/ptyhost`)

Owns the sessions. Each session pairs a PTY with a headless terminal
(libghostty-vt); all PTY output is mirrored into the headless terminal,
so buffer, cursor, colours, modes and the title live in the daemon, not in
any client. It speaks newline-delimited JSON over its unix socket that
mirrors the WebSocket protocol below, runs detached, logs to
`$XDG_RUNTIME_DIR/webmux/<name>.log`, and stops only on an explicit
`shutdown` — restarting or upgrading anything else never kills a shell.
Why it exists as a separate process: [restart-resilience.md](restart-resilience.md).

Sessions run with `TERM=xterm-256color`, `PATH` prefixed with the shims
directory, `WEBMUX_SESSION` and `WEBMUX_CLIPBOARD_DIR` set, `BROWSER`
pointing at the shim, and any inherited `TMUX*` variables removed.

### Server (`webmux-host serve`, `host/internal/server`)

A thin proxy between WebSockets and the pty host, plus a small JSON API:
sessions (`/api/sessions`), the file browser (`/api/fs/*`), the clipboard
and paste shims, and the browser-open relay. It spawns the named pty host
on demand at startup and writes an advert (`~/.webmux/<name>.json`:
socket path, payload hash, pid) that the client reads to know where to
tunnel. This is where feature churn lands, and it is replaced freely: the
client pushes a new one on connect whenever the bundled payload hash
differs, and the pty host — and every shell in it — carries on.

Both halves are one statically linked Go binary per architecture
(`linux-x64`, `linux-arm64`; glibc and musl hosts alike) with libghostty-vt
as the terminal mirror: [native-host.md](native-host.md). The node files at
the repo root — `server.js`, `ptyhost.js`, `ptyhost-client.js`,
`deploy/remote-start.js` — are the legacy implementation it was ported
from. They stay in the tree as the reference the port is tested against,
speak the same protocols, and interoperate with it in both directions
(a pty host started by the node payload keeps its sessions when the first
native payload replaces its server), but no client pushes them any more.

### Clients

**Electron** (`electron/`, [electron-client.md](electron-client.md)):
`main.js` supervises one ssh tunnel per connected profile, hosts the
header strip and the connection manager as client-owned pages, and serves
the frontend on the `webmux://` scheme (registered as secure, so clipboard
APIs are available). `ui/app.js` is the frontend: the scrolling column
layout with one xterm.js per terminal pane on its own WebSocket. The fit
addon reports pane sizes back; the server resizes both the PTY and the
headless mirror. The layout tree lives in localStorage keyed by the
`webmux://<host-slug>` origin, so each client keeps its own arrangement
per host. Client-wide settings live in the client's `config.json`; pages
read and write them at `/settings.json` on their own origin and every
connected host page follows a change at once. File-browser panes are
client-side widgets (`ui/files-widget.js`) with no server session; their
path and cursor persist alongside the layout.

**webmux-gtk** (`gtk/`, [native-client.md](native-client.md)): a fork of
Ghostty whose GTK shell is replaced by a new one (`src/apprt/webmux/`)
and whose termio backend (`src/termio/Webmux.zig`) speaks the WebSocket
protocol directly — `snapshot` and `output` frames feed Ghostty's
terminal, keystrokes go out as `input`, grid changes as `resize`. There
is no local pty and no bridge command. Ghostty's terminal state,
renderer, fonts, input encoding and selection are used as is. The host
and its protocols are unchanged; both clients push the same payload.

### Persistence

On every attach the pty host serializes the headless buffer — libghostty's
VT formatter, scrollback included; on the alternate screen it formats the
primary screen from a throwaway clone so vim or less don't hide the
history — and sends it as a `snapshot`. The client renders exactly what
the session looks like now. Titles are tracked in the pty host, so they
survive reattach too. Nothing is written to disk: sessions die with the
pty host process (reboot, or an explicit shutdown).

## Protocol

WebSocket at `/ws?session=<id>`, JSON messages. The pty host speaks the
same frames over its unix socket and the server forwards them verbatim.

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

Sessions are created and killed through the JSON API (`POST
/api/sessions`, `DELETE /api/sessions/:id`); the file browser uses
`GET /api/fs/list`, `/api/fs/preview`, `/api/fs/raw` (`?download=1` serves
an attachment), `GET /api/fs/watch` (a server-sent-events stream over
`fs.watch`), and `POST /api/fs/upload`, `/api/fs/rename`, `/api/fs/delete`.
Host pages report session-socket drops and reconnects to the client over
`POST /log` on their own origin, so they land in the connection log.

## Connection resilience

Sessions survive everything short of a pty-host shutdown; the client's
job is to notice a dead link quickly and get the tunnel back without
asking. On the Electron side (the GTK client implements the same state
machine; `gtk/PARITY.md` § 7):

- ssh runs with keepalives (`ServerAliveInterval=10`, `CountMax=2`, so a
  dead link is noticed within ~30 s) and with `ControlMaster` forced off,
  so a mux master from `~/.ssh/config` can't defeat them.
- The client probes the server through the tunnel every 5 s for as long
  as the tunnel is up. A dead or restarted remote server (or a half-open
  link) fails three probes in a row, which kills the tunnel and triggers
  the retry path — and every retry re-runs the deploy step, which
  restarts a dead server before tunnelling again.
- Auto-retry (backoff 1 s → 15 s) only happens for a connection that was
  established and then interrupted. A connect that never succeeded parks
  as *failed* with ssh's stderr; nothing churns in the background.
- Lid-open kills pre-sleep tunnels immediately rather than waiting out
  the keepalives.
- The page marks its title `· offline` while any session socket is down
  and retrying; the client shows that as an amber *degraded* pill.

**macOS Local Network privacy** (macOS 15+, stricter on 26.5+/27) gates
ssh to LAN hosts behind a per-app grant, and a denied connect fails
instantly with `No route to host`. The grant is attributed per process,
and Electron helper processes get their own entries, so the prompt can
land on the wrong one and leave the ssh children denied. Before the first
ssh to a LAN host per app run, `main.js` opens and closes one TCP
connection to it from its own process (`lan.js`), so the prompt is
attributed to the process that owns the ssh children. A denied probe (or,
for a `.local` name, a failed lookup — mDNS is gated too) holds the
attempt for up to 20 s while the prompt is up, so clicking Allow lets that
same connect proceed. macOS identifies the app for this grant by its code
signature, which is why the build is signed: [signing.md](signing.md).

## Clipboard (OSC 52)

An OSC 52 write travels through the PTY to the client unmodified; the
Electron page writes it with `navigator.clipboard.writeText`, the GTK
client through Ghostty's clipboard handling. Reads via OSC 52 are
ignored. What tmux does with OSC 52 from programs inside it, and the
one-line config it needs, is in [using.md](using.md) › Clipboard.

## Image paste

Pasting an image into a pane uploads it to the server (`paste-image`),
which writes it to the "clipboard slot" served by the `xclip` / `xsel`
shims in `shims/` (prepended to each session's `PATH`). Then:

- If the pane's foreground process is Claude Code, the raw Ctrl+V byte is
  forwarded — Claude reads "the clipboard" via the shim and attaches the
  image natively.
- Otherwise the image's temp-file path is typed at the prompt.

Foreground detection reads the shell's tpgid from `/proc` and checks
whether the process's argv looks like `claude`.

In the Electron client, Ctrl+V is suppressed at the xterm key-handler
level (xterm would otherwise send a bare `^V`) and the client reads the
clipboard through `navigator.clipboard.read()`: image → upload flow, text
→ xterm's normal paste, empty → a literal `^V`. Ctrl+Alt+V always sends a
literal `^V`. The clipboard image is also proactively synced to the server
slot on window focus (`clipboard-sync`; there is no clipboardchange
event), so a plain ⌘V into Claude Code finds it too. The slot is global —
one clipboard for all panes, like a real desktop.

## Browser-open relay

`xdg-open`, `sensible-browser`, `x-www-browser` and `$BROWSER` resolve to
shims in `shims/`. A shim spools the URL to the server, which forwards it
as `open-url` on the socket of the session that asked (`WEBMUX_SESSION`),
and the client viewing that session pops up an open / copy chooser.
