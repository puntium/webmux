# Follow-ups

Everything noticed while building the native Linux client (`webmux-gtk`)
that is not part of the build itself, or that the build leaves open. The
lead appends to this file as engineers report. Work still planned as part
of the build is tracked in `docs/native-client.md` › Status and
`gtk/PARITY.md`, not here.

Each item says where it came from. "Reported" means an engineer agent
observed it and the lead has not re-checked it; "verified" means the lead
re-ran or read it.

Last updated: 2026-11-05, after the header bar change that followed the first run on a real desktop
(all smokes pass on the Debug and release binaries). `gtk/PARITY.md`
carries a status per item: 300 of 317 ticked, 3 awaiting an independent
re-check, 12 judged by reading only, 2 n/a.

## 0. Incident

- **2026-11-04, during integration testing: a real `browser-picker` was
  started on the desktop's X display for about a minute.** A test ran
  `xdg-open` inside a session on a fake-ssh test host; the session used
  the login shell, whose profile rebuilt PATH without the host's shims,
  so the system `xdg-open` ran, and the host defaults an empty `DISPLAY`
  to `:0`. The integration engineer found and killed it. Fixed in the
  test tooling: fake-ssh sessions and the dev host now run `sh` with the
  shims first on PATH, `DISPLAY=no-such-display.invalid:0`, `BROWSER=`
  and an empty `WAYLAND_DISPLAY`. Nothing else outside the test
  directories was touched (reported; the lead confirmed no such process
  remains).
- [ ] Related, in the product rather than the tests: **the host defaults
  `DISPLAY` to `:0` for sessions** (`host/internal/ptyhost`, as
  `ptyhost.js` did). On a host that is also a desktop, a program in a
  session whose PATH lost the shims opens windows on that desktop. Worth
  reconsidering.

- [ ] **A login shell inside a session defeats the shims** (reported by
  the terminal auditor, on this machine): starting `tmux` or `bash -l` in
  a session rebuilds PATH from the system profile, after which `xdg-open`
  resolves to the real one instead of the host's shim. On a real remote
  host whose login shell resets PATH, the open-url chooser and the
  clipboard shims stop working inside tmux the same way. A host/shims
  design question (affects the Electron client equally).

## 1. Decisions waiting on you

- [ ] **First connect to a real host.** You ran the app on your GNOME
  desktop on 2026-11-05 (`make linux-client-run`); whether it has
  connected to a real sshd yet is not known to me. Everything I ran used
  a nested headless compositor with a fake ssh. The first real connect
  pushes the payload to that host as the Electron client does. See
  `gtk/README.md`.
- [ ] **Header bar, after that first run (2026-11-05).** The run showed
  what headless testing could not: the window had no title bar (no way
  to move it, no window controls) and the header buttons were cramped.
  The header is now a standard `AdwHeaderBar` with flat icon buttons
  (deviation 66). Checked headlessly: screenshots, all smokes, real
  pointer clicks on the buttons, pills and a pill's ✕. Not checkable
  headlessly and so still yours to confirm: dragging the window by the
  header, the window controls, and how the icons look with your icon
  theme (the headless run has no theme and shows GTK's bundled
  fallbacks). Dragging a pill to reorder it now competes with the title
  bar's window drag; the pill claims the press, and `smoke-chrome` has a
  real-pointer check that the drag reorders, but only a real desktop
  shows that the window stays put while it does.
- [ ] **The third fix round's fixes have no independent re-check** (the
  text-field focus restore, touchpad accumulation, the file browser's
  focus-change scrolling, the keyring clean-up at startup, the
  close-handshake race). They are covered by regression checks in the
  smokes on both binaries, and the lead reproduced the text-field case;
  a short independent pass would close the last three `gtk/PARITY.md`
  items marked partly.

- [x] **Commits.** Decided 2026-11-05: committed and pushed at your word.
  The webmux repo's branch `gtk-client` is on `origin` and was merged
  into `main` the same day (a fast-forward); the fork's branch
  `webmux-shell` is on <https://github.com/puntium/ghostty>. Further
  commits and pushes still wait for you to ask.
