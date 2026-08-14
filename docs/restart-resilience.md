# Restart resilience: making shells survive server restarts

Design discussion notes (2026-08-10). Goal: preserve shell processes across code
updates / server restarts as much as possible.

> **Status (2026-08-11): baseline implemented.** Steps 1–3 of the decision
> summary shipped: client WS reconnect with backoff + snapshot re-request,
> UUID session ids, and the pty-host daemon (`ptyhost.js`, named unix socket
> under `$XDG_RUNTIME_DIR/webmux/`, spawned detached on demand by
> `server.js`, stopped only by explicit `node ptyhost.js shutdown`/kill).
> Multiple named hosts can run concurrently. Remaining ideas below (snapshot
> persistence, dtach, tmux flavors) are still open.

## Where we are today

- Single Node process owns everything: HTTP/WS server, static files, and every
  pty. `Session` (server.js:124) holds the node-pty, an `@xterm/headless`
  mirror + `SerializeAddon` for snapshots, and title/size state. Restarting the
  server kills every shell.
- Sessions live in an in-memory Map with counter IDs (`nextId`, server.js:122)
  that reset on restart — collides with IDs the client keeps in localStorage.
- No client reconnect: `ws.onclose` (public/app.js:537) prints `[disconnected]`
  and gives up. Recovery requires a page reload.
- The headless mirror gives "persistent screen state, ephemeral processes" —
  it survives client disconnects, not server restarts.
- Repo root has a leftover `webmux` unix socket file + .gitignore entry from an
  apparent earlier experiment in this direction.

## Prerequisites regardless of architecture

1. **Client WS reconnect with backoff** that re-requests the snapshot on
   reconnect (reset terminal, write snapshot — the fresh-attach path at
   server.js:196 already does this). Without it, any restart still leaves
   panes dead until manual reload. Cheap; do this first.
2. **Stable session IDs** (UUIDs, not a resetting counter). The existing
   `attachExisting()` reconciliation (public/app.js:737) then re-adopts live
   sessions across restarts.

## Option 1 (recommended baseline): pty-host daemon

Extract a minimal `ptyhost` process owning only: the sessions Map, `pty.spawn`
+ env setup, and the headless mirror + serialize addon (the mirror must move
with the ptys so post-restart attaches get a full screen). It listens on a unix
socket. `server.js` becomes a thin restartable proxy: static files, auth, TLS,
WS termination, forwarding `input`/`resize`/`output`/`snapshot` frames.

- Simplest wire protocol: one unix-socket connection per attached session,
  newline-delimited JSON mirroring the existing WS message types ~1:1.
- Keep the daemon's dependency footprint tiny (node-pty, @xterm/headless,
  serialize) so it almost never needs restarting. ~95% of churn is in the web
  server / FE, which become restart-free.
- Same architecture VS Code uses (its "pty host" survives reloads).
- Optional later: daemon persists serialized snapshots to disk so even daemon
  restarts restore screen content (processes still die); or dtach under the
  daemon if daemon churn is real.

**Rejected: fd-passing** the pty masters to a new server process (SCM_RIGHTS).
Node doesn't expose it for arbitrary fds without native addons and node-pty
can't reconstitute a Pty from a raw fd.

## Option 2: become a tmux client

tmux server owns all processes; survives web-server deploys, daemon crashes,
even node-pty breakage. Bonus feature: same sessions attachable from a plain
terminal over SSH.

### Flavor A — pty-wrapped attach (lazy)

Session create = `tmux new-session -d -s webmux-<id>`; each attach spawns the
node-pty running `tmux attach -t webmux-<id>`. Pty becomes a disposable tmux
client. Almost no code changes; headless mirror becomes deletable.

- tmux draws everything (splits, status bar, copy mode) into the byte stream —
  rendering foreign layouts is free, but tmux chrome appears inside webmux.
- Prefix key is live: users can create real tmux splits inside tiles.
- Scrollback moves to tmux's buffer: only the visible screen redraws on
  attach; prefill xterm.js history via `capture-pane -e -S -5000`.

### Flavor B — control-mode client (`tmux -C`, the real version)

Pipe-based, no pty at all. `%output %<pane> <octal-escaped bytes>` in,
`send-keys -H` out, `capture-pane` for snapshots. Server becomes a stateless
WS↔control-mode translator; node-pty leaves the dependency list. This is the
iTerm2 `-CC` architecture. No app state left to lose.

