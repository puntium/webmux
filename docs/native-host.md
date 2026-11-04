# Native host: `webmux-host` (Go + libghostty-vt)

Status (2026-11-03): **complete, not yet released.** All four packages are
in, `go build/vet/test ./...` is clean, both static binaries build, the e2e
harness passes 31/31 against the Go binary (x64 natively, arm64 under
qemu-user) and against the node reference, the node→native migration test
passes, and the client pushes the native payload (`docs/push-deploy.md`).
Not yet done: a real Electron client session against the Go server, and an
arm64 run on real hardware (see Open items). This document started as the
contract the port was built against and now describes what was built; it
is deliberately specific. When the code and this document disagree, fix one
of them in the same change.

## Goal

Replace the server-side node payload (`server.js`, `ptyhost.js`,
`ptyhost-client.js`, `deploy/remote-start.js`, `node_modules`) and the
pushed node runtime with ONE statically linked Go binary per architecture,
`webmux-host`, whose terminal mirror is libghostty-vt instead of
`@xterm/headless`. The Electron client, the frontend (`electron/ui/`), the
shell shims (`shims/`), the WebSocket protocol, the HTTP API and the
pty-host unix-socket protocol are unchanged: the Go binary is a behavioral
drop-in. The JS implementations stay in the tree until the native binary
has replaced them in a release; they are the reference for every port
(where the Go code and the JS differ in behavior, the JS is the spec unless
the difference is listed under Deliberate deviations below).

Why: the mirror must be at least as capable as the renderer in front of it
(see the libghostty investigation: a libghostty renderer in front of an
xterm mirror breaks reattach for Kitty-keyboard and grapheme-heavy
sessions). Doing the mirror natively also removes the 25 MB node push and
the multi-arch node-pty prebuild dance.

## Layout

```
host/                      Go module `webmux/host` (go 1.26.0)
  go.mod, go.sum           libghostty bindings, creack/pty, coder/websocket, fsnotify, google/uuid, x/sys
  tools.go                 `//go:build tools`: keeps every require referenced
  flake.nix, flake.lock    dev shell: zig 0.17.1 (mitchellh/zig-overlay), go, cmake, pkg-config,
                           plus the native cgo env (CGO_ENABLED, zig cc, PKG_CONFIG_PATH, GOFLAGS tags)
  build.sh                 builds libghostty-vt + webmux-host for every target (see Build)
  LIBGHOSTTY-API.md        cheat sheet of the Go bindings' API (copied from the module source)
  README.md                the three commands; points here
  cmd/webmux-host/main.go  subcommand dispatch only
  internal/protocol/       socket naming, runDir, newline-JSON framing, Control(), EnsureHost()
  internal/ptyhost/        the pty host daemon: ptyhost.go (daemon, signals, shim dir), main.go (CLI),
                           session.go (one owner goroutine per session), client.go (per-connection
                           writer queue), snapshot.go (formatter + alt-screen clone), utf8.go
                           (split-sequence buffering), ptyfile.go, ordered.go (JSON.stringify key order)
  internal/server/         HTTP API + WebSocket bridge: server.go, http.go, fs.go (incl. zip listing),
                           watch.go (SSE), paste.go (slot, /proc foreground, open-url spool), ws.go,
                           jsutil.go (node/JS semantics reproduced on purpose); fake pty host in tests
  internal/start/          remote starter (port of deploy/remote-start.js); its tests re-exec the test
                           binary as a fake `webmux-host serve`
  test/e2e.js              node harness: drives a server over its unix socket (31 checks)
  test/migrate.js          node → native migration + reverse-compat test
  third_party/ghostty-vt/<triple>/{include,lib,share}   built libghostty-vt (gitignored)
  dist/webmux-host-<platform-key>                        built binaries (gitignored)