- [x] **Where the fork lives.** Decided 2026-11-05: a public GitHub fork
  of ghostty-org/ghostty, <https://github.com/puntium/ghostty>, branch
  `webmux-shell`.
- [x] **Pinning the fork from the webmux repo.** Decided 2026-11-05:
  `gtk/ghostty` is a git submodule, so each webmux commit records the
  fork commit it goes with. A commit in the fork needs a follow-up commit
  here to move the pointer; push the fork first, or the pointer names a
  commit nobody else can fetch.
- [ ] **A real ssh target.** The connection engine has never run against a
  real sshd (it would use your keys and write `~/.webmux` on the host).
  Name a host, or allow localhost.
- [ ] **Host scrollback finding** (section 2, first item): investigate and
  fix in `host/`, or leave?
- [ ] **Review the lead's rulings** in `docs/native-client.md` › Rulings on
  `gtk/PARITY.md` (new Ctrl+Shift+C copy, menu button instead of the
  hidden menu bar, no reload command, clipboard-image sync scope,
  PNG conversion of unsupported images, first-run profile import).
- [ ] **Review the deliberate deviations** in `docs/native-client.md`
  (15 so far), in particular: unix-socket tunnel end instead of a TCP
  port; a second live connection to the same host+instance is refused;
  snapshot replay at the remote grid size.
- [ ] **Upstreaming.** A pluggable termio backend hook in Ghostty itself
  would shrink the fork to almost nothing in the core. Ghostty has an AI
  contribution policy (`AI_POLICY.md`) and its `AGENTS.md` tells agents
  never to open issues or PRs, so this is yours to raise, if at all.

## 2. Host (`host/`, unchanged by this work)

- [ ] **Snapshots may carry only ~800 rows of scrollback, not 5000.**
  Reported by the backend engineer: after `seq 1 6000` the attach snapshot
  starts at line 5202. Suspected cause (unchecked): the mirror sets
  `WithMaxScrollbackLines(5000)` only, and libghostty's default
  `max_scrollback_bytes` (10,000) caps it first. Affects the Electron
  client too. `host/internal/ptyhost/session.go`; the e2e harness only
  checks 200 lines (`host/test/e2e.js`), so it would not catch this.
- [ ] **Soft-wrapped lines arrive as hard line breaks.** Reported: the VT
  formatter snapshot joins rows with CRLF, so lines that wrapped on the
  host before an attach cannot reflow in the client, while the host mirror
  does reflow them. Same limitation in the Electron client. Possible
  fixes: the formatter's unwrap option, or binary snapshots.
- [ ] **Unsupported image types are dropped silently** on `paste-image` /
  `clipboard-sync` (`host/internal/server/paste.go:87-93`; PARITY A-11).
  The native client will convert to PNG first; the host could answer with
  an error frame instead of nothing.
- [ ] **`docs/native-host.md:164` lists `GET /api/health`**; the server
  serves `GET /` and has no such route (PARITY A-06). Fix the doc.
- [ ] **Binary snapshots.** With Ghostty on both ends at the same commit,
  the host can send libghostty's binary snapshot and the client can decode
  it directly (instant reattach, exact wraps, no formatter workarounds).
  Needs a protocol addition, a version check (format v1 has no
  compatibility guarantee; pty hosts outlive deploys) and the VT snapshot
  kept as fallback.
- [ ] **Host-answered queries** (`docs/native-host.md` › Open items, stage
  2): the mirror could answer device queries itself. Interacts with the
  next item.
- [ ] **Mixed clients on one session.** Every attached client answers
  device queries, so two clients produce duplicate replies (already true
  with two Electron clients). New with this work: a Ghostty client may
  tell an application it supports the Kitty keyboard protocol; if an
  xterm.js client then types into the same session, it cannot encode what
  the application now expects. Not yet tested.
- [ ] **`TERM`.** Sessions run with `TERM=xterm-256color`
  (`docs/native-host.md` says "stays"). Revisit once the Electron client is
  not the only renderer.
- [ ] Existing open items in `docs/native-host.md` still stand (a real
  Electron session against the Go server, arm64 on real hardware, pty-host
  respawn, zip64).

