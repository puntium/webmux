# Native macOS client: `webmux.app` (Swift/AppKit shell on GhosttyKit)

Status (2026-11-07): **phases 1–3 done (seam, GhosttyKit, dev host; Swift foundation; the four feature areas, integrated into one app); phase 4: the fork pass is done; the planned PARITY audit was dropped on 2026-11-07 (good enough to use; tweaks come from use).** Remaining work is the Open items list. This is the
contract the client is built against, in the spirit of
[native-client.md](native-client.md) (the Linux client). It is deliberately
specific; when the code and this document disagree, fix one of them in the
same change. The Status table at the bottom is kept current so that work
can resume after an interruption.

## Goal

A native macOS client with every *function* of the Electron client
(`electron/`, checklist in `gtk/PARITY.md`), presented the way a Mac app
is expected to look and behave. Pixel parity is not a goal; functional
parity is. Where the Electron client copies a web look (header strip,
pills, custom modals), the Mac client uses the native equivalent (toolbar,
standard menus, sheets, Settings window). The decision record is the
user's direction of 2026-11-06: "as native as possible, sharing with Linux
where it makes sense; config UI and things like that all native."

Architecture ("option A"):

- **Ghostty's core is kept as is** (terminal state, Metal renderer, fonts,
  input encoding, selection) and reached through Ghostty's own embedding
  library: `GhosttyKit.xcframework`, built from **the same fork** the Linux
  client uses (`gtk/ghostty`, branch `webmux-shell`). The fork's termio
  backend `src/termio/Webmux.zig` (WebSocket instead of a pty) is compiled
  into the library.
- **The shell is Swift/AppKit**, in `mac/`. It owns connections, the ssh
  tunnel, deploy, Keychain, profiles, settings, the layout strip, panes,
  the file browser, menus and dialogs. Nothing of the GTK shell
  (`src/apprt/webmux/`) or the pure-Zig packages (`src/webmux/`) is linked
  into the Mac app; they are the *reference implementation* (audited
  against PARITY) that the Swift code mirrors.
- **The host (`host/`) and its protocols are unchanged.** The Electron and
  GTK clients keep working against the same host. `host/build.sh` runs on
  macOS as is (zig cross-compiles the static Linux binaries; verified
  2026-11-06).

Non-goals: Ghostty features the Electron client does not have (tabs,
splits, quick terminal, inspector, command palette); the App Store; Intel
Macs in the first version (the build is `arm64` only, the xcframework
`-Dxcframework-target=native`); binary snapshots.

## Why GhosttyKit, and what that costs

`include/ghostty.h` is labelled by upstream as "libghostty-internal": the
only consumer is Ghostty's own macOS app and there is no stability
promise. Upstream ships no prebuilt GhosttyKit (only the VT-only
`ghostty-vt.xcframework`). So:

- we build GhosttyKit ourselves from the fork, pinned at the fork's base
  (`vt-1.0.0` today) and rebased with it;
- the Swift wrapper that talks to the C API is **copied from Ghostty's
  `macos/Sources/Ghostty/` and trimmed**, and must be re-diffed against
  upstream at every rebase (the files carry a header naming their origin
  commit);
- every edit to a pre-existing Ghostty file is listed in
  `gtk/ghostty/WEBMUX.md` › Upstream edits, as on Linux.

The alternative that is officially stable, `libghostty-vt`, stops at
terminal state and would mean writing the renderer and font stack
ourselves. Rejected.

## Toolchain

| Tool | Why | Pin / source |
| --- | --- | --- |
| Zig 0.17.x | builds GhosttyKit (and, via `host/build.sh`, libghostty-vt + the Linux host binaries) | Homebrew `zig` (0.17.1 on 2026-11-06). The fork accepts any 0.17.x ≥ 0.17.0; 0.18 will fail the gate until the fork rebases. |
| Xcode 26+ with the Metal toolchain | `swift build`, `xcodebuild -create-xcframework`, `xcrun metal` for Ghostty's shaders | Xcode 27.2. `xcodebuild -runFirstLaunch` then `xcodebuild -downloadComponent MetalToolchain` (needs to run outside a sandbox). |
| Go 1.26+ | the host | Homebrew `go` |
| node | `deploy/build-payload.js` (payload packing), the Electron client | Homebrew `node` |
| `rcodesign` (optional) | signing with the stable identity ([signing.md](signing.md)) | dev builds use `codesign -s -` (ad hoc) |