```

During the build-out, package ownership was strict (one engineer per
directory under `internal/`). The rule that survives: nobody runs
`go mod tidy` without checking the diff (`tools.go` exists so it keeps the
requires, but it has never been run on this module). Add a dependency with
`go get` only if it is not already in `go.mod`.

## Subcommands

```
webmux-host ptyhost [--name X]                 run the pty host daemon (foreground; the server spawns it detached)
webmux-host ptyhost [--name X] ping|list|shutdown   one-shot control commands (as `node ptyhost.js …`)
webmux-host serve                              run the HTTP/WS server (env: WEBMUX_PTYHOST, WEBMUX_SOCKET)
webmux-host start [--name X]                   idempotent "make this payload the running server" (remote-start.js)
webmux-host version                            prints payload hash (or `dev`) and libghostty build info
```

Exit codes and stdout contracts match the JS counterparts exactly;
`start` prints a single JSON object as the LAST stdout line.

## Pty host (`internal/ptyhost`), port of `ptyhost.js`

Protocol: unchanged, `PROTOCOL = 1`, socket `$XDG_RUNTIME_DIR/webmux/<name>.sock`
(fallback `$TMPDIR/webmux-<user>/`), newline-delimited JSON, first line picks
the mode. Commands and replies are byte-for-byte the same JSON shapes as
`ptyhost.js` documents in its header comment, including `ping`'s
`pasteDir`, `list`'s `describe()` fields, `attach`'s first `snapshot` frame
`{type:'snapshot', data, cols, rows, title, pid}`, `exit`, `error`,
`watch` → `{type:'session-title', session, title}`.

Because the protocol is unchanged, a Go server fronts a still-running NODE
pty host transparently (sessions survive the node→native migration), and a
Go pty host serves an old node server. Nothing bumps PROTOCOL.

Session:
- id: UUID v4 string.
- pty: `github.com/creack/pty`, `$SHELL_CMD || $SHELL || bash`, cwd `$HOME`,
  `TERM=xterm-256color` (stays; see investigation), env exactly as
  `ptyhost.js` builds it: PATH prefixed with the payload's `shims/` dir
  (the dir next to the running binary: `filepath.Dir(os.Executable())/shims`),
  `WEBMUX_CLIPBOARD_DIR`, `WEBMUX_SESSION`, `BROWSER`, `DISPLAY` default
  `:0`, `TMUX`/`TMUX_PANE` removed, `TERM_PROGRAM{,_VERSION}` removed when
  `TERM_PROGRAM=tmux`.
- mirror: one `libghostty.Terminal` per session (`go.mitchellh.com/libghostty`),
  `WithSize(cols, rows)`, scrollback 5000 lines. All pty output is written
  to the mirror AND fanned out verbatim to attached clients as
  `{type:'output', data}` (data is a JS string: pty bytes decoded as UTF-8
  the way node's `pty.onData` delivers them; split multi-byte sequences
  across chunks must not be corrupted — buffer incomplete UTF-8 tails).
- The terminal is NOT thread-safe. One goroutine owns each session's
  terminal; pty reads, input, resize, attach (snapshot) and kill are
  serialized through it (a channel or a mutex, but never concurrent cgo calls).
- snapshot: libghostty Formatter, VT format, `Trim(false)`, extras: modes,
  cursor, style, hyperlink, scrolling region, kitty keyboard. With no
  selection the formatter already covers the active screen INCLUDING its
  scrollback (verified: 200 lines into 80x24 → 201 lines from "line 1",
  byte-identical to an explicit history→end selection), so none is passed.
  The result is the `data` of the snapshot frame, consumed by the unchanged
  xterm.js client via `term.reset(); term.write(data)`.
- alt-screen snapshot (`snapshot.go`): the formatter only ever formats the
  ACTIVE screen, so while vim/less is up it would drop the primary screen
  and its scrollback (xterm's SerializeAddon emits primary, `?1049h`, alt).
  Switching the live mirror with `?47l/?47h` is unsound (mode 47 copies the
  cursor, ends the alt cursor's hyperlink, and leaves the 47 flag set
  forever). Instead the primary is formatted from a disposable CLONE: the
  mirror is encoded with libghostty's binary `Snapshot()`, decoded into a
  fresh Terminal with no effect callbacks (nothing can reach the pty), the
  clone leaves the alt screen as the app eventually will (`?1049l` restores
  the saved cursor; 1047/47 their own resets), and its primary is formatted.
  Output: primary + `ESC[?1049h ESC[H ESC[0m ESC]8;;ESC\` + the live
  mirror's alt output with its leading `?1049h` removed (a second one would
  re-save the cursor at home). The live mirror is only read. If the clone
  fails the snapshot degrades to the alt screen alone. Tested for entry via
  1049, 1047 and 47 (`TestSnapshotAltScreen`).
- query responses: NOT answered by the mirror in this stage (no WritePty
  effect registered); the client answers, as today. Title: `WithTitleChanged`
  → broadcast `{type:'title', title}` to attached clients and
  `session-title` to watchers. Nothing else from the effects API in stage 1.
- resize: ints clamped to cols 2..500, rows 2..300; mirror then pty.
- exit: `{type:'exit', exitCode}` to attached clients, their sockets closed,
  session removed.
- daemon: `EADDRINUSE` dance (ping the socket; if alive exit 1, else unlink
  and listen), SIGTERM/SIGINT → kill all ptys, unlink socket, exit;
  SIGHUP caught and dropped (not SIG_IGN, so shells don't inherit an
  ignored SIGHUP). Log lines to stdout as `ptyhost.js` does (the server
  redirects them into `<runDir>/<name>.log`).
- paste dir: `os.TempDir()/webmux-pastes-<user>`, mkdir 0700 at start.
- shims dir: `shims/` next to the binary (a payload); else, in a checkout
  (`host/dist/`, `go test`), walk up from the executable and then the cwd
  for `shims/xdg-open`. Logged as `shims: <dir> (next to the binary|dev
  checkout|MISSING)`.

## Server (`internal/server`), port of `server.js`

Everything in `server.js` 1:1, same paths, same JSON, same status codes,
same CORS behavior (permissive on every response, OPTIONS preflight), same
limits. Listens on the unix socket `<runDir>/<name>.http.sock` (0600) or
`$WEBMUX_SOCKET`; same EADDRINUSE dance; writes the advert
`~/.webmux/<name>.json` `{socket, payloadHash, protocol, pid, startedAt}`
unless `WEBMUX_SOCKET` is set. `payloadHash` comes from a `PAYLOAD_HASH`
file next to the binary, else `dev`.

Routes (read `server.js` for bodies; this is the checklist):
`GET /api/health` (whatever `server.js` serves at its health/identity route),
`GET|POST /api/sessions`, `DELETE /api/sessions/:id`, `POST /api/paste`,
`GET /api/fs/list`, `GET /api/fs/preview` (incl. the zip central-directory
listing → `archive/zip`), `GET /api/fs/watch` (SSE, `fsnotify` on the
directory, non-recursive, ~100 ms coalescing, 25 s comment keepalive,
`gone` event), `POST /api/fs/upload`, `POST /api/fs/delete`,
`POST /api/fs/rename`, `GET /api/fs/raw`.

WebSocket `/ws?session=<id>` (`github.com/coder/websocket`): one pty-host
unix connection per browser socket, host frames forwarded verbatim,
browser `input`/`resize` forwarded, `paste-image` → clipboard slot +
foreground detection via `/proc/<pid>/stat` tpgid exactly as
`server.js`, `clipboard-sync` → slot only. The watch connection fans
`session-title` to every browser socket. The open-url spool watcher
(`open-*` files in the paste dir, claim by rename) → `{type:'open-url', url, id}`
to the session's sockets or broadcast.

`ensureHost` spawns `os.Executable() ptyhost --name <name>` detached
(setsid, stdio → `<runDir>/<name>.log`), polls ping for 5 s.

## Starter (`internal/start`), port of `deploy/remote-start.js`

Same algorithm and same output contract. Differences:
- the server is `os.Executable() serve` with `WEBMUX_PTYHOST=<name>`,
  cwd = the payload dir, stdio → `~/.webmux/<name>.server.log`;
- `pidIsWebmuxServer` and `serversForInstance` must recognize BOTH the old
  node server (`/proc/<pid>/cmdline` contains `server.js`) and the native
  one (`webmux-host` … `serve`), so the first native deploy onto a host
  running the node payload stops the node server (never the pty host).
- `PAYLOAD_HASH` is read from the file next to the binary.

## Payload and deploy

The payload is now per platform: `electron/payload/<key>/payload.tar.gz`
containing `webmux-host` (static binary), `shims/`, `PAYLOAD_HASH`;
`electron/payload/payload.json` becomes `{ platforms: { <key>: {hash, bytes} }, builtAt }`.
`deploy/build-payload.js` is rewritten to stage these from `host/dist/`;
the content hash is computed the same way (sorted paths + bytes). `electron/deploy.js`:
probe unchanged, the node runtime step is removed, payload push picks the
platform's tarball, `remoteStart` runs `exec <payload>/webmux-host start --name <instance>`.
`electron/platforms.js` rows lose the node fields and gain `payloadKey`
(`linux-x64`, `linux-arm64`); musl rows become possible once the binaries
are static. `electron/main.js` and `electron/test/deploy-cli.js` adapt to
the new manifest shape.

## Build

Commands (everything server-side runs inside the `host/` flake's dev shell;
`build.sh` re-execs itself there when zig/go are missing):

```sh
cd host
./build.sh               # libghostty-vt for both triples if missing (~2-3 min each, cached under
                         #   host/third_party/; Ghostty source in ~/.cache/webmux-ghostty), then both binaries
./build.sh --host-only   # just host/dist/webmux-host-linux-x64 (fast iteration)
./build.sh --libs        # just the C libraries; --force rebuilds them even if the pin matches
nix develop . -c go build ./... && nix develop . -c go vet ./... && nix develop . -c go test ./...
cd .. && node deploy/build-payload.js   # electron/payload/<key>/payload.tar.gz + payload.json
```

(`make host-libs`, `make host`, `make payload` wrap the same commands; on a
host without `make`, run them directly.)

Gotchas:
- **Run go from `host/`.** The module root is `host/`, not the repo root:
  `nix develop ./host -c go test ./host/internal/...` from the repo root
  fails with "cannot find main module" / "directory prefix does not contain
  main module". `cd host && nix develop . -c go test ./...` works.
- **The flake must be visible to git.** Nix evaluates a flake inside a git
  repo from the git tree, so untracked `flake.nix`/`flake.lock` are
  invisible ("path … does not exist"). They were added intent-to-add with
  `git add -N host/flake.nix host/flake.lock` (the only index change of the
  port; they show as `A` in `git status`). Committing them makes this moot;
  `git rm --cached` undoes it, after which `nix develop path:./host` is
  needed instead. Expect `warning: Git tree … is dirty` on every run.
- **Unix socket paths are capped at 108 bytes** (`sun_path`). The nix
  shell's TMPDIR, the Claude scratchpad, and Go's `t.TempDir()` names all
  blow past it with `<dir>/webmux/<name>.http.sock` appended. Every test
  and harness here roots its sockets in a short `/tmp/wm-*` (or `/tmp/wme.*`)
  dir; do the same for any new one.

`host/build.sh` steps:
1. fetch Ghostty at the pinned commit (the one `go-libghostty`'s
   `CMakeLists.txt` pins: the Go bindings' cgo headers must match the C
   library) into a cache dir outside the repo; `zig build -Demit-lib-vt -Dtarget=<triple> --prefix host/third_party/ghostty-vt/<triple>`
   for each target;
2. `CGO_ENABLED=1 GOOS=linux GOARCH=<arch> CC="zig cc -target <triple>" PKG_CONFIG_PATH=<prefix>/share/pkgconfig CGO_CFLAGS="-I<prefix>/include -DGHOSTTY_STATIC" go build -trimpath -tags osusergo,netgo -ldflags="-s -w -linkmode=external '-extldflags=-static -s'" -o host/dist/webmux-host-<key> ./cmd/webmux-host`.
   (Deviation from the first draft, which had `CGO_LDFLAGS=-lghostty-vt`: the bindings link through
   `#cgo pkg-config: --static libghostty-vt-static`, whose `.pc` names `<prefix>/lib/libghostty-vt.a` by
   path, so `PKG_CONFIG_PATH` is required and `-l` would have preferred the `.so`. `osusergo,netgo` keep
   `os/user`/`net` off libc NSS; `-extldflags -s` strips the C side, 16 MB → 4 MB.)
   Pinned: Ghostty `f54340ad77814fe319d136e5e915d6a48de8dd23`, go-libghostty
   `v0.0.0-20261021212106-df1957cbff56`, Zig 0.17.1, `-Doptimize=fast`. Both musl triples build and
   link fully static; no `-gnu` fallback was needed. `file`: "ELF 64-bit LSB executable, x86-64 /
   ARM aarch64, statically linked, stripped"; `ldd`: "not a dynamic executable". Sizes with the full
   implementation: 9.5 MB (x64) / 8.7 MB (arm64) binaries, 3.8 / 3.4 MB payload tarballs (the
   4 MB figure from the scaffold stage predates the real packages). `webmux-host version` prints the
   payload hash (`dev` outside a payload), then
   `libghostty-vt 0.1.0-dev optimize=release-fast simd=true kitty-graphics=true tmux-control=false`. `nix develop ./host` also exports the native cgo
   env so plain `go test ./...` works in the shell after `./build.sh --libs`.
Targets: `x86_64-linux-musl` → `linux-x64`, `aarch64-linux-musl` → `linux-arm64`
(fully static; verify with `file`/`ldd`). If musl fails for the C library,
fall back to the `-gnu` triples and record why here.

Pins live in `host/build.sh` (`GHOSTTY_COMMIT`, `ZIG_TARGETS`) and in
`host/go.mod` (`go.mitchellh.com/libghostty` pseudo-version). Bump them
together.

## Deliberate deviations from the JS

The Go code reproduces node/JS quirks on purpose wherever a client could
tell (`internal/server/jsutil.go`: U+FFFD UTF-8 decoding, lenient base64,
node's `path.*`, errno names as `err.code`, `String(err)`,
`encodeURIComponent`, `decodeURIComponent`'s `URI malformed`, `cols || 80`
truthiness, …; `internal/ptyhost/ordered.go`: `JSON.stringify` key order on
every pty-host frame). What it does NOT reproduce, deliberately:

JSON encoding
- HTTP JSON responses (fs/list entries, previews, error bodies, sessions,
  …) are encoded with Go's sorted map keys, not node's insertion order. The
  client only `JSON.parse`s them. SSE payloads do keep node's order
  (`{path, error}`). Pty-host frames (snapshot/output/title/exit/error/
  session-title) are byte-identical to `ptyhost.js` and forwarded verbatim
  by both servers; `ping`'s CLI output is the reply line verbatim.
- `mtime` in previews is node's fractional `mtimeMs` (sec·1e3 + nsec/1e6 in
  float64), compared exactly by the harness: no deviation.