## 3. Electron client and docs (found by the parity inventory; not changed)

Bugs and stale text in the existing client. The native client either fixes
or deliberately copies each (see the rulings); the Electron client itself
is untouched.

- [ ] No keyboard shortcut copies a terminal selection on Linux (A-03).
- [ ] A failed `GET /api/sessions` at page start leaves a blank page with
  no retry (A-07; `electron/ui/app.js:1620-1627`).
- [ ] `newSession()` has no error handling; a failed create shows nothing
  (A-08; `electron/ui/app.js:1389-1415`).
- [ ] Linux strings say "macOS Keychain" and "Finder" (A-05;
  `electron/connect.html:308`, `electron/logs.html:156`).
- [ ] The status text "allow it in the browser, or right-click → paste"
  refers to a context menu that does not exist (A-10;
  `electron/ui/app.js:1017`).
- [ ] `.tile.exited { opacity: 0.5 }` is never applied (A-09;
  `electron/ui/index.html:338`).
- [ ] The header comment of `app.js` describes the wrong chords (A-01;
  `electron/ui/app.js:9-14`).
- [ ] Docs give the log shortcut as ⌘⇧L; the code uses ⌃⌘L on macOS and
  Ctrl+Shift+G on Linux (A-02; `README.md:274-276,295`,
  `docs/electron-client.md:217`).
- [ ] README says the file browser deletes on `d`/`Delete`; the code also
  deletes on Backspace (A-17; `electron/ui/files-widget.js:1059`).
- [ ] README says Ctrl+Shift+V pastes; it works only through Chromium's
  native paste (A-04, inferred).
- [ ] Ctrl+R / F11 / Ctrl+Q are eaten by a focused terminal on Linux, so
  reload, full screen and quit are menu-only there (A-15, inferred).
- [ ] The theme id is validated by pattern in `main.js` but the list of
  themes lives only in the page (A-12).
- [ ] Clipboard-image sync reaches only the host whose page gets the focus
  event (A-14, inferred).
- [ ] Found by the layout engineer's differential test: a repeated session
  id in the live list creates duplicate columns in `app.js`; "new terminal
  below" can land at the top of the old column if focus moves during the
  server call; the saved-focus restore differs from what PARITY S-04's
  prose said (the checklist item should be reworded to match the code).
- [ ] Items tagged `[inferred]` in `gtk/PARITY.md` (T-19, T-21, C-05,
  K-31, A-03, A-04, A-14–A-16) were deduced from xterm.js/Chromium
  behaviour, not read in this repo. Confirm against the running Electron
  client before treating them as requirements.

## 4. Native client: not yet verified

- [ ] **Connections against a real sshd** (see section 1). Only checked:
  OpenSSH 10.6 parses `-o StreamLocalBindUnlink=yes -L /x.sock:/y.sock` as
  a unix-to-unix forward (`ssh -G`). Reported.
- [ ] **Backend over a real ssh tunnel.** All backend tests use a local
  host socket. Reported.
- [ ] **Release builds.** Every run and timing so far is a Debug build.
  Debug parses scrolling output at roughly 10 KB/s (reported), so judge
  performance only on a release build; none has been made.
- [ ] **Side-channel frames end to end**: `paste-image`, `clipboard-sync`,
  `paste-result`, `open-url` are unit-tested for encoding only. Reported.
- [ ] **Renderer CPU fallback** (frames delivered as pixels instead of
  DMABUF) is carried over from Ghostty and has never run here: DMABUF
  import succeeded in every setup tried. Reported.
- [ ] **Real pointer input.** The headless compositor seat has no pointer;
  selection, mouse reporting and scrolling were exercised at the core-call
  level through the control socket, not through GTK's gesture and scroll
  controllers. Cursor-shape changes are wired but unobserved. Reported.
- [ ] **Input methods.** Pre-edit verified only with GTK's simple input
  method (dead keys); not with IBus or fcitx. Reported.
- [ ] **Keyring.** The connection engine takes a password callback; the
  libsecret-backed provider does not exist yet and nothing has run against
  a real Secret Service.