Nix is **not** needed on the Mac for anything in this document.

## Layout

```
mac/
  Package.swift              SwiftPM. One library target per area (each builds and is unit-tested
                             on its own; the pure ones mirror the Zig pure packages) and the app
                             target on top. Dependencies run downwards:
  Sources/WebmuxLayout/      the column/stack layout model, commands, width rule, persistence
                             (reference: gtk/ghostty/src/webmux/layout). Foundation only.
  Sources/WebmuxHost/        one host over its unix socket: HTTP/1.1, WebSocket, SSE, protocol
                             frames, sessions + fs APIs (reference: src/webmux/net). + Network
  Sources/WebmuxConnection/  profiles + store, Keychain, ssh tunnel, probe, deploy, liveness,
                             retry, connection log, LAN probe (reference: src/webmux/conn). + Security
  Sources/WebmuxTerminal/    AppKit + GhosttyKit (links Metal, QuartzCore, CoreText, Carbon, IOSurface):
    Ghostty/                 the trimmed wrapper copied from ghostty macos/Sources/Ghostty
                             (Ghostty.App, SurfaceView_AppKit, Ghostty.Config, Ghostty.Input, …)
    Terminal/                WebmuxSurfaceView (a Ghostty surface attached to a webmux session),
                             pane behaviours: config, theme, fade, clipboard, image paste, links, IME
  Sources/WebmuxWorkspace/   workspace view (the strip), pane frames, animations, sessions
                             (depends on WebmuxLayout, WebmuxTerminal, WebmuxHost)
  Sources/WebmuxFiles/       the file-browser pane: Miller columns, previews, upload/download, watch
                             (depends on WebmuxHost, WebmuxWorkspace)
  Sources/WebmuxPanels/      Settings window, Connections window, Connection Log window,
                             status HUD, link chooser, About (depends on WebmuxConnection, WebmuxHost)
  Sources/webmux/            the app, depends on every library above:
    App/                     main.swift, AppDelegate, main menu, window controller, toolbar
    Control/                 control socket for scripted testing (dump, key, text, click, wait, …)
    Support/                 logging, paths, JSON helpers, marshalling
  Tests/<Target>Tests/       XCTest per target (WebmuxConnectionTests/Fixtures: fake ssh + host)
  GhosttyKit.xcframework     BUILD OUTPUT (gitignored): make mac-ghosttykit
  Resources/                 Info.plist, webmux.entitlements, AppIcon.icns
  scripts/
    build-ghosttykit.sh      zig build in gtk/ghostty → mac/GhosttyKit.xcframework
    bundle.sh                swift build → mac/dist/webmux.app (+ codesign)
    dev-host.sh              build | run | status | stop a native Darwin webmux-host (dev mode)
  README.md                  how to build, run, test; conventions for this directory
docs/macos-client.md         this file
```

Makefile targets (repo root): `make mac-ghosttykit` (the xcframework),
`make mac-client` (payload + bundle, signed), `make mac-client-run`
(build and open), `make mac-test` (`swift test`).

## The seam in the fork

Three edits to pre-existing Ghostty files, all recorded in
`gtk/ghostty/WEBMUX.md` › Upstream edits:

1. **`src/apprt/embedded.zig`** — the embedded apprt's `Surface` declares
   `termioBackend()` (the core's existing `@hasDecl` hook in
   `src/Surface.zig` then calls it), returning a `termio.Webmux.Config`
   when the surface options carry a webmux session, `null` otherwise
   (stock behaviour: `termio.Exec`). `Surface.Options` gains the fields
   below. A C function `ghostty_surface_webmux_send` queues a side-channel
   frame (`paste-image`, `clipboard-sync`) on the surface's backend.
