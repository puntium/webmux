# Native Linux client: `webmux-gtk` (Ghostty fork, GTK4)

Status (2026-11-05): **built, audited and fixed; not yet run on a real
desktop or against a real sshd.** This is the contract the client was
built against. It is deliberately specific; when the code and this
document disagree, fix one of them in the same change. The lead keeps the
Status table at the bottom current.

## Goal

A native Linux client with every feature of the Electron client
(`electron/`, checklist in `gtk/PARITY.md`), built as a fork of Ghostty:

- Ghostty's core is kept as is: terminal state, renderer, fonts, input
  encoding, selection, search (`src/terminal`, `src/renderer`, `src/font`,
  `src/input`, `src/Surface.zig`).
- Ghostty's GTK shell (`src/apprt/gtk/`: application, windows, tabs,
  splits, palette, dialogs) is **not used**. A new shell, `src/apprt/webmux/`,
  replaces it. Terminal-essential widget code (the surface widget, the
  DMABUF `RenderSurface`, key translation) may be copied from
  `src/apprt/gtk/` into the new shell and adapted; nothing in the new shell
  imports from `src/apprt/gtk/` at runtime.
- There is **no bridge command and no local pty**. A new termio backend,
  `src/termio/Webmux.zig`, speaks the existing webmux WebSocket protocol
  (`README.md` › Protocol) directly: `snapshot` and `output` frames feed the
  terminal, keystrokes and query replies go out as `input`, grid changes as
  `resize`.
- The host (`host/`, `webmux-host`) and its protocols are **unchanged**.
  The Electron client keeps working against the same host.

Non-goals: macOS (stays on Electron), changing the host, binary snapshots
(a later step this architecture makes possible), Ghostty features the
Electron client does not have (tabs, splits, quick terminal, inspector).

## Layout

```
gtk/
  PARITY.md                 feature checklist derived from electron/ (definition of done)
  ghostty/                  the fork: a git checkout of ghostty-org/ghostty at f54340ad
                            (same pin as host/), branch `webmux-shell`. Its own git
                            repository (github.com/puntium/ghostty), a submodule
                            of the webmux repo since 2026-11-05.
    src/apprt/webmux.zig    apprt entry (App, Surface, resourcesDir)
    src/apprt/webmux/       the shell: application, window, header, connection page,
                            terminal pane, layout strip, file browser, settings, log
                            window, modals, CSS, UI definitions
    src/termio/Webmux.zig   the IO backend
    src/webmux/             pure Zig, no GTK, unit-tested on its own:
      net.zig, net/         unix-socket HTTP/1.1 client, WebSocket client, SSE reader,
                            protocol frame types
      conn.zig, conn/       profiles, ssh tunnel supervision, deploy, liveness,
                            connection log
      layout.zig, layout/   the column/stack model and its commands, width rule,
                            persistence
    WEBMUX.md               fork notes: how to build/run/test, conventions, and the
                            complete list of edits to pre-existing Ghostty files
  audit/                    the parity audit's findings, one file per auditor
  wt/<area>/                clones of the fork for engineers working in parallel;
                            merged into gtk/ghostty by the lead. Used during the
                            build only; gone now.
docs/native-client.md       this file
```

## Rules for everyone working on this

1. **Ownership is by directory.** You edit only what your brief assigns.
   If you need a change elsewhere, make the smallest possible edit only if
   your brief allows it, and list it in your report; otherwise describe the
   change you need and let the lead route it.
2. **Edits to pre-existing Ghostty files are the scarce resource.** Every
   one makes rebasing onto upstream harder. Prefer a new file plus a
   one-line hook (`@hasDecl` checks are the house pattern, see
   `src/Command.zig:145`). Every such edit is recorded in
   `gtk/ghostty/WEBMUX.md` › Upstream edits (file, what, why) by whoever
   makes it.
3. **The Electron client is the spec** for behaviour (`gtk/PARITY.md`
   points at the code). Where the native client deliberately differs, add
   it to Deliberate deviations below with the reason. Anything else that
   differs is a bug.
4. **Pure packages never touch GTK** (`src/webmux/`). They expose blocking
   or thread-safe APIs and invoke callbacks on their own threads; the shell
   marshals to the GTK main loop. GTK objects are touched only on the main
   thread.
5. **Do not open windows on the user's desktop session.** This machine has
   a live GNOME Wayland session (`WAYLAND_DISPLAY=wayland-0`); never run
   the app against it. Use the headless recipe in `WEBMUX.md` (a nested
   headless compositor, the app's control socket and its built-in
   screenshot command).
6. **Verify by running, not by reading.** A feature is done when it has
   been exercised (unit test, harness check, or a screenshot you looked
   at), and your report says which. State plainly what you did not verify.
7. **No git commits, no pushes, no network side effects** beyond fetching
   build dependencies. Leave work in the tree.
8. Zig is 0.17. APIs differ from what you remember (`std.Io` in
   particular); read the standard library source in the toolchain and the
   surrounding Ghostty code before writing against memory. Unix socket
   paths are capped at 108 bytes: root test sockets in a short `/tmp/wm-*`
   directory.