- [ ] **Backend mailbox-full path**: when the termio mailbox fills during a
  snapshot replay the renderer lock is dropped mid-replay. Reasoned about,
  never triggered. Reported.
- [ ] **Layout model under `-O ReleaseSafe`**: one out-of-memory test fails
  with `NondeterministicMemoryUsage`. Believed to be the test harness, not
  proven. Passes in Debug (verified).
- [ ] **Full `zig build test`** reports failure although no test fails:
  stock `src/benchmark/TerminalSnapshot.zig` prints to stderr. Not
  confirmed that unmodified upstream does the same. Reported.
- [ ] **Kitty keyboard and Kitty graphics end to end** through a remote
  session (the reason for wanting Ghostty in the client) have not been
  tried.
- [ ] **"Stock Ghostty is unchanged without `-Dwebmux`"** rests on
  reasoning (identical generated options, the stock branch still selected),
  not on comparing binaries: Ghostty debug builds are not reproducible.

## 5. Native client: known gaps and small risks

- [ ] A keystroke typed during the few milliseconds of a locked snapshot
  replay is dropped (the backend discards writes between its replay
  markers). Reported.
- [ ] Input typed while a pane is disconnected is dropped, as in the
  Electron client. Queueing it would be friendlier but is a behaviour
  change.
- [ ] The password is passed to ssh through the child's environment (as
  the Electron client does). The engine zeroes its copy after spawn, but
  Zig's spawn internals may briefly hold another copy. Reported.
- [ ] The control socket (screenshots, typing, state dumps) is enabled by
  an environment variable. Before any release build: make sure it cannot
  be enabled by accident, or compile it out of release builds.
- [ ] Syntax errors under `src/apprt/webmux/` break the stock Ghostty
  build too (Zig parses every imported file, even in unused branches).
  Verified by the foundation engineer.
- [ ] Ghostty's own compiled UI resources and translations are still
  linked into `webmux-gtk`, unused. Removing them needs one more upstream
  edit.
- [ ] Scrollback is configured as 5000 lines but Ghostty trims by page, so
  slightly more survives.
- [ ] The app always runs as a separate instance (no hand-off to a running
  instance).
- [ ] No scrollbar, context menu, link-hover overlay or search in the
  terminal pane yet; check each against `gtk/PARITY.md` before deciding it
  is needed.
- [ ] Headless run directories (`/tmp/wm-*`) are not deleted by
  `webmux-dev/headless stop`.
- [ ] macOS-only behaviour is not carried over (Local Network probe,
  Keychain specifics); macOS stays on the Electron client.

- [ ] **Link state has two values in the seam** (`PaneHost.linkChanged`
  up/down): nothing fires for the first attach, and "up" fires when the
  socket reopens, slightly before the fresh snapshot repaints. If the
  header pill needs a "connecting" state per pane, the seam needs a third
  value. Reported by the foundation engineer.
- [ ] `session-title` frames are ignored by terminal panes (each pane has
  its own socket and gets its own `title`). Fine while every pane stays
  attached; revisit if panes ever detach while hidden.
- [ ] After the seed step, still not exercised: attaching to a session the
  host does not have (`session_error`), `setShown(false)` pausing
  rendering, dev mode with a registered workspace.

- [ ] **Terminal pane, written but not exercised** (reported): the
  light-theme scrollbar colours, dragging the scrollbar thumb, the
  clipboard-write failure message, and the "image in clipboard — Ctrl+V
  forwarded to Claude" result (needs Claude Code in the foreground on the
  host).
- [ ] **Testing note**: Wayland only lets a client set the clipboard or
  PRIMARY with a serial from real input, so headless tests must send one
  real key through the compositor first (`webmux-dev/realkeys`). Not an
  issue for real use.
- [ ] **Wheel step** (T-27): nobody measured what Chromium's step is in the
  Electron client; if scrolling feels different, measure it there.
- [ ] **OSC 8 link underline on hover** (T-25) needs a small Ghostty core
  change if wanted.