2. **`include/ghostty.h`** — the matching fields at the end of
   `ghostty_surface_config_s`:
   ```c
   const char* webmux_socket_path;   // host HTTP unix socket; NULL = local pty
   const char* webmux_session_id;
   void* webmux_userdata;
   ghostty_webmux_event_cb webmux_event_cb;
   ```
   a C event struct (`ghostty_webmux_event_s`: tag + fields, strings as
   `ghostty_string_s` valid only during the callback) mirroring
   `termio/webmux/Client.zig` `Event`, and the send function.
3. **`src/webmux/net/Conn.zig`** — the unix-socket wrapper used raw Linux
   syscalls; it now goes through libc on non-Linux (`std.c`): no
   `SOCK_CLOEXEC`/`MSG_NOSIGNAL` on Darwin, so `FD_CLOEXEC` via fcntl and
   `SO_NOSIGPIPE` via setsockopt instead. Behaviour unchanged on Linux.

The callback runs on the backend's reader thread; the Swift side copies
the event and hops to the main queue (the same rule as the GTK pane).

**The tunnel's local end is a unix socket**, as on Linux: the Zig backend
only speaks unix sockets, and `ssh -L <path>:<remote path>` with
`StreamLocalBindUnlink=yes` gives us one without a port to pick. The
Swift side therefore also talks to the host over that socket. Foundation's
URLSession cannot, so `Host/` uses Network.framework (`NWConnection` to an
`NWEndpoint.unix`) with a small HTTP/1.1 + WebSocket client of our own,
mirroring `src/webmux/net/` (which is the tested reference). Socket paths
live under `~/Library/Application Support/<bundle id>/run/` (short paths:
`sun_path` is 104 bytes on Darwin).

Build: `zig build -Demit-xcframework=true -Demit-macos-app=false
-Dxcframework-target=native -Doptimize=ReleaseFast -Dsentry=false`
in `gtk/ghostty`, output `macos/GhosttyKit.xcframework`, copied to
`mac/GhosttyKit.xcframework` by `scripts/build-ghosttykit.sh`. The webmux
termio backend is always compiled in (`src/termio.zig` imports it); a
surface without the webmux fields behaves exactly like stock Ghostty.
Ghostty's resources (`zig-out/share/ghostty`: terminfo, shell integration)
are **not** needed: the shell runs on the remote host.

## Idiomatic macOS: the shape of the app

One main window per app (W-01…), the Electron client's "hosts" become
**one workspace per connection**, switched with one click from the host
pills in the toolbar and ⌘1…⌘9 / ⌘⇧[ / ⌘⇧] (W-45). One pill per live
connection, coloured by status (green connected, yellow connecting /
degraded, red retrying / failed), with the name in small type above a
minimap of that host's panes (`WorkspaceMinimapView`: columns and stacks
roughly to proportion, the focused pane highlighted, an outline of the
on-screen part when the strip scrolls), so every host's layout shows at
once; clicking a pane in a minimap brings its host to the front with
that pane focused. The minimap's `attention` set (drawn orange) is the
hook for a future "pane wants attention" signal; nothing sets it yet. The window has a unified
title bar + `NSToolbar`: the host switcher and a "+" that opens the
Connections window (to start another connection; the Electron and GTK
clients have no such entry) centred, New Terminal, New File Browser and
Settings on the right. The Connection Log is in the menus only (⌃⌘L).
The status is the pill's colour and the window subtitle.