## Architecture

```
webmux-gtk (one process)
  GTK main thread ── application, window, header pills, connection page,
  │                  per connection: strip of columns → panes (terminal | files)
  │
  ├─ per connection: conn.Supervisor (own thread)
  │     deploy over ssh → read advert → ssh -N -L <local unix socket>:<remote http socket>
  │     liveness probe through the tunnel, retry/backoff, state → main loop
  │
  ├─ per terminal pane: core Surface
  │     renderer thread ── renders, exports DMABUF frames → RenderSurface widget
  │     io thread (Termio) + termio.Webmux read thread
  │         WebSocket /ws?session=<id> over the tunnel socket
  │         snapshot → reset terminal, feed; output → feed
  │         writes (keys, query replies) → {type:"input"}; resize → {type:"resize"}
  │         title / exit / error / paste-result / open-url / link up-down → pane (main loop)
  │
  └─ HTTP API calls (sessions, fs/*, paste) and SSE (fs/watch): net.Client on worker
        threads, results marshalled to the main loop
```

### The backend seam

`src/Surface.zig` `init` hard-wires `termio.Exec`. The single hook: if the
apprt surface declares `termioBackend`, the core calls it and uses the
backend it returns instead of building an `Exec`. `termio.Backend` gains a
`webmux` variant next to `exec`. The shell's surface supplies the tunnel
socket path, the session id, and an event sink.

Backend contract (mirrors `electron/ui/app.js` `connect()`):

- attach: connect, WebSocket upgrade on `/ws?session=<id>`; first frame is
  `snapshot` → full terminal reset then feed `data`, under the renderer
  lock so no half-reset frame is drawn; then report the current grid size.
- `output` → `Termio.processOutput`.
- writes from the core (`queueWrite`) → `{type:"input",data}`; data is
  UTF-8 text in JSON, as the host expects.
- `resize` → `{type:"resize",cols,rows}`.
- `title`, `session-title`, `exit`, `error`, `paste-result`, `open-url` →
  event sink (the pane decides what to do).
- socket drop while the session is alive → print the same dim
  "[disconnected — reconnecting…]" line the Electron client prints, report
  link-down to the sink, reconnect with backoff 1 s doubling to 10 s; the
  fresh snapshot repaints. Never reconnect after `exit`, `error`, or
  surface close.
- a thread-safe `send` for the pane's side-channel frames (`paste-image`,
  `clipboard-sync`).

### Tunnel

Same ssh options as the Electron client, with one change: the local end is
a unix socket (`$XDG_RUNTIME_DIR/webmux-gtk/<host-slug>.sock`, 0700
directory, `StreamLocalBindUnlink=yes`) instead of `127.0.0.1:<port>`.
Everything local connects to that socket.

### Local state

- `$XDG_CONFIG_HOME/webmux-gtk/config.json`: profiles, settings, last
  profile (same shape as the Electron `config.json` minus `passwordEnc`
  and `localPort`).
- Passwords: the Secret Service via libsecret, keyed by profile id. Never
  written to `config.json`, never logged.
- `$XDG_STATE_HOME/webmux-gtk/layout/<host-slug>.json`: the layout and
  file-browser state for that host+instance (what the Electron client
  keeps in localStorage under the `webmux://<host-slug>` origin).
- `$XDG_STATE_HOME/webmux-gtk/logs/webmux.log` (+ `.1`, rolled at 1 MB).
- Payload to push: `$WEBMUX_PAYLOAD_DIR`, else
  `<exe dir>/../share/webmux-gtk/payload`, else `electron/payload` found by
  walking up from the executable (a checkout). Same tarballs and
  `payload.json` that `deploy/build-payload.js` writes.
- Ghostty configuration: the app does not read `~/.config/ghostty`. Its
  terminal defaults reproduce the Electron client (font, 13 px, 5000 lines
  of scrollback, blinking cursor, the two colour schemes).
- Application id `me.puntium.webmux.gtk`; binary `webmux-gtk`.

## Phase 2: the shell's feature areas

The seams between areas are code: `src/apprt/webmux/iface.zig` (written by
the lead; read it first, do not edit it). In short: the chrome owns
connections and gives each one a workspace; the workspace owns layout,
sessions and pane chrome and gets its panes from per-kind factories; a pane
owns only the inside of its rectangle; shell-wide services (status
messages, URL handling, the connection log, settings) are reached through
`iface.services` / `iface.settings`, whose defaults only log.
The connection engine is reached through `iface.engine` (owned by the
chrome). Actions that cross areas are named in `iface.actions`
(`pane.<command>` on the workspace widget, `app.show-settings`,
`app.show-log`, `app.show-connections`); `iface.hooks.clipboardSync` is the
terminal feature's clipboard-image sync, triggered by the chrome.