Pty host (vs `ptyhost.js`)
1. `exitCode` on a signal death is 0 (WEXITSTATUS only), matching node-pty,
   which reports the signal separately in a field `ptyhost.js` never
   forwarded: the client keeps seeing "[session exited: 0]" after a kill.
2. `create` clamps cols/rows to 2..500 / 2..300 and takes the default for
   non-numbers; `ptyhost.js` handed anything truthy to node-pty unchecked. A
   failed spawn replies `{ok:false,error}` where node would have crashed.
3. Usage text: `usage: webmux-host ptyhost [--name X] [shutdown|list|ping]`
   (exit 2).
4. Extra log lines: `shims: …` and `session <id> exited (<code>)`.
5. Shutdown closes each pty master as well as SIGHUPing it and waits up to
   2 s for sessions to end, so attached clients may get an `exit` frame
   where node just dropped the connection.
6. A client that falls 4096 frames behind is disconnected; node buffered
   without limit.
7. An incomplete UTF-8 tail still held at exit is flushed as one last
   `output` frame (U+FFFD), like `StringDecoder.end()`.
8. The snapshot pads blank rows (`Trim(false)`) and writes colors as
   `38;5;n`; xterm's serializer trims and uses `31`-style codes. The replay
   is the same. The alt-screen layout is described under Pty host.