- [ ] The pane swallows Ctrl+Shift+letter combinations that are not shell
  chords unless the application enabled the Kitty keyboard protocol (as
  xterm.js does). Check this is what you want once Kitty-keyboard
  applications are in use.

- [ ] **Workspace, not done** (reported): no horizontal scrollbar or
  scroll indicator for the strip (the Electron client shows a 10 px one);
  off-screen panes are not culled from rendering.
- [ ] **Workspace, written but not exercised** (reported): GTK's own
  pointer paths (hover colours, divider drag gesture, wheel units; tested
  at the handler level only), the 250 ms animation settle timeout,
  fractional display scales, the title bar height against the Electron
  client's (25 px assumed, not measured).
- [ ] **Cell width is polled** from a terminal every 500 ms because font
  and scale changes emit no signal; a workspace with no terminal uses the
  last width seen, else 8 px. Works, but a signal from the pane would be
  cleaner.
- [ ] `webmux-dev/smoke --pane` fails its last step in the merged tree
  (verified): it forces an unknown session id through a dev hook that the
  workspace's reconciliation now bypasses. The step needs rewriting, not
  the product.
- [ ] `webmux-dev/headless` has no "restart only the app" command; the
  workspace smoke relaunches the app itself.

- [ ] **Secret transfer is unencrypted on the bus.** The keyring client
  uses the Secret Service "plain" session algorithm, not the
  Diffie-Hellman one libsecret uses; GIO's message copies of the secret
  cannot be wiped. Local session bus only, but worth upgrading. Reported.
- [ ] **The real app subscribes to logind's PrepareForSleep on the system
  bus** (read-only) to kill stale tunnels on wake. Tests must use the
  session bus instead; being made the headless default in integration.
- [ ] **Chrome, not exercised** (reported): real pointer input, the header
  menu popover, the workspace-create-failure path (X-31), Edit menu
  actions on terminals (W-42), Minimize, Open Config File (no handler app
  headless), an unlock prompt for a locked keyring (no prompter headless).
- [ ] **Panels, not exercised** (reported): backdrop click on dialogs, the
  status message's rise/fade animation, real tooltips, the log window's
  forwarding of `app.*` shortcuts.
- [ ] The log window's wrapped-line indent is a fixed 137 px, not measured
  from the font. (Its toolbar clipping, G-22, was fixed and confirmed by
  the re-check.)
- [ ] Two `g_settings_schema_source_lookup` assertion warnings appear in
  `app.log` at every start (reported by two engineers as pre-existing).
  Harmless so far; find the cause.
- [ ] Calling pango functions directly makes the binary need libpango,
  which its rpath does not cover, and it fails to start (reported). Any
  packaging work should check the binary's runtime library set.