| Electron thing | Mac equivalent |
| --- | --- |
| Connection page, profile form, ⋯ menu | **Connections** window (`NSWindow`: sidebar list with a +/− and log footer; form with the everyday fields — name, host, password, instance — and an Advanced box for port, identity, extra ssh options, download folder; sheet for delete/restart confirmations) |
| Settings modal (color scheme, fade) | **Settings** window (⌘,) with a toolbar-style pane |
| Log window | **Connection Log** window (`NSTableView`, Reveal in Finder) |
| Status messages | transient HUD panel at the window's bottom, auto-dismissed |
| Link chooser modal | `NSAlert` sheet |
| Native menus from `main.js` | the same menus with the macOS accelerators column from PARITY § 5 (⌘ chords) |
| localStorage per host | `~/Library/Application Support/<bundle id>/layout/<host-slug>.json` |
| `config.json` + `passwordEnc` (safeStorage) | `config.json` without passwords; passwords in the **Keychain** (generic password, service = bundle id, account = profile id) |
| xterm.js file-browser Miller columns | `NSBrowser` (the native Miller-column control) or three `NSTableView`s if NSBrowser fights us; previews in `NSImageView`/`NSTextView`/`WKWebView`-free markdown via `AttributedString(markdown:)`; upload via drop and `NSOpenPanel`; download via `NSSavePanel` / default folder |
| Dark/light theme setting | `NSApp.appearance` (system / dark / light) and the two terminal palettes (T-05, T-06) |
| Local Network probe + hint (X-40, X-41) | kept: it exists for macOS; `NSLocalNetworkUsageDescription` in Info.plist |