Server (vs `server.js`)
9. Oversized request bodies get a real `413 {"error":"payload too large"}`
   with `Connection: close`; node destroys the socket (the client usually
   saw a reset).
10. Malformed browser WebSocket messages (`null`, non-objects, bad JSON)
    are ignored; `null`/non-object crashed the node server with a TypeError.
11. When the pty host closes an attach, the queued frames (the `exit`)
    drain and the WebSocket closes with code 1000; node's `ws.close()` sent
    no code (client sees 1005). The frontend only logs the code.
12. Zip previews use a byte-for-byte port of `readZipListing`, not
    `archive/zip` (which cannot reproduce the 16 MB cap, partial listings,
    latin1 names or the count/truncated rules).
13. fs/list ordering approximates `localeCompare(…, {sensitivity:'base'})`
    without ICU: ICU's ASCII order (space, punctuation, symbols, digits,
    letters case-folded), Latin-1 letters folded to their base (é=e, ß=ss,
    æ=ae), control characters ignored, other scripts by code point after
    Latin; stable. Matches node on everything the harness and tests cover;
    exotic scripts may order differently.
14. WebSocket origin: any origin accepted (`InsecureSkipVerify`), as node's
    `ws` checks none; compression off; read limit 100 MiB (ws's
    `maxPayload`); an upgrade on any path but `/ws` gets 400. Each browser
    socket has its own unbounded send queue and writer goroutine.