| Area | Directory (owned) | Registers | PARITY sections |
| --- | --- | --- | --- |
| Terminal pane | `pane.zig`, `Surface.zig`, `terminal/` | `iface.factories.terminal` | 1, 2, 14 and the pane-local parts of 3 |
| Workspace | `workspace/` | `iface.workspace_factory` | 3 (sessions), 4, 5 (pane chords) |
| File browser | `files/` | `iface.factories.files` | 6 |
| Chrome | `window.zig`, `application.zig`, `chrome/` | `iface.services.connLog`, drives `conn.Engine` | 7, 8, 9, 5 (app shortcuts) |
| Panels | `panels/` | `iface.services.status`, `.url`, writes `iface.settings` | 10, 11, 12 |

(Directories are under `src/apprt/webmux/`.) Each engineer works in their
own clone, `gtk/wt/<area>`, copied from the integration tree. Shared shell
files (`window.zig`, `application.zig`, `shortcuts.zig`,
`control/commands.zig`, `style.css`) belong to the chrome; other areas may
add only registration lines to them (a `register()` call, shortcut table
rows, a control-command import, a CSS file load) and list each such line in
their report so the lead can merge it. Each area keeps its CSS in its own
file and its control-socket commands in its own `control.zig`.

**Dev mode** (so every area can run against a real host with no ssh):
`webmux-dev/headless start --host` starts an isolated local `webmux-host
serve` and the app with `WEBMUX_GTK_DEV_SOCKET` pointing at it. In dev mode
the window shows one connection view for that socket (slug and name `dev`)
with no chrome around it: the registered workspace, or, when no workspace
is registered, a single terminal pane attached to the host's first session.
An area tests itself there; see `WEBMUX.md` › Dev mode.

## Build and test

Everything runs in the fork's nix dev shell (`gtk/ghostty/flake.nix`,
Ghostty's own). Exact commands, the headless UI recipe and the control
socket are documented in `gtk/ghostty/WEBMUX.md` (written by the
foundation work). Pure packages: `zig test src/webmux/<name>.zig` in that
shell. A local host for tests needs no ssh:
`WEBMUX_SOCKET=/tmp/wm-x/h.sock host/dist/webmux-host-linux-x64 serve`
(see `docs/native-host.md` › Verification for an isolated HOME/XDG setup).

## Deliberate deviations from the Electron client

1. Tunnel local end is a unix socket, not a loopback TCP port (other local
   users cannot reach it; no port to pick or pin). The profile's
   `localPort` field is gone.
2. No `webmux://` origin: per-host state is files under XDG dirs keyed by
   the same host slug.
3. Passwords live in the Secret Service, not in `config.json` as
   ciphertext.
4. Every pane's terminal stays attached while its connection is open
   (the Electron client only opens sockets for panes in the DOM).

5. Layout model input hardening (`src/webmux/layout`): parsed layouts drop
   non-string and empty pane ids, treat numeric-string weights as 1, cap
   file-browser state at JSON objects 64 levels deep; a live-session list
   with repeated, empty or `files-` ids ignores those entries (app.js
   would create duplicate columns); a divider drag with a zero or invalid
   span is refused instead of writing NaN weights.
6. "New terminal below" places the pane below whatever is focused when the
   session exists (app.js picks the column before the server call and the
   position after, so a focus change in between lands it at the top of the
   old column).
7. Profiles carry an `id` (16 hex chars, stable across renames) so the
   keyring entry survives a rename; unknown profile fields are dropped.
8. A second live connection to the same host+instance is refused (both
   would share one tunnel socket); the Electron client allows it on
   separate ports.
9. The askpass script lives in `$XDG_RUNTIME_DIR/webmux-gtk/`, not the
   config dir. That directory must be a non-symlink directory owned by the
   user and is forced to 0700; without `XDG_RUNTIME_DIR` the fallback is
   `/tmp/webmux-gtk-<uid>`. A socket path over 107 bytes shortens the
   slug's base and keeps its hash.
10. The instance name is validated at connect and reconnect as well as at
    save. ssh stderr is split into lines across reads; a killed ssh child
    gets SIGKILL 2 s after SIGTERM.
11. Connection-log fields: `socket` replaces `localPort`; the probe line
    has no `status` field and `client started` no `electron` field.
12. After Restart Sessions the engine only reports completion; reloading
    the panes is the shell's job.
13. Snapshots are replayed at the remote grid size and the terminal is then
    resized to the local grid (the Electron client replays at the local
    size, which misplaces the cursor and overwrites lines when the sizes
    differ). Replies a replay provokes are discarded, never sent as input.
14. Writes made before a pane's first attach are held and sent when the
    socket opens; after that, writes while disconnected are dropped as in
    the Electron client.
15. The "[disconnected — reconnecting…]" and "[session exited: N]" lines
    are printed by the backend, not the pane.
16. Terminal selection colours are the xterm overlay blended to an opaque
    colour; there is no separate inactive-selection colour (T-05, T-06).
17. OSC 8 hyperlinks show the pointer cursor on hover but are underlined
    only with Ctrl held (Ghostty's behaviour; changing it needs a core
    edit). Plain-text URLs underline on hover as in the Electron client
    (T-25).
18. Wheel scrolling uses Ghostty's 3 lines per notch, not Chromium's
    pixel-based step (T-27).