- [ ] **File browser image formats** (reported): PNG, JPEG, GIF (first
  frame), BMP, ICO and SVG preview; WebP and AVIF do not (no loader in the
  app's environment). The Electron client previews whatever Chromium
  decodes, WebP included. Needs a gdk-pixbuf loader at packaging time.
- [ ] **File browser, not exercised** (reported): closing a pane through
  a container (only app quit), returning to the right edge after a layout
  change (F-65), stray drops (F-58), row hover colour. Being picked up in
  integration where the workspace makes them testable.
- [ ] **Markdown renderer gaps** (deviation 29): decide whether any matter
  for your notes (footnotes, front matter, selectable text are the likely
  ones).
- [ ] The preview header date ignores the system locale.

- [x] **File browser re-follow after a width change** (F-65): fixed in
  the first fix round and confirmed FIXED by the independent re-check.
- [ ] **Headless only**: once the app has owned the clipboard, GTK does not
  see a later `wl-copy` while the window keeps focus; the files smoke
  orders its steps around it. Probably harmless on a real desktop; check
  there.
- [ ] The control socket's `screenshot` renders an open dialog over an
  almost black backdrop without the window content; `grim` through
  `webmux-dev/in-session` shows the real picture.
- [ ] Download-folder memory for a saved profile through the real save
  dialog has not been run end to end (only dev mode's in-memory path).

- [x] **Cell width** measured in headless Chrome with the Electron
  client's font and xterm setup: its WebGL renderer uses a 7×17 cell (the
  DOM renderer 7.8×17); the native pane used 8×17 and now uses 7×17
  (reported by the terminal engineer; see deviation 42 for the remaining
  one-column gap).
- [ ] Audit findings are in `gtk/audit/*.md` with reproduction commands;
  the fix round works from those files.

- [ ] **The test helpers hide real-input bugs.** The layout auditor found
  three defects (divider drag, layout-dependent chords, dead app shortcuts
  under dialogs) exactly where control-socket helpers bypass GTK's own
  event handling, and found them quickly with real keystrokes and a
  60-line virtual-pointer client (saved in
  `gtk/audit/tools/virtual-pointer/`; uses the wlroots virtual-pointer
  protocol through the nested sway). The fix round adopts it into
  `webmux-dev/` so smokes can use a real pointer; every "no pointer
  device" caveat earlier in this file should be re-tested with it.
- [x] **Release performance, first numbers** (lead, 2026-11-04, with two
  verifiers loading the machine): ReleaseFast builds in 5m14s to a 34 MB
  binary. `seq 1 200000` (1.3 MB) displays in 0.57 s (Debug: over 60 s).
  Worst control-socket round trip during a server restart, reconnect and
  snapshot replay: 0.10 s (Debug: 2.8 s). Not yet measured on release:
  the file browser's first display of a 2,000-entry directory, a 20 MB
  snapshot, animation smoothness.
- [ ] **Three smokes fail on the release binary because they read
  Debug-only log lines** (`smoke-pane` "no large replay happened",
  the workspace smoke's "shortcut app.host-1" grep, and probably
  `smoke-files` "columns animate normally"). The checks should read state
  through the control socket instead, so the release binary is what gets
  tested. Not yet confirmed that none of the three hides a real
  release-only difference.

- [ ] **Real ssh behaviour still unverified after the fix round**: the
  chrome engineer read `ssh_config(5)` (`StreamLocalBindUnlink=yes`
  removes a stale socket; `StreamLocalBindMask` defaults to 0177, so the
  tunnel socket is owner-only), but no real tunnel has run. The fake uses
  socat, which binds 0755 inside a 0700 directory.
- [ ] Features copy `iface.Conn.name` when created; after a live rename
  the chrome's log service maps old names to the new one, but any UI text
  built from the copied name would still show the old one. Cleaner: read
  the name at use time (needs an `iface` note that it updates on rename).
- [ ] `Workspace.reload` writes nothing to the connection log, so a
  reconnect's session re-read is invisible in the log window.

- [ ] **Test tools after the fix round**: `webmux-dev/realkbd` (real
  evdev keycodes under a real XKB layout; use it for every chord),
  `webmux-dev/realpointer`, `webmux-dev/chrome-click` (widget names to
  real clicks). `realkeys` (wtype) is now only for typing text: chords
  sent through it no longer match. Known tool quirks: `headless stop`'s
  `pkill` can kill a caller whose command line contains the run dir;
  each `realpointer` call creates and destroys its pointer (keep a drag
  or a hover in one call); Shift+Tab through `realkeys` must be
  `ISO_Left_Tab`.
- [ ] Engineers' helper scripts collided in the shared session
  scratchpad during the fix round (one engineer's `restart` ran
  another's script and started a run with the other's binary). No
  product impact; a process note for future multi-agent rounds: one
  scratch subdirectory per engineer.
- [ ] `smoke-files` failed once under load on "browser never went idle"
  and passed on re-run (reported by the workspace engineer): a timing
  flake to remove.
- [ ] Unverified reading (workspace engineer): the Electron client's zoom
  accelerators match the layout's character; and the cause of real keys
  not reaching the window under an in-window dialog is assumed to be a
  GTK grab (fixed by giving each dialog the same key controller).

- [ ] **File browser, remaining after the fix round** (reported): the
  first display of a 2,000-entry directory still costs about 120 ms to
  build in a Debug build (no virtualised list); one or two GtkGrid
  measure warnings per markdown table remain, cause above the browser's
  own widgets not found; image-only paragraphs stack (cosmetic).
- [ ] **Terminal, remaining after the fix round** (reported): at some
  zoomed font sizes the cell rounding can differ from xterm's; 48
  Ctrl+Alt+F-key combinations could not be delivered through the nested
  compositor (it treats them as VT switches) and were checked with
  synthesized events only; the "raw `^[[200~`" report was reproduced only
  when Ctrl+Alt+V (a literal ^V) precedes a paste, where the Electron
  client behaves the same.
- [ ] **Snapshot replay** now holds the renderer lock per 4 KB slice with
  synchronized output on; worst main-loop stall on a 1.1–1.6 MB snapshot
  fell from 1.15–3.44 s to 0.017–0.29 s in Debug (reported). Re-measure
  on a release build and with a 20 MB snapshot.

- [ ] **Unexplained once**: a standalone `webmux-dev/smoke-integration`
  stopped silently during the colour-scheme screenshots with no FAIL
  line, leaving its app and compositor running; it could not be
  reproduced (the next run and three full runs passed). Reported by the
  integration engineer.
- [ ] The Shift+PageUp failure after the fix-round merge was a tooling
  collision, not a product bug: two engineers each wrote a virtual
  keyboard client, and the lead's reconciliation left both building to
  the same binary, so one tool ran the other's client and pressed
  nothing. The key-table harness now fails when fewer keys were sent than
  requested, so a broken tool cannot pass as "0 differ".

- [ ] **Re-check results** are in `gtk/audit/recheck-*.md`. Open after
  it, beyond what the second fix round takes on: replaying a 20 MB
  snapshot keeps the pane busy for about an hour in a Debug build (the UI
  stays responsive; re-measure on release); the client resets the socket
  instead of answering the server's close after a session exits; control
  characters in a session title draw as boxes in the pane's title bar; a
  frame containing a lone surrogate is dropped whole (the host never
  sends one); double-clicking a space or bracket selects the whole run of
  separators; a key pressed within about 10 ms of a paste arrives before
  the pasted text.
- [ ] **Cannot be verified headlessly** (16 items across the two
  re-checks), chiefly: real drag-and-drop from a file manager (a second
  Wayland client did work as a drag source), the items the audit could
  only judge by reading (X-13, X-31, W-05, W-19, W-42, G-29, P-27), real
  ssh, IBus/fcitx.

- [ ] `dump`'s `last_shortcut` is also set for chords that were matched
  but swallowed under a modal, so smokes prove "swallowed" only together
  with an unchanged state; a `swallowed` flag would make it explicit.
- [ ] `realkeys-xkb` names keys by US position, so under `--layout de`
  there is no way to name German's own "-" key; note it in its help.
- [ ] Lesson recorded from the second fix round: an id re-issue loop hung
  the app at start when the allocator handed back the freed id's bytes
  (caught by the chrome smoke, now covered by an engine test with an
  allocator that reuses freed memory at once). Release builds make this
  class of bug more likely to show; keep running the smokes on the
  release binary.

- [ ] **File browser after the second fix round** (reported): the first
  display of a 2,000-entry directory still stalls the main loop 39–65 ms
  on the release build (2–4 frames; was 60–195 ms); a virtualised list
  would remove it. Download failure reasons, long names and the
  recent-files entry are fixed; the user's real recent-files list was
  never touched (lead checked: it parses, 9 entries, none from the app).
- [ ] The link chooser has empty space above a short URL (panels area;
  cosmetic, not taken in the second fix round).

- [ ] **Release performance, measured by the terminal engineer** (not
  re-run by the lead): 1 MB snapshot replay 18 ms (Debug 2.6 s); 20 MB
  replay 250 ms (Debug 59 s); worst main-loop stall during replay 1–3 ms;
  sustained output about 30 MB/s end to end (Debug 0.25 MB/s). The
  earlier "about an hour" for a 20 MB replay in Debug was not reproduced
  (about a minute).
- [ ] **The touchpad scroll finding contradicted the verifier**: the
  Electron client scrolls 56 lines for an 80 px swipe, not about 5
  (measured by running Electron 43 with xterm.js 5.5 in the headless
  compositor). The native client now matches that. If touchpad scrolling
  feels too fast in daily use, that is the Electron client's behaviour
  carried over, and a setting would be the place to change it.
- [ ] Dragging after a double-click extends by Ghostty's word rule; making
  it xterm's needs a small Ghostty core edit (one more upstream edit).
- [ ] Keys typed during a paste are not held when the application has the
  Kitty keyboard protocol on.
- [ ] `webmux-dev/realpointer` paces every command by a roundtrip plus
  20 ms, so it cannot produce fast drags; the "divider trails a fast drag
  by a second" observation was that pacing, not the app (reported; no lag
  measured in either build).