15. HTTP timeouts follow node's defaults (60 s headers, 5 s keep-alive
    idle); a handler panic is recovered into a 500.

Starter (vs `remote-start.js`)
16. An advert `pid` ≤ 0 counts as not alive (`process.kill(0, 0)` succeeds
    in node, so a `pid: 0` advert counted as alive).
17. `--name` with no value gives `""` → "invalid instance name ''"; node
    got the string "undefined", which passed validation.
18. Old-server recognition matches both the node server (`server.js` in a
    cmdline that also contains `webmux`) and `…webmux-host serve`; never a
    pty host. Same `WEBMUX_PTYHOST`/`WEBMUX_SOCKET` filtering as the JS.

## Verification

Commands (all pass as of the status date; run from the repo root unless
noted):

```sh
cd host && nix develop . -c go build ./... && nix develop . -c go vet ./... && nix develop . -c go test ./...
cd host && ./build.sh                                            # both targets
node host/test/e2e.js                                            # Go binary (default)
E2E_SERVER_CMD="node $PWD/server.js" node host/test/e2e.js       # node reference
node host/test/migrate.js                                        # node → native migration + reverse compat
node deploy/build-payload.js
node electron/test/lan.js && node electron/test/harness.js && node electron/test/deploy-fake.js
```

- Unit tests per package (`go test ./...`, also clean under `-race`):
  framing and control (protocol); daemon end-to-end, CLI, EADDRINUSE,
  mirror smoke, primary and alt-screen snapshots, UTF-8 splitting
  (ptyhost); every route, WS bridge, spool, paste, SSE against a fake pty
  host (server); started/reuse/replace/SIGKILL/stale advert/legacy node
  server/log tail/timeout with the test binary as a fake `serve` (start).