19. `session-title` frames are not used: every pane has its own socket and
    its own `title` (T-40, follows from deviation 4).
20. A window resize recomputes the column widths at once (the Electron
    client debounces 100 ms).
21. The unfocused fade is drawn as two colour quads over the pane body,
    which gives the same pixels as the Electron client's overlay.
22. Passwords use the Secret Service "plain" session algorithm over the
    session bus (one item per profile in the default collection,
    attributes `xdg:schema=me.puntium.webmux.gtk.Password`,
    `profile-id`); which profiles have a password is mirrored, ids only,
    to `$XDG_STATE_HOME/webmux-gtk/keyring.json`.
23. The retry countdown on the connection page ticks down live (the
    Electron client shows the fixed delay). A host view shows a one-line
    placeholder before it has content (the Electron client shows a blank
    page).
24. Zoom scales the visible host's terminal panes only.
25. Pane menu items stay enabled with no host in front and do nothing.
26. Link chooser: for `mailto:` the button opens the default mail
    application (dead in the Electron client); other non-http schemes
    offer Copy only. Plain clicks and shift-clicks act only on http(s).
27. The fade slider previews live and saves 400 ms after it stops or on
    close. The log window keeps at most 3000 rows.
28. File browser: the preview stays on screen during a same-file refresh
    (the Electron client flashes "…"); the preview header's date is always
    en-US style; a saved directory that is not `~`, `~/…` or absolute
    falls back to `~`; an unreachable host shows the transport error's
    name in the column.
29. Markdown is rendered by the client's own parser, not `marked`. Not
    covered: footnotes, definition lists, math, emoji shortcodes, front
    matter, heading anchors, multi-line link reference definitions.
    Remote (http) images are not fetched; their alt text is shown.
    Rendered text is not selectable.
30. Dev mode (`WEBMUX_GTK_DEV_SOCKET`) starts the connection engine too
    (settings store, connection log, keyring; no connections), so every
    area behaves there as in the real app.
31. App shortcuts still run while a dialog is open (for example
    Ctrl+Shift+O over the settings dialog); only pane chords are blocked
    there, as PARITY K-18 requires.
32. Settings opens with no host in front as well (E-10).
33. WebP and AVIF images do not preview (no loader in the app's
    environment); the Electron client previews what Chromium decodes
    (F-33).
34. Connection-log lines about a host's view say "workspace" instead of
    "page"; the Electron client's "loading app page" lines have no
    counterpart (G-07).
35. Layout saves are debounced 250 ms.
36. A live connection is keyed on the host+instance of its current connect
    cycle. Editing a connected profile's host, port, instance or options
    changes the stored profile only and applies at the next Connect or
    Reconnect; automatic retries keep what the connection holds (the
    Electron client let a retry pick up the edit). A rename applies at
    once. The "already connected" refusal covers every connection that
    holds or is binding a socket, and Reconnect checks it too.
37. A cleared or deleted password is recorded as cleared in
    `keyring.json` at once and never used again, even if the keyring was
    down at the time; the keyring item is removed when the keyring next
    answers. Saving a profile with a new password stores the password
    first and saves nothing if that fails. With no Secret Service
    running, a profile that has a saved password cannot connect (the
    Electron client's ciphertext needs no running keyring).
38. A `config.json` that does not parse is renamed to
    `config.json.broken-<UTC time>`, reported in the connection log and
    in a banner on the connection page, and never overwritten; if the
    rename fails, saves are refused.
39. The ssh port must be a whole number from 1 to 65535 (blank = ssh's
    default); the form and connect refuse anything else (the Electron
    client passes it to ssh).
40. Shortcut matching: app shortcuts and the letter/bracket pane chords
    match the physical key (US position), as the Electron client matches
    `event.code`; Enter and the arrows match the key's meaning in the
    active layout (`event.key`); zoom keys match the layout's character.
41. The strip's 10 px horizontal scrollbar is not shown while a closing
    animation is holding the old extent open (the Electron client shows
    it then).
42. Terminal cell: 7×17 px at scale 1 (`adjust-cell-width = -1`), the
    Electron client's WebGL cell. The native pane can still be one column
    narrower than the Electron client, whose fit calculation ignores the
    holder's 4 px padding so its canvas runs over the right padding.
43. Inline code in rendered markdown has square corners (a Pango text
    background cannot be rounded).
44. A download that is interrupted by quitting the app leaves its hidden
    temporary file (`.<name>.<hex>.webmux-part`) in the target folder.
45. The "session exited" connection-log line is written when the pane
    closes, about 1.2 s after the exit, so it follows the socket-closed
    line.
46. Status messages belong to a host: a message from a host that is not
    in front is held for its remaining time and shown if that host comes
    to the front in time; app-wide messages always show.
47. Keypad Enter and the keypad arrows count as Enter and the arrows in
    pane chords (as in app.js), so Ctrl+Shift+KP_Enter never reaches a
    terminal.
48. Profiles in `config.json` that share an id (or have a missing or
    malformed one) all get new ids on load, and the secret stored under
    the shared id is cleared: neither copy keeps the password, because
    nothing shows which host it was saved for. The repair is reported in
    the connection log and the page banner.
49. A `config.json` that parses but has wrong types is repaired in
    memory, each repair is logged and listed in the banner, the original
    text is kept as `config.json.before-repair-<time>`, and nothing is
    written until the next save.
50. A link chooser raised by a host that is not in front is closed and
    raised again (same URL and pane) when that host returns, rather than
    hidden.
51. Zoom in is also bound to Ctrl+plus and keypad plus/minus by key
    meaning, for layouts where + is unshifted.
52. While a connected profile has an unapplied edit, its card says which
    host the connection is on until Reconnect applies the edit.
53. Downloads through the save dialog are added to the desktop's
    recent-files list (GTK's chooser does this; the Electron client's
    save dialog does too). The app sets a program name so the entry is
    valid.
54. A file that grows while its preview is scrolled to the end keeps its
    scroll position and does not follow the end (as the Electron client).
55. The first display of a very large directory builds 80 rows at once
    and the rest 100 per idle callback; column widths are estimated from
    per-character measurements with the likely-widest names measured
    exactly.
56. In rendered markdown an image inside a paragraph of text is shown on
    a line of its own.
57. Scrolling: a wheel notch is 3 lines at every display scale (deviation
    18). A touchpad follows what the Electron client was measured to do
    (Chromium on Wayland turns 1 px of finger travel into 12 CSS px; an
    80 px swipe is 56 lines of 17 px), with Alt multiplying by 5.
58. Double-click selects by xterm's word rule (separators space, brackets,
    quotes and backtick), but dragging after a double-click extends by
    Ghostty's word rule (a core behaviour).