### tmux trade-offs (both flavors)

- **Nested tmux regression** — the big one for webmux: env is currently
  scrubbed of `TMUX`/`TERM_PROGRAM` (server.js:157) precisely so users run
  their own tmux inside panes. Under tmux-backed sessions that becomes nesting
  (prefix conflicts, `$TMUX` set).
- tmux re-encodes output: OSC 52 needs `set-clipboard` config (already
  documented in README); hyperlinks/sixel depend on tmux version/passthrough.
- Control-mode parsing is fiddly (octal-escaped UTF-8, line framing, flow
  control) with little Node library support.

### Performance (flavor B) — not actually slower

- Rendering is unchanged: `%output` is (roughly) raw pane bytes, octal-escaped.
  Unescape server-side, forward over WS; browser still runs plain xterm.js.
- Server likely gets *cheaper*: xterm-headless (full JS VT parse of every byte,
  server.js:176) is replaced by a trivial unescape loop; tmux's C parser holds
  state instead. Costs: up-to-4× byte inflation on the tmux→node pipe for
  non-ASCII, one extra process hop (microseconds).
- Flood behavior improves: control-mode flow control (`%pause` /
  `refresh-client -f pause-after`, tmux ≥ 3.2) frame-skips runaway output and
  resumes with a `capture-pane` snapshot. Current pipeline ships every byte.
- Historical "iTerm2 -CC is slow" complaints were mostly pre-3.2 (no flow
  control).

### Sizing model

Chain: client size → window size → pane sizes → pty size (`TIOCSWINSZ` →
SIGWINCH). A control client declares its size via `refresh-client -C WxH`.
Window size derives from viewing clients per the `window-size` option
(`latest` default since 3.1; also `smallest`/`largest`/`manual`).

For webmux: `set window-size manual` + `resize-window -t @<id> -x -y` per
window decouples every window from client sizes — the tiling engine keeps full
authority. If an SSH client co-attaches, size contention is inherent (losing
client sees clipping / dot-filled area); accept as the price of shared access.

### Wire protocol facts

- All tmux clients speak the same version-locked binary imsg protocol over the
  unix socket. A normal client passes its actual tty fd via SCM_RIGHTS and the
  *server* renders directly into it; a control client instead receives the
  `%`-notification text layer.
- Never speak imsg directly — always exec the tmux binary as the client
  (`tmux -C` over pipes, or `tmux attach` in a pty). Control mode is the
  stable public interface.

### Layout mapping: tile = window (one pane each)

- Pane layout *within* a window is tmux-authoritative (a server-side split
  tree with cell sizes; siblings coupled). iTerm2 mirrors it exactly and
  round-trips divider drags as `resize-pane`. Windows, by contrast, have no
  geometry relationship — clients present the window list however they want.
- Mapping each webmux tile to its own one-pane tmux window avoids the whole
  coupled-layout-tree dance and keeps webmux's FE layout tree in charge.

### Handling splits created by foreign clients

- No keyboard sequences ever needed: control clients issue commands
  (`split-window`, `break-pane`, `resize-pane`) directly.
- Inside webmux the one-pane invariant can't be violated: `send-keys -H -t %N`
  bypasses tmux key-binding tables, so there is no prefix key. Splits only
  arrive from external clients, announced via `%layout-change`.
- Policies, ascending effort:
  1. **Normalize**: on adoption or `%layout-change`, `break-pane` extras into
     their own windows → normal tiles. Never render tmux geometry.
  2. **Active pane only** + "N hidden panes" badge with an explode button.
  3. **Full render**: graft tmux's layout string (same tree shape as webmux's
     own tile tree) into the FE; iTerm2 approach; only if co-rendering with
     SSH users becomes a headline feature.
- Recommendation: policy 1 or 2; declare the invariant a feature.

## Decision summary

- The "users run tmux inside panes" constraint is the main argument against
  tmux-backed sessions; otherwise flavor A arguably beats the daemon.
- Baseline plan: (1) client reconnect + snapshot re-request, (2) stable UUIDs,
  (3) extract pty-host daemon, (4) optional snapshot persistence / dtach.
- Possible middle path: pluggable backend per session (`spawn $SHELL` vs
  `tmux new -d`) so tmux durability is opt-in per pane without forcing
  nesting on everyone.