- `host/test/e2e.js`: starts a server (`E2E_SERVER_CMD`, default
  `host/dist/webmux-host-linux-x64 serve`) on a private `WEBMUX_SOCKET` in an
  isolated `/tmp/wm-e2e-*` HOME/XDG_RUNTIME_DIR/TMPDIR and checks, over the
  unix socket: health, CORS, 404/400, sessions create/list/delete, the
  snapshot frame, session env and shims, `seq 1 200` scrollback in a
  reattach snapshot, resize + clamping, OSC 2 title / session-title,
  open-url spool (targeted, broadcast, non-http dropped), clipboard-sync,
  paste-image, `/api/paste`, fs list/preview/watch/upload/rename/delete/raw,
  exit 7, missing session, pty-host shutdown, server SIGTERM (31 checks).
  HTTP/SSE JSON is compared structurally (key order ignored, see JSON
  encoding above); title/session-title/exit/error frames are compared
  byte-for-byte against the raw WebSocket text. `E2E_PTYHOST_SHUTDOWN_CMD`
  (with `{name}`), `E2E_SHELL`, `E2E_KEEP`, `E2E_VERBOSE` tune it.
  The arm64 binary was run through it under qemu-user with a wrapper that
  pre-starts `qemu-aarch64 webmux-host-linux-arm64 ptyhost` (EnsureHost's
  re-exec of `os.Executable()` would need binfmt) and then execs
  `qemu-aarch64 … serve`, with
  `E2E_PTYHOST_SHUTDOWN_CMD="qemu-aarch64 <bin> ptyhost --name {name} shutdown"`:
  31/31.