59. Session titles: runs of whitespace collapse to one space; C0 control
    characters and DEL show as control pictures (as Chromium draws them),
    C1 controls and invalid UTF-8 as U+FFFD.
60. Typed input that arrives while a text paste's clipboard read is in
    flight is held (at most 1 s) and sent after the pasted text; not when
    the application has the Kitty keyboard protocol on.
61. An unpaired surrogate escape in a frame from the host is replaced by
    U+FFFD instead of dropping the frame.
62. At startup, keyring secrets whose id no profile references are
    deleted (ids are compared case-insensitively, and ids found in
    set-aside `config.json.broken-*` and `.before-repair-*` files count
    as referenced). The clean-up is skipped entirely unless `config.json`
    exists, parses and has at least one profile.
63. Touchpad scrolling keeps the fractional remainder across events
    (pixels on the normal screen, lines on the alternate screen and with
    mouse reporting), as xterm.js does, so the distance depends only on
    the total swipe.
64. With no folder remembered for a connection, the save dialog opens in
    the XDG download directory, else `~/Downloads` if it exists, else the
    home folder.
65. In the file browser only a horizontal wheel or touchpad scroll or a
    press on the strip's scrollbar counts as the user scrolling away from
    the right edge; any other change to a pinned view is undone on the
    next frame.
66. The header is a standard GNOME header bar (`AdwHeaderBar`), not a
    copy of the Electron header strip (the user's direction, 2026-11-05,
    after the first run on a real desktop). It is the window's title bar:
    dragging its empty parts moves the window, and it carries the window
    controls. Its buttons are flat icon buttons with libadwaita's spacing
    and colours: new terminal, new file browser, settings, connections,
    menu. With no connection open the centre reads "webmux". The pills
    keep their look. Overrides W-02 (height), W-10 and W-17 (button
    styling) in `gtk/PARITY.md`.