- [ ] `gtk/PARITY.md` items T-13 and K-28 conflict as written (Ctrl+3…7
  are host-switch shortcuts, so they cannot also send control codes); the
  checklist text should be reworded. F-62 is ticked although its row
  points at the main-thread stalls, which were only partly fixed at the
  re-check (improved again in round 2). Re-run
  `gtk/audit/tools/tick-parity.py` on `gtk/audit/tools/PARITY.orig.md`
  once `gtk/audit/final-check.md` exists.

- [ ] **Final check, measurements on the release binary** (independent
  verifier): key to echo median 1.5 ms (max 2.4) on a local host, 2.4 ms
  (max 6.2) through the fake-ssh tunnel; new pane 300–450 ms from chord to
  attached; host switch under 40 ms; 2 MB of output in 0.29 s with a
  longest UI stall of 3.6 ms; first display of a 5,000-entry directory
  stalls 17 ms; a killed tunnel healed in 3.2 s and a killed server in
  15 s with the same sessions; quit takes 1.1 s.
- [ ] **Final check, low-severity leftovers** not taken in the third fix
  round if they prove awkward: an uppercase copy of a profile id leaves
  the original secret in the keyring while the app's record of it is
  emptied (no cross-host leak); secrets whose id disappeared from a
  hand-edited config are never deleted; titles sent by the host with raw
  control characters were verified only by the engineer (through a
  proxy), not independently; the link chooser's empty band above a short
  URL.