- `host/test/migrate.js` (fully isolated under `/tmp/wm-mig-*` with its own
  HOME, XDG_RUNTIME_DIR, TMPDIR; daemons double-forked so they are not this
  process's children; anything left running under the scratch HOME is
  killed and fails the run; `MIG_BIN` picks the binary, `MIG_KEEP=1` keeps
  the dir):
  a. node `ptyhost.js --name mig` + `WEBMUX_PTYHOST=mig node server.js`
     (advert `~/.webmux/mig.json`, payloadHash `dev`); create a session over
     the API and run `seq 1 50` in it;
  b. stage `~/.webmux/dist/payload/<hash>/{webmux-host,shims/,PAYLOAD_HASH}`
     and run `<payload>/webmux-host start --name mig` from `$HOME`: last
     stdout line `{"ok":true,"action":"started",…}`, node server gone, node
     pty host alive with the same pid, advert has the new hash and the new
     server's pid (cmdline `<payload>/webmux-host serve`);
  c. through the Go server: identity, the session is listed, the attach
     snapshot carries 1..50, input still reaches the shell;
  d. `start` again → `action:"reuse"`, same pid;
  e. `webmux-host ptyhost --name mig shutdown` stops the NODE pty host
     (exit 0, socket gone), SIGTERM the Go server (socket gone);
  f. reverse compat: `webmux-host ptyhost --name x` fronted by
     `node server.js` (and pinged by the node client): create, `seq 1 40`,
     reattach snapshot, `node ptyhost.js --name x shutdown`.

## Open items

- The Electron client has not been run against the Go server (only the
  headless client tests and the e2e harness, which drives the same HTTP/WS
  surface the frontend uses). First real connect should watch: snapshot
  replay of TUI apps and the alt-screen layout, paste-image into Claude
  Code (the Ctrl+V foreground path is not covered by the harness), file
  browser ordering with non-Latin names.
- arm64 has only run under qemu-user on x86_64, never on real hardware,
  and its EnsureHost spawn path (the server starting its own pty host) was
  not exercised there.
- Not covered by any harness: the server respawning a pty host that died,
  `/api/fs/watch` `gone` (unit-tested only), zip64, Restart Sessions'
  remote script in `electron/main.js` (checked with `sh -n` only).
- The query-response and other libghostty effects (WritePty, bell, …) are
  still unregistered (stage 1: the client answers queries, as before).