Terminal defaults reproduce the Electron client functionally (T-01…):
JetBrains Mono at 13 pt (Ghostty's bundled font; the Nerd Font symbols
come from Ghostty's fallback), 5000 lines of scrollback, blinking block
cursor, the two palettes. The app never reads `~/.config/ghostty`.

Keyboard: the macOS column of PARITY § 5 (chords are ⌘, secondary ⌥; app
shortcuts ⌘⇧O connections, ⌘⇧R reconnect, ⌃⌘L log, ⌘, settings). Chords
are consumed by the window before the surface sees them (T-15).

## Rules for everyone working on this

1. **Ownership is by directory** (the areas below). Edit only what your
   brief assigns; for anything else, describe the change and let the lead
   route it, or make the smallest edit and list it in your report.
2. **Edits to pre-existing Ghostty files are the scarce resource**, both
   Zig (fork) and the copied Swift wrapper. Prefer new files plus a
   one-line hook. Record every fork edit in `gtk/ghostty/WEBMUX.md`.
3. **The Electron client is the spec for behaviour** (`gtk/PARITY.md`),
   the GTK client the reference implementation (`src/apprt/webmux/`,
   `src/webmux/`). Where the Mac client deliberately differs, add it to
   Deliberate deviations below with the reason. Looks may differ freely
   (that is the point); functions may not.
4. **Main thread only for AppKit.** Network, ssh and backend callbacks run
   on their own threads/queues and hop to the main queue to touch views.
5. **Verify by running, not by reading.** The app has a control socket
   (`WEBMUX_MAC_CONTROL=<path>`): `dump` (window → workspace → panes as
   JSON, with the terminal's text via `ghostty_surface_read_text`), `key`,
   `text`, `click`, `wait`, `screenshot` (best effort; Metal content is
   checked through `dump`, not pixels). Dev mode (below) gives a host
   without ssh. Opening windows on this Mac's desktop is fine (unlike the
   Linux rule); keep them to the dev app.
6. **Parallel work:** areas live in separate SwiftPM targets so a broken file in one does not stop another's build; each worker uses its own `--scratch-path .build-<area>`; nobody edits `Package.swift` without the lead.
7. **Swift conventions:** Swift 6 language mode is *not* required (the
   copied wrapper is Swift 5 style); `@MainActor` on view code; no
   force-unwraps outside tests; `os.Logger` with subsystem = bundle id,
   category = area. No third-party packages in the first version.

## Dev mode

`WEBMUX_MAC_DEV_SOCKET=<unix socket path>` starts the app with one
workspace on that host and no ssh, like the GTK client's dev mode.
`mac/scripts/dev-host.sh` builds a **native Darwin** `webmux-host`
(`zig build -Demit-lib-vt -Dtarget=aarch64-macos` + `go build`, dev only,
never a payload platform) and runs `webmux-host serve` on a short socket
path under `/tmp/wm-mac/`. If the Darwin host build turns out not to be
viable, dev mode falls back to a tunnel to a real Linux host opened by
hand with `ssh -N -L`.

## Phases

**Phase 0 — contract and toolchain** (this document, Makefile targets,
Metal toolchain, host built on macOS). Done 2026-11-06 except the
Makefile targets.

**Phase 1 — the seam.** Fork edits 1–3 above; `make mac-ghosttykit`
produces `mac/GhosttyKit.xcframework`; the fork's own `zig build test`
still passes for `src/webmux/net`. Verified by building.

**Phase 2 — the foundation** (lead). SwiftPM skeleton; the trimmed
Ghostty wrapper; `WebmuxSurfaceView`; dev mode showing **one terminal
attached to a dev host, typing works, resize works, title arrives**;
control socket with `dump`/`key`/`text`; `bundle.sh` producing a signed
`webmux.app` that launches from Finder. This is the integration point for
phase 3.

**Phase 3 — feature areas, in parallel**, each against PARITY sections
and the GTK reference, each with its own worktree, merged by the lead:

| Area | Directory (owned) | PARITY sections | GTK reference |
| --- | --- | --- | --- |
| Connections | `Connection/`, `Panels/Connections*`, `Panels/Log*` | 7, 8, 11 | `src/webmux/conn/`, `chrome/hub.zig`, `chrome/page.zig`, `chrome/keyring.zig`, `panels/log_window.zig` |
| Workspace | `Workspace/`, pane chords in `App/` | 3 (sessions), 4, 5 | `src/webmux/layout/`, `workspace/` |
| Terminal pane | `Terminal/` | 1, 2, 14, pane-local parts of 3 | `pane.zig`, `terminal/`, `config.zig` |
| File browser | `Files/` | 6 | `files/` |
| Panels and app | `Panels/Settings*`, `Panels/Hud*`, `Panels/Link*`, `App/` menus | 9, 10, 12 | `panels/`, `chrome/menu.zig`, `shortcuts.zig` |
| Host client | `Host/` | 13 | `src/webmux/net/`, `termio/webmux/Client.zig` |

**Phase 4 — integration and audit.** One audit pass against PARITY with
the control socket and a real host; fixes; `docs/development.md` and
`README.md` updated; `make mac-client` artefact installed on this Mac.

## Deliberate deviations from the Electron client (and from the GTK client)

1. Looks: native toolbar, menus, windows and sheets replace the Electron
   header strip, pills, connection page and modals. Colours, sizes and
   paddings in PARITY §§ 9–12 are not binding; the functions are.
2. The tunnel's local end is a unix socket under
   `~/Library/Application Support/<bundle id>/run/` (as on Linux), not a
   loopback port; the profile's `localPort` field is gone.
3. Passwords live in the Keychain, never in `config.json`.
4. Per-host state (layout, file-browser state) is a JSON file per host
   slug under Application Support, not a `webmux://` origin.
5. Profiles carry an `id` (as the GTK client) so the Keychain item
   survives a rename; profiles (not passwords) are imported from the
   Electron `~/.config/webmux/config.json` on first run.
6. Every pane's terminal stays attached while its connection is open
   (GTK deviation 4).
7. Snapshots replay at the remote grid size then resize (GTK deviation
   13); the backend prints the "[disconnected — reconnecting…]" and
   "[session exited: N]" lines (GTK 15); OSC 8 underline only with a
   modifier (GTK 17); 3 lines per wheel notch (GTK 18).
8. The file browser is an `NSBrowser`-style Miller view with native
   previews; markdown renders through `AttributedString(markdown:)`
   (no remote images, no footnotes/math), not the Electron `marked`.
9. arm64 only in the first version.

Terminal pane (`Sources/WebmuxTerminal/Terminal`):

10. ⌘V is the paste (Edit › Paste, also ⇧⌘V); ⌃V stays the pty's `^V`
    (the Electron client pastes on Ctrl+V); ⌃⌥V is a literal `^V` (T-16).
11. Link detection runs Swift-side over the row text under the pointer
    (`TerminalLinks`), not through xterm.js's link provider or the core's
    regex; a click opens, ⇧-click copies (T-24), also under mouse reporting.
12. Non-http OSC 8 targets follow GTK deviation 26 (inert on a plain
    click; ⌘-click offers the chooser, Copy only). URLs underline on hover
    and open on a plain click as in the Electron client (the fork's
    `ghostty_config_webmux_links`, fork pass 2026-11-07).
13. (Lifted 2026-11-07.) The Electron key fixups (K-19…) apply only while
    the program has not enabled the kitty keyboard protocol, as in the GTK
    client (`ghostty_surface_webmux_kitty_keyboard`).
14. ⌘ keys never reach the pty: the workspace consumes the chords, the
    terminal consumes ⌘C/⌘V, and the core does not encode ⌘ on macOS.
15. 3 lines per wheel notch, ⌥ scrolls 5× (T-27), T-30's sticky bottom band.

Workspace (`Sources/WebmuxWorkspace`):

16. No strip scrollbar: the strip pans by horizontal wheel/swipe and by
    the reveal scroll (L-25…L-27).
17. A fresh pane fades in through layer opacity, not a CSS transition.
18. Moves run on Core Animation's clock with the sqrt duration rule
    (L-36…L-39) but without the hitch-absorbing frame clock of GTK dev. 69;
    terminals resize once per move, when it ends (`holdResize`).
19. The focus ring is a 2 pt border on the pane frame (not a CSS outline).
20. ⌘W, ⌘H and ⌘F are pane chords while a workspace is in front (Close
    Pane, Focus Left, Full Width); Hide/Hide Others have no accelerators.

File browser (`Sources/WebmuxFiles`):

21. Markdown renders through `AttributedString(markdown:)`: raw HTML is
    shown literally, task boxes as ☐/☑, tables monospaced, footnotes and
    math unsupported, remote images as their alt text, local images
    inlined; the text is selectable.
22. PDF previews through PDFKit (≤ 50 MB); a zip listing is an
    `NSOutlineView`; WebP/AVIF do preview (the Electron client cannot).
23. The delete confirmation is an in-pane overlay (not a modal).
24. Downloads write to a `.webmux-part` temp file and rename on completion.
25. The columns are `NSTableView`s, not an `NSBrowser` (rejected: async
    listings, the drilled preview and inline rename fight it); there is
    no type-to-select.

Panels and app (`Sources/WebmuxPanels`, `Sources/webmux/App`):

26. The window title is the connection's name and the subtitle its state
    (no header strip, no pills).
27. Pane menu items are disabled, not no-ops, while no host is in front
    (GTK dev. 25 inverted: the Mac convention).
28. Passwords prompt for Keychain access once per rebuild of an unsigned
    (ad-hoc) debug binary; a certificate-signed build asks once.
29. Dev mode (`WEBMUX_MAC_DEV_SOCKET`) is a full workspace on the host
    named `dev` (layout `layout/dev.json` under the Application Support
    root in use); its HUD and log lines are real.
30. Quit bounds `engine.shutdown()` to 3 s so a supervisor stuck behind a
    pending Keychain prompt cannot hang the exit (see Open items).

(Add to this list; do not silently differ.)

## Open items

Fork follow-ups (`gtk/ghostty`, branch `webmux-shell`): **done
2026-11-07** (`WEBMUX.md` › macOS: GhosttyKit): `ghostty_config_load_string`,
`ghostty_config_webmux_links` (URL underline on hover, plain click),
`ghostty_surface_webmux_osc8_at` (T-25), `ghostty_surface_webmux_alt_click`
(T-20, the move computed in Zig from the core's cursor state) and
`ghostty_surface_webmux_kitty_keyboard` (dev. 13 lifted). Each has a live
test in `LiveTerminalTests`.

PARITY items the areas reported partly done or not applicable: T-10
(scrollbar pixels differ), T-21 (n/a on macOS); L-23, L-24 (ring/fade are native, not the
CSS values), L-27 (no strip scrollbar), L-29, L-35 (z-order only during
overlaps); F-39, F-54…F-58, F-62 (download panel details, remote-image
markdown); W-29 (Electron's window-level status pills); X-20 (back to the
Connections window only when the workspace never came up).

Integration and release:

- stable-identity signing with `rcodesign` for `make mac-client` (ad hoc
  today; Local Network and Keychain grants are forgotten per build).
- a Keychain prompt pending in a supervisor thread can block
  `engine.shutdown()`; quit is bounded at 3 s (dev. 30), the root cause
  (answering the prompt off the main thread) is not fixed.
- the fake-ssh connect flow misreports a Linux payload that cannot run on
  the Mac as the Local Network hint (X-41's heuristic fires on the probe);
  a real host does not hit this path.
- first connect to a real Linux host: **done 2026-11-07** by the user with
  the ad-hoc build (profile, deploy, tunnel, terminals work). No PARITY
  audit against a real host yet.

## Status

| Item | Status | Where |
| --- | --- | --- |
| Metal toolchain, zig 0.17.1, go, node on this Mac | ✅ 2026-11-06 | — |
| `host/build.sh` on macOS → both Linux binaries | ✅ 2026-11-06 | `host/dist/` |
| Fork: `Conn.zig` on libc (Darwin) | ✅ 2026-11-06 (3 tests; fork `zig build test -Dtest-filter=webmux` 105/105 on macOS) | `gtk/ghostty/src/webmux/net/Conn.zig` |
| Fork: embedded seam + header | ✅ 2026-11-06 (`WEBMUX.md` › macOS: GhosttyKit) | `src/apprt/embedded.zig`, `include/ghostty.h` |
| `make mac-ghosttykit` | ✅ 2026-11-06 (115 s cold, 80 s warm; 141 MB static lib) | `mac/scripts/build-ghosttykit.sh` |
| SwiftPM skeleton + wrapper + one terminal in dev mode | ✅ 2026-11-07 (nine targets, `swift build && swift test` green: 227 tests; typing, resize, title verified over the control socket) | `mac/` |
| Dev host (Darwin `webmux-host`) | ✅ 2026-11-06 (`dev-host.sh build|run|stop`; 49 s build) | `mac/scripts/dev-host.sh` |
| Control socket | ✅ 2026-11-07 (`dump`/`key`/`text`/`resize`/`wait`/`screenshot`/`quit`, one JSON object per line) | `mac/Sources/webmux/Control/` |
| Bundle + ad-hoc signing | ✅ 2026-11-07 (`dist/webmux.app`, `Identifier=me.puntium.webmux.mac`, `Signature=adhoc`, attaches to the dev host from Finder) | `mac/scripts/bundle.sh` |
| Phase 3 areas | ✅ 2026-11-07 (built in parallel, one library target each): WebmuxWorkspace 23 tests (live against a dev host), WebmuxTerminal 43 (live), WebmuxFiles 38 (1 snapshot test skipped without `WEBMUX_FILES_SNAPSHOT_DIR`), WebmuxPanels 25 | `mac/Sources/Webmux{Workspace,Terminal,Files,Panels}` |
| Phase 3 libraries landed earlier | ✅ 2026-11-07: WebmuxLayout 126 tests (Electron trace replays bit-for-bit), WebmuxHost 43 (8 live), WebmuxConnection 44 (18 engine via fake ssh) | `mac/Sources/Webmux{Layout,Host,Connection}` |
| Integration (one app) | ✅ 2026-11-07: workspace per connection, terminal/files panes, menus + chords, theme/fade/clipboard sync, dev mode on the workspace, `dump` of the workspace, payload in the bundle; `swift test` 343 green (webmuxTests 1); dev smoke and fake-ssh connect flow over the control socket (mac/README.md › Smoke) | `mac/Sources/webmux/App/{AppDelegate,HostWorkspace,FilesPane,MainWindowController}.swift` |
| First connect to a real Linux host | ✅ 2026-11-07 (user, ad-hoc build) | — |
| Phase 4: fork pass (config from a string, link rule, OSC 8 at a cell, Alt+click, kitty query) | ✅ 2026-11-07 (fork `src/apprt/embedded/webmux.zig`, `src/config/webmux.zig`; 3 new live tests) | `gtk/ghostty/WEBMUX.md` › macOS: GhosttyKit, `mac/Sources/WebmuxTerminal/Terminal/TerminalPaneView.swift` |
| Phase 4: PARITY audit on a real host | dropped 2026-11-07 (user: good enough; tweaks come from daily use) | — |