## 6. Packaging, repo and docs

- [ ] No desktop file, icon, or nix package for `webmux-gtk`; the payload
  tarballs are found by walking up to `electron/payload` in a checkout
  only. (`make linux-client` and `make linux-client-run` exist as of
  2026-11-05: release build into `gtk/ghostty/zig-out-release`, then run.
  The build step is tested; the run step has only been dry-run, since it
  opens the app on the desktop.)
- [ ] `README.md` and `docs/` do not mention the native client yet beyond
  `docs/native-client.md`.
- [ ] The Ghostty pin is shared with the host (`host/build.sh`
  `GHOSTTY_COMMIT`, `host/go.mod`); document that all three move together,
  and write down the rebase procedure for the fork (seven upstream edits,
  listed in `gtk/ghostty/WEBMUX.md`).
- [ ] `docs/native-client.md` › "Zig 0.17 notes" and the same section in
  `gtk/ghostty/WEBMUX.md` overlap; fold them together at the end.

## 7. Ideas raised earlier, not pursued

- [ ] **Ghostty in the Electron/macOS client via wasm.** `ghostty-web`
  (Coder) was ruled out: it pins a December 2025 Ghostty with its own
  patched API and has a Canvas 2D renderer. Restty (libghostty-vt, WebGPU,
  xterm.js-compatible API) was found but not inspected. Building
  `ghostty-vt.wasm` from the host's pin with a renderer over `render.h`
  remains the route that gives one engine everywhere.
- [ ] **xterm.js 6.1** reportedly adds the Kitty keyboard protocol (beta at
  the time of the search; stable release not confirmed): the cheap way to
  get that one feature in the Electron client.
- [ ] **Stock Ghostty plus a `webmux-host attach` subcommand** over ssh:
  no client at all, the window manager does the layout. Cheap to add and
  useful as a fallback on machines without the client.
- [ ] **A native macOS client** on the same fork is possible in principle
  (the shell is GTK-only, but the backend and the pure packages are not);
  not planned.