67. Connections and Settings are one native `AdwPreferencesDialog` with
    two pages, Connections and General, not copies of the Electron
    connection page and settings modal (the user's direction, 2026-11-05).
    They use libadwaita's rows, spacing and colours, so the Electron
    palettes are gone from them; the status dots use the header's colours.
    Under the dialog the window shows a small landing view when no host is
    in front. The dialog opens at startup, when the front host disconnects
    and when a connection that never came up fails; Ctrl+Shift+O opens it
    over the host in front, which stays in front. Showing a host closes
    it. The dialog stays alive when closed, so a half-typed form is still
    there when it reopens; opening Settings cancels the form. A click on a
    profile row opens its form as a subpage, which also has Restart
    Sessions and Delete Profile (no ⋯ menu), and these ask in an alert
    dialog instead of relabelling in place. `AdwEntryRow` has no
    placeholder text: the examples moved into group descriptions and the
    password hint into its row's title. Settings has no Done button (the
    dialog's close button instead). While the dialog is up the header is
    dimmed like the rest of the window, so pills, ☰ and ⚙ cannot be
    clicked. App shortcuts still work. Overrides W-04, W-05 (for the dialog), W-17,
    W-20…W-32 and E-10…E-14 in `gtk/PARITY.md`.
68. The link chooser is a native `AdwAlertDialog` with the heading `Link
    options`, not a copy of the Electron modal, so `panels/ui.zig` and the
    `.modal*` CSS are gone. It uses libadwaita's colours and sizes. Its
    buttons stack in a narrow window. The URL scrolls with the dialog's
    message area instead of stopping at 30% of the window height.
    A click on the backdrop no longer closes the chooser or the preferences
    dialog: libadwaita's floating dialogs have no such behaviour, and it
    needed a hook on a private widget. Escape closes both. The preferences
    dialog is no longer forced to float, so in a small window it is a
    bottom sheet, where a click outside closes it. Overrides M-03, M-04 and
    the backdrop in E-10 in `gtk/PARITY.md`.
69. Layout animations are tuned for a large display on an integrated GPU
    (the user's direction, 2026-11-06, after the strip stuttered on a 6K
    display; measurements and reasons in `gtk/ghostty/WEBMUX.md` ›
    Performance). Where that differs from the Electron client:
    - A move takes 200 ms up to 600 px of travel and longer beyond that,
      growing with the square root of the distance to at most 320 ms
      (app.js: always 200 ms). Overrides the 200 ms in L-31.
    - A move ends on the frame clock. A frame that comes late does not
      make the motion skip ahead; the move runs late instead, by up to
      250 ms. The timeout that ends a move whose clock is not running
      fires 50 ms after the move should have ended and waits while frames
      are still being drawn. Overrides L-39's 250 ms bound.
    - While the strip moves (a layout animation, and the scroll that
      follows it), terminals hold still: a terminal whose pane changed
      size keeps drawing at its old size and takes the new one (and tells
      the host) once the move's last frame is out; a new terminal attaches
      at once but draws nothing until it has arrived; a closed pane is
      torn down after that frame. The Electron client refits at the start.
      Still one resize per pane per change (L-31).
    - A new pane fades in under the strip's colour at 1 − p instead of at
      opacity p, which looks the same over the strip (L-33).
    - Offsets and clips of moving things, and the strip's scroll offset,
      sit on device pixels (whole CSS pixels in app.js).
    The unfocused fade (L-24) gives the same pixels as before, by a colour
    matrix on the terminal's texture instead of two quads over it.

(Add to this list; do not silently differ.)

## Zig 0.17 notes collected from the team

- `**` array repetition is gone: use `@splat`. Enum type info has
  `field_names`/`field_values` (or use `std.enums.values`).
- `std.ArrayList` is unmanaged (`.empty`, pass the allocator on each call);
  `std.json.Value` arrays are `std.array_list.Managed`.
- JSON output: `std.json.Stringify` writing to a `*std.Io.Writer`
  (`std.Io.Writer.Allocating` for in-memory).
- Do not return a struct holding an `ArenaAllocator` from a literal that is
  still allocating from that arena; compute first, then build the struct.
- `nix develop . --accept-flake-config -c …` avoids the flake-config prompt.
- No `std.Thread.Mutex`: use `std.Io.Mutex` (`.init`,
  `lockUncancelable(io)`, `unlock(io)`) and `std.Io.Condition`.
- `std.posix` lost open/write/pipe/stat: with `-lc` use `std.c.*`; raw
  statx is `std.os.linux.statx`. `std.fmt.bufPrintZ` is now
  `bufPrintSentinel(buf, fmt, args, 0)`. `{f}` calls a type's
  `format(w: *Io.Writer)`. Declarations may not sit between fields.
- Processes: `std.process.spawn(io, .{...})`; PATH lookup uses the
  parent's env, not `environ_map`; `Child.wait(io)` closes the pipe Files;
  `std.os.linux.pidfd_open` gives a pollable exit fd.
- Time: `Io.Clock.awake.now(io).toMilliseconds()`,
  `io.sleep(.fromMilliseconds(n), .awake)`; random: `io.random(&buf)`.
  Tests: `std.testing.io`, `std.testing.environ.createMap(alloc)`.
- `socat` and `python3` are on PATH. Name `/tmp/wm-*` scratch dirs
  uniquely; several engineers use that prefix.
- Run out-of-memory (`checkAllAllocationFailures`) tests in Debug; under
  ReleaseSafe they can report `NondeterministicMemoryUsage`.
- Headless Chrome is installed (`google-chrome --headless=new
  --ozone-platform=headless`, with `WAYLAND_DISPLAY` and `DISPLAY` unset):
  useful for measuring what the Electron client's real CSS lays out.

## Rulings on `gtk/PARITY.md`

The checklist ends with Ambiguities (A-nn) and Not carried over (N-nn).
The lead's rulings, which are part of the spec:

- A-01, A-02, A-06: the code is right, the docs are stale. Follow the code.
- A-03: add Ctrl+Shift+C to copy the terminal selection (not a pane chord).
- A-04: Ctrl+Shift+V paste is a requirement, alongside Ctrl+V (C-04…C-06).
- A-05, A-10: use native wording ("system keyring", "file manager"; no
  mention of browsers or right-click paste).
- A-07: fix, do not copy: retry the session-list fetch with backoff while
  the connection is up, and show the connection's state meanwhile.
- A-08: fix: a failed session create shows a status message.
- A-09: dead style. An exited terminal is not dimmed.
- A-11: convert an image the host does not accept to PNG before sending.
- A-12: the theme list and its validation live in one place (the settings
  model); unknown ids fall back to dark.
- A-13: file-browser panes count in the pane total.
- A-14: sync the clipboard image to the visible host on window focus and
  whenever the visible host changes.
- A-15: no reload command (there is no page); Reconnect covers it. Full
  screen and Quit live in the menu and take no terminal keys.
- A-16: show the "cleared" marker.
- A-17: keep Backspace as a delete key in the file browser.
- N-01…N-12, N-14, N-15: accepted as not carried over; the outcomes they
  served stay (the items they cross-reference).
- N-13: own config path, no legacy migrations. One addition: on first run
  with no `config.json`, import profiles from the Electron client's
  `$XDG_CONFIG_HOME/webmux/config.json` if present (without passwords and
  `localPort`). The two clients can be used side by side.
- N-16: a header-bar menu button with the same items replaces the hidden
  Alt-tap menu bar.

## Rulings for the fix round (after the audit)

- **Real input is the test.** A fix for something a user does with keys
  or a mouse is verified with `webmux-dev/realkeys` and
  `webmux-dev/realpointer` (real events through the compositor), not only
  through control-socket commands, and each fixed defect gets a regression
  check in the area's smoke that would have caught it.
- Keys (T-12, T-13 and the Shift+PageUp, Insert, Alt+arrow family): when
  the application has not enabled the Kitty keyboard protocol, the
  terminal sends what xterm.js 5.5 sends. Go through xterm's key table
  systematically rather than key by key. With the Kitty protocol enabled,
  Ghostty's encoder is used unchanged.
- Chords are matched by physical key position (as the Electron client
  matches `event.code`), so they work on every keyboard layout (K-16).
- App shortcuts work while an in-window dialog is open; pane chords do not
  run while any modal is up, the file browser's in-pane confirmation
  included (K-18, deviation 31 must be true as written).
- Padding is 4 px and scrollback keeps at least 5000 lines (T-09, T-03).
- Settings may be opened from the connection page (the header button is
  enabled there too); the Electron client only allows it on a host page
  (E-10). Recorded as deviation 32.
- WebP and AVIF previews need an image loader the app does not ship
  (F-33): deviation 33 until packaging provides one.
- Connection-log wording says "workspace" where the Electron client says
  "page", and there are no "loading app page" lines (G-07): deviation 34.
  The per-session socket events of G-08 are required.

## Rulings for the second fix round (after the re-check)

- Blockers, in order: the header menu must return keyboard focus to the
  pane that had it, and its Edit items must act on that pane; a download
  through the save dialog must not write invalid XML into
  `recently-used.xbel`; two profiles must never share a keyring secret
  (duplicate or missing ids in `config.json` are repaired on load, and
  that is reported); a long profile name or host must not widen the
  window.
- Scrolling distance matches the Electron client for a touchpad as well
  as a wheel, at every display scale; deviation 18 (3 lines per wheel
  notch) stays.
- The preview keeps its scroll position when the open file's content
  changes, as far as the new content allows.
- The ssh port accepts only what deviation 39 says: a whole number from 1
  to 65535 written in decimal, or blank.
- A `config.json` that parses but has wrong types is repaired in memory,
  and the repair is reported in the connection log and the page banner
  before anything is written back.
- No smoke check may depend on a Debug-only log line: every smoke passes
  on both `zig-out/bin/webmux-gtk` and the release binary.
- Left as they are (same in the Electron client, or host-side): rename
  trimming surrounding spaces; names that are not valid UTF-8; shims lost
  inside tmux or a login shell.

## Status

| Phase | Work | State |
| --- | --- | --- |
| 0 | Stock Ghostty GTK builds in the nix shell on this machine | done (4m28s cold, exit 0) |
| 0 | `gtk/PARITY.md` feature inventory | done (317 items, 14 areas; rulings above) |
| 1 | Foundation: new apprt skeleton, build flag, terminal surface widget, headless recipe, control socket, `WEBMUX.md` | done: `-Dwebmux=true` builds `webmux-gtk`; `webmux-dev/smoke` passes (lead re-ran, looked at the screenshot); 3 upstream edits |
| 1 | `src/webmux/net` | done: 13 tests incl. live against a local host; merged into gtk/ghostty |
| 1 | `src/webmux/conn` | done: 27 tests pass (`zig test -lc src/webmux/conn.zig`, lead re-ran), incl. deploy against a fake ssh and the real payload. Not yet run against a real sshd |
| 1 | `src/webmux/layout` | done: 118 tests pass (`zig test src/webmux/layout.zig`, lead re-ran), incl. a 1,600-step differential trace against app.js |
| 2 | `termio.Webmux` backend | done: headless suite against a real host, and a real-app run in stock Ghostty via a throwaway hook; merged into gtk/ghostty (4 more upstream edits) |
| 2 | Workspace: strip widget, pane chrome, animations, sessions, pane chords | done and merged into gtk/ghostty: workspace smoke passes there (lead re-ran, looked at a screenshot). Open: strip scrollbar, `smoke --pane`'s unknown-session step needs rewriting for the workspace |
| 2 | File browser pane | done: its smoke passes in its clone (lead re-ran, looked at the markdown screenshot); `files/` copied into gtk/ghostty, registration and workspace wiring handed to integration |
| 2 | Chrome: window frame, header pills, connection page, engine wiring, keyring | done and merged into gtk/ghostty: chrome smoke (fake ssh, real payload deploy, tunnel kill and heal) passes there (lead re-ran) |
| 2 | Panels: settings, log window, status messages, link chooser | done and merged; its smoke passed in its clone, fails in the merged tree until the chrome loads settings from the engine (integration) |
| 1.5 | Seed: backend wired into the terminal pane, terminal pane factory, feature registration, dev mode (`headless start --host`), remote smoke | done: `webmux-dev/smoke --host` passes (lead re-ran): typing, server restart with one link-down and identical repaint, exit closes the pane |
| 2 | Terminal pane features: paste, image paste, clipboard sync, links, scrolling/selection | done and merged into gtk/ghostty: `webmux-dev/smoke --pane`, `--host` and the local smoke pass there (lead re-ran) |
| 3 | Integration of all five areas in gtk/ghostty | done: `webmux-dev/smoke --all` runs 7 smokes, all pass; shell tests pass; stock Ghostty still builds (lead re-ran all three, looked at screenshots of the connected app and the connection page). About 39,000 lines of new Zig; still 7 upstream edits |
| 3 | Independent parity audit against `gtk/PARITY.md` (five auditors, results in `gtk/audit/`) | done: 338 rows, 270 pass, 29 fail, the rest recorded deviations/rulings, N/A or judged by reading; plus defects outside the checklist |
| 3 | Fix round from the audit (five engineers; work lists in `gtk/audit/*.md`) | all five areas' fixes merged into gtk/ghostty; builds, unit tests pass; 4 of 7 smokes pass, 3 fail where the fixes meet (Shift+PageUp not reaching the pane, two smoke checks tripped by new log lines) |
| 3 | Fix-round integration | done: all 7 smokes pass (three runs by the engineer, one by the lead), shell tests, engine 31/31, layout 118/118, net 13/13, stock build; xterm key table 1,260 combinations, 0 differ, in the merged tree (reported); status messages are per host; one keyboard tool (`realkeys-xkb`) |
| 3 | Independent re-check of every audit failure with real input (two verifiers, `gtk/audit/recheck-*.md`) | done: 100 findings re-checked; 62 fixed, 3 partly, 10 not fixed (most host-side, shared with the Electron client, or low severity), 8 recorded deviations, 16 cannot be verified headlessly; 16 new defects, four of them blocking daily use |
| 3 | Second fix round (three engineers): the blockers and the rest of the re-check's findings; smokes made independent of Debug-only log lines | done and merged. Lead's run on the final tree: all 7 smokes pass on the Debug binary and on a freshly built release binary; engine 33/33, layout 118/118, net 13/13, shell tests pass; stock Ghostty builds. About 44,000 lines of new Zig; 7 upstream edits in 6 files |
| 3 | Final independent check on the release binary (`gtk/audit/final-check.md`); `gtk/PARITY.md` ticked from the audit records | done. Three of four blockers confirmed fixed; the fourth is fixed for panes but focus returning to a text field selects its whole content, so the next key replaces it (must fix). Two should-fix: an unfocused file browser scrolls away from its listing; touchpad scroll distance depends on how the touchpad slices the swipe. A day of use otherwise without trouble; key-to-echo 1.5 ms median locally, 2.4 ms through the tunnel |
| 3 | Third fix round (short): the text-field select-all, the two should-fix items and the minor leftovers | done and merged: the text-field case reproduced fixed by the lead with real input; touchpad distance independent of slicing; the file browser no longer scrolls on focus changes; a close-handshake race found by a flaky smoke was fixed at its cause |
| 3 | Final state (lead's run, 2026-11-05) | both binaries rebuilt; all 7 smokes pass on Debug and on release; `smoke-host` 5/5 more on each; engine 33/33, layout 118/118, net 13/13, shell tests pass; stock Ghostty builds; nothing left running. About 44,000 lines of new Zig; 7 upstream edits in 6 files. `gtk/PARITY.md`: 300 of 317 ticked, 3 awaiting an independent re-check, 12 judged by reading only, 2 n/a |
| 4 | After the first run on a real desktop (2026-11-05) | header replaced by a standard header bar (deviation 66); `make linux-client` and `make linux-client-run` added; all 7 smokes pass on release, the chrome smoke on both binaries. Fork published at <https://github.com/puntium/ghostty>, branch `webmux-shell` (one more upstream edit: `.gitignore`) |
| 3 | Release build (`zig-out-release/`, ReleaseFast, 34 MB, 5m14s) and performance check | built; 1.3 MB of terminal output displays in 0.57 s (Debug: over 60 s); worst control-socket round trip during a reconnect and replay 0.10 s (Debug: 2.8 s), measured by the lead while two verifiers loaded the machine. 4 of 7 smokes pass on it; the 3 failures read Debug-only log lines (to fix after the re-check) |
| 3 | Release build and performance check, packaging, docs | not started |
