# webmux.app — the native macOS client

A Swift/AppKit shell on GhosttyKit. The contract is
[docs/macos-client.md](../docs/macos-client.md); this file is the how-to for
this directory. Status: **phases 1–3 done and integrated** (one workspace per
connection, terminal and file-browser panes, menus and chords, Settings /
Connections / Log windows, HUD, dev mode on a full workspace, signed bundle with
the server payload); phase 4 closed without the PARITY audit (tweaks come from use); see docs/macos-client.md › Open items.

## Build

Requirements: Xcode 26+ with the Metal toolchain, Homebrew `zig` 0.17.x, `go`
(dev host only). No nix.

```sh
make mac-ghosttykit          # gtk/ghostty → mac/GhosttyKit.xcframework (about 2 min cold)
cd mac && swift build        # every target, debug: .build/debug/webmux
make mac-client              # payload-pack + release bundle: mac/dist/webmux.app (ad-hoc signed)
make mac-client-run          # ... and open it
make mac-test                # swift test (all mac/ targets)
```

`make payload-pack` packs `electron/payload/` from the Linux host binaries
already in `host/dist/` (`node deploy/build-payload.js`, no nix; the binaries
themselves come from `make host`, which needs nix). `scripts/bundle.sh
[--debug]` does the bundle on its own and copies that payload into
`webmux.app/Contents/Resources/payload/`, where `Paths.findPayloadDir` looks
first; without one the app starts but cannot deploy a host.
The bundle is signed ad hoc (`codesign -s -`): a new identity per build, so
macOS forgets Local Network / Keychain grants between builds. The
stable-identity path with `rcodesign` and a certificate PEM
([docs/signing.md](../docs/signing.md)) is a later step.

### Targets

One SwiftPM package, one library per area, the app on top. A library builds
and tests on its own, so a broken file in one area never stops another's build.

```
GhosttyKit            binary target: GhosttyKit.xcframework (make mac-ghosttykit)
WebmuxLayout          layout model, commands, width rule, persistence     Foundation
WebmuxHost            one host over its unix socket: HTTP, WS, SSE, API   Foundation + Network
WebmuxConnection      profiles, Keychain, ssh tunnel, probe, deploy, log  Foundation + Security
WebmuxTerminal        Ghostty wrapper (Ghostty/) + WebmuxSurfaceView      AppKit + GhosttyKit
                      (Terminal/); links Metal, QuartzCore, CoreText,
                      Carbon, IOSurface, UniformTypeIdentifiers, libc++
WebmuxWorkspace       the strip, pane frames, animations, sessions        ← Layout, Terminal, Host
WebmuxFiles           the file-browser pane                               ← Host, Workspace
WebmuxPanels          Settings, Connections, Log, HUD, link chooser       ← Connection, Host
webmux                the app: App/, Control/, Support/                   ← all of the above
```

`Tests/<Target>Tests` is the XCTest bundle of each target. Only what an area
or the app needs is `public`; the rest of the Ghostty wrapper stays internal to
`WebmuxTerminal`.

How the app puts the areas together (`Sources/webmux/App`):

- `AppDelegate.hostDidConnect` creates a `HostWorkspace` per connection
  (`WorkspaceController(connection: WorkspaceConnection(socketPath:name:slug:),
  ghostty:, layoutURL: <AppSupport>/layout/<slug>.json, settings:)`), puts
  `controller.view` in the host's `HostContentView` and calls
  `attachInBackground()`; `hostDidGoAway` → `detach()`. `HostWorkspace` routes
  `onStatus` → `StatusHUD` (from that connection), `onLog` → the engine's
  `ConnectionLog` under the host name, `onSummaryChanged` → pane count and the
  hub's offline flag, and `onPaneCreated` → a terminal pane's
  `onChooseLink`/`onStatus` (the `TerminalPaneDelegate` relays) → `LinkChooser`
  / HUD. Settings changes reach every workspace live (min/max cols, fade; the
  fade slider previews through `PanelNotification.fadeChange`).
- Terminal panes: `WebmuxWorkspace.TerminalPane` hosts a
  `WebmuxTerminal.TerminalPaneView` (the surface with the pane behaviours:
  ⌘C/⌘V, links, scrollbar, image paste, fade) and is its delegate; the frame's
  focus state drives `setUnfocused(fade:)`. The colour scheme is applied once,
  app-wide: `PanelNotification.themeChange` → `Ghostty.App.apply(theme:)`
  (T-07, every surface repaints in place). `NSApplication.didBecomeActive` →
  `syncClipboardImageIfAny()` on the front workspace's focused terminal (C-09).
- Files panes: `FilesPane` (App/FilesPane.swift) adapts `WebmuxFiles.FilesPaneView`
  to `WorkspacePane` (title fitted with `FilesPaths.fitPath`, state persisted
  through the layout file, `onDownloadDirChosen` → the profile via
  `engine.setDownloadDir`, links → `LinkChooser`); `FilesPaneFactory` is
  registered once with `WorkspacePaneFactories.shared.register(.files, …)`.
- Pane commands: `MainWindowController` implements `PaneCommandTarget` for the
  menu items and toolbar buttons (nil target, responder chain) and forwards to
  the front workspace (`run(LayoutCommand)`, `reload()`, `view.zoom`); the items
  validate as enabled only with a loaded workspace in front. The key chords are
  consumed by `WorkspaceView.performKeyEquivalent` (and ⌘C/⌘V by the terminal)
  before the menu bar sees them, so a chord fires exactly once.

Working on one area without touching the shared `.build`:

```sh
cd mac
swift build --scratch-path .build-workspace --target WebmuxWorkspace
swift test  --scratch-path .build-workspace --filter WebmuxWorkspaceTests
swift build --scratch-path .build-app --product webmux        # the app, when you need to run it
```

Every `--scratch-path` is a full build of that target's dependency graph
(`WebmuxTerminal` links the 141 MB GhosttyKit, so the first build of an
AppKit area takes a minute); `.build*` is gitignored. `Package.swift` is the
lead's: add files to your target's directory, not targets to the manifest.

## Run (dev mode)

```sh
scripts/dev-host.sh build          # once: a native Darwin webmux-host (dev only)
scripts/dev-host.sh run dev        # prints /tmp/wm-mac/dev/http.sock
WEBMUX_MAC_DEV_SOCKET=/tmp/wm-mac/dev/http.sock \
WEBMUX_MAC_CONTROL=/tmp/wm-mac/dev/ctl.sock \
  .build/debug/webmux
scripts/dev-host.sh stop dev
```

`WEBMUX_MAC_DEV_SOCKET` opens one window, "webmux (dev)", with a full
workspace on that host (name and slug `dev`; the layout is saved as
`layout/dev.json` under the Application Support root — set
`WEBMUX_MAC_APP_SUPPORT=<short path>` to keep smokes out of the real one; the
root must be short enough for socket paths, so `/tmp/wm-mac/<name>`, not a
deep scratch directory). An empty host gets a first terminal (S-06). Without
the variable the window shows the landing view and the Connections window
opens. The bundle takes the same variables: `open --env
WEBMUX_MAC_DEV_SOCKET=… --env WEBMUX_MAC_CONTROL=… dist/webmux.app`.
`WEBMUX_MAC_SSH=<program>` replaces `ssh` (the tests' fake ssh in
`Tests/WebmuxConnectionTests/Fixtures/fake-ssh` with its `FAKE_*` variables
makes a connect flow run without a network).

The app never reads `~/.config/ghostty`: the terminal configuration is the
text in `Sources/WebmuxTerminal/Terminal/TerminalConfig.swift` (the Electron defaults,
PARITY T-01…T-10, mirroring `gtk/ghostty/src/apprt/webmux/config.zig`).
GhosttyKit needs no resources directory (terminfo and shell integration live
on the remote host), so `GHOSTTY_RESOURCES_DIR` is not set.

## Test

```sh
cd mac && swift test                       # everything (about 50 s; 343 tests on 2026-11-07, 1 skipped)
cd mac && swift test --filter WebmuxTerminalTests   # one bundle
```

`swift test` runs the bundles as separate processes. Two of them need more
than the package: `WebmuxHostTests.LiveTests` starts its own isolated Darwin
dev host (`scripts/dev-host.sh run host-tests`, instance name `host-tests`,
stopped at the end; skipped with `XCTSkip` when
`host/dist/webmux-host-darwin-arm64` is missing), and `WebmuxConnectionTests`
runs its engine against the fake `ssh` and fake host in
`Tests/WebmuxConnectionTests/Fixtures/` (found through `#filePath`, so the
directory is `exclude`d, not a resource). Neither touches the `dev` instance,
so `swift test` can run while the dev app is up.

Per bundle: `WebmuxLayoutTests` (126) the layout model against the shared spec
traces; `WebmuxHostTests` (43) HTTP/WS/SSE over socketpairs and a fake server,
plus the live host; `WebmuxConnectionTests` (44) profiles, Keychain, ssh
command, engine, deploy; `WebmuxTerminalTests` (43) the event conversion, the
config text, both palettes through the real C API, links, image paste, and
live pane semantics against its own dev host (`term-tests`);
`WebmuxWorkspaceTests` (23) geometry/animation arithmetic and the live
workspace against `ws-tests`; `WebmuxFilesTests` (38, the PNG snapshot test
skipped unless `WEBMUX_FILES_SNAPSHOT_DIR` is set) paths, state, markdown,
zip, transfers and the live pane; `WebmuxPanelsTests` (25) the status
mapping, profile form, log filter, menu table, HUD timer, URL kinds;
`webmuxTests` (1) the control command table. Everything that needs the whole
app is verified by running it against the dev host through the control socket
(the smoke below); the contract's rule 5.

A Darwin detail the fake server had to learn (`Tests/WebmuxHostTests/Loopback.swift`):
when a client closes before `accept()` dequeues its connection, the accepted
socket is already fully shut down and XNU rejects `setsockopt(SO_NOSIGPIPE)`
and `fcntl(F_SETNOSIGPIPE)` with EINVAL, so a write to it is a guaranteed
SIGPIPE. `Peer` treats that EINVAL as "peer gone" and never writes. Server-side
code in the app (the control socket) has the same exposure.

## Control socket

`WEBMUX_MAC_CONTROL=<unix socket path>` makes the app listen there. One JSON
object per line in, one per line out; every reply has `"ok": true|false` and,
when false, `"error"`. Commands run on the main thread (except `wait`). A
client in three lines:

```sh
printf '%s\n' '{"cmd":"text","text":"echo wm-$((6*7))\n"}' '{"cmd":"wait","contains":"wm-42"}' '{"cmd":"dump"}' \
  | nc -U /tmp/wm-mac/dev/ctl.sock
```

| command | fields | reply |
| --- | --- | --- |
| `dump` | — | `windows: [{title, subtitle, kind: main\|connections\|settings\|log\|about\|sheet, frame, focused, …}]`, `openWindows`, `appearance`, `settings {theme, unfocusedFade, minCols, maxCols}`, `terminal {theme, background}` (the palette the terminals run with), `hud {text, count}`. The main window adds `hosts [{name, state, active}]`, `front`, `landing`, and `workspace {name, loaded, offline, paneCount, focused, zoom, scroll, animating, columns: [{full, panes: [pane]}]}` for the front host; a pane is `{id, kind, title, focused, keyboard, box}` plus, for a terminal, `session, attached, linkUp, finished, cols, rows, fade, text` (`text` is the visible screen read with `ghostty_surface_read_text`), for a file browser `directory, cursor, columns, listed, opened, preview?, openError?`. `panes` is the same list flat (layout order). The Connections window adds `selected, error, notice, detail, diagnostics`; the Log window `lines, entries`; Settings `appearance` |
| `menu` | `title` | `{ok, enabled, keyEquivalent, target?}`; performs the item with that title (any menu) honouring its enabled state. With the app inactive (no key window; a background launch cannot take activation on macOS 14+) the main window's responder chain is walked by hand, as validation would with that window key |
| `menus` | — | `{items: [{menu, title, keyEquivalent, mods, enabled, hidden}]}`: the menu bar as data |
| `setting` | `key` (`theme` → `system\|dark\|light`; `fade` → 0–100), `value` | `{ok, appearance}`; drives the Settings window's controls (creating the window) |
| `window` | `kind` (`main\|connections\|settings\|log`), `action` (`front\|close`) | `{ok}` |
| `connections` | `select?` (profile name), `press?` (`new\|save\|connect\|show\|reconnect`), `fields?` (`name host sshPort identityFile instance extraOptions password clearPassword`) | `{ok, form, error, notice, selected, detail}`; `new` runs before `fields`; Save on a new profile is Save & Connect, Connect toggles by state (Cancel while connecting) |
| `key` | `key` (a character, or `return` `escape` `tab` `backspace` `forwarddelete` `space` `up` `down` `left` `right` `home` `end` `pageup` `pagedown` `insert` `f1`…`f12`, or a `Ghostty.Input.Key` name), `mods` (any of `cmd` `shift` `ctrl` `alt` `fn`) | `{ok, route}`; a keyDown + keyUp `NSEvent` pair through `NSApp.sendEvent` (`route: app`); inactive, the real order by hand — the window's views' `performKeyEquivalent` (`view`: the pane chords, ⌘C/⌘V), the menu bar (`menu`), then the window (`window`); plain keys skip the equivalents like AppKit does |
| `text` | `text` | `{ok, typed}`; key by key through the current keyboard layout into the focused terminal (`\n` Return, `\t` Tab, `\u{7f}` Backspace, `\u{1b}` Escape, 0x01–0x1a ctrl+letter); characters the layout cannot produce go in as committed text (the IME path), in order |
| `resize` | `w`, `h` (content size, points) | `{ok, cols, rows, frame}` (the focused terminal's grid) |
| `wait` | `ms` (default 100), or `contains` + `timeout_ms` (default 5000) | `{ok}` / `{ok, found}`; `contains` polls the focused terminal's visible text every 50 ms |
| `screenshot` | `path`, `kind?` (as `window`; default `main`) | `{ok, path, width, height, note}`; `CGWindowListCreateImage` of that window — **blank without Screen Recording permission** (the Metal content is checked through `dump`, not pixels) |
| `quit` | — | `{ok}`, then the app terminates (engine shutdown bounded at 3 s) |
| `help` | — | the command list |

The GTK client's socket (`gtk/ghostty/src/apprt/webmux/control/`) has the same
spirit and more commands (`click`, `selection`, chrome); the Workspace and
Terminal areas extend this one as they need.

## Smoke (how to run it)

```sh
scripts/dev-host.sh run dev
WEBMUX_MAC_DEV_SOCKET=/tmp/wm-mac/dev/http.sock WEBMUX_MAC_CONTROL=/tmp/wm-mac/dev/ctl.sock \
WEBMUX_MAC_APP_SUPPORT=/tmp/wm-mac/as-dev .build/debug/webmux &
ctl() { printf '%s\n' "$@" | nc -U /tmp/wm-mac/dev/ctl.sock; }
ctl '{"cmd":"dump"}'                                        # the workspace, sessions attached
ctl '{"cmd":"menu","title":"New Terminal"}' '{"cmd":"wait","ms":1500}' '{"cmd":"dump"}'
ctl '{"cmd":"text","text":"echo wm-$((6*7))\n"}' '{"cmd":"wait","contains":"wm-42"}'
ctl '{"cmd":"key","key":"left","mods":["cmd"]}'              # focus left (K-06)
ctl '{"cmd":"key","key":"right","mods":["cmd","alt"]}'       # move column right (K-13)
ctl '{"cmd":"key","key":"w","mods":["cmd"]}'                 # close pane (K-04): the session is deleted
ctl '{"cmd":"menu","title":"New File Browser"}' '{"cmd":"wait","ms":2000}' '{"cmd":"dump"}'   # lists ~
ctl '{"cmd":"setting","key":"theme","value":"light"}' '{"cmd":"dump"}'   # terminal.background #f4f5f9
ctl '{"cmd":"quit"}'
scripts/dev-host.sh stop dev
```

Connect flow without a network: run the app without `WEBMUX_MAC_DEV_SOCKET`,
with `WEBMUX_MAC_SSH=<copy of Tests/WebmuxConnectionTests/Fixtures/fake-ssh>`
and its `FAKE_LOG`, `FAKE_REMOTE_HOME`, `FAKE_STUBS` (a `uname` printing
`Linux`/`x86_64`, a `pgrep` exiting 1), `FAKE_REMOTE_RUN`; then
`connections {"press":"new","fields":{"name":"box","host":"box"}}`,
`connections {"press":"save"}` (Save & Connect), `wait 10000`, `dump`: the
probe, the push and the server start run through the fake, and the failure
(the Linux binary cannot run here) shows in the Connections window's
`detail`/`diagnostics`. Host `badhost` fails at the probe with ssh's message.

### Verified transcript (2026-11-07, integrated)

Debug binary against `dev-host.sh run dev`, through `ctl.sock`, app inactive:

```
→ dump                      ← workspace {loaded: true, paneCount: 1, focused: 0d5e…}; pane text "ken@KURO ~ % "
→ menu "New Terminal"       ← {enabled: true, target: MainWindowController}; paneCount 2, host has 2 sessions,
                               the unfocused pane fade 40, the new one 0 and keyboard: true
→ text "echo wm-$((6*7))\n", wait contains wm-42        ← {found: true}
→ key ⌘←                    ← focused back to column 0 (fade 0 / 40 swap)
→ key ⌥⌘→                   ← the columns swap (focused pane now column 1)
→ key ⌘W                    ← paneCount 1, host sessions 1 (DELETE after the close animation)
→ menu "New File Browser"   ← files pane: directory /Users/ken, columns [/, /Users, /Users/ken], 58 names listed, title "~"
→ setting theme light       ← appearance Aqua, terminal {theme: light, background: #f4f5f9}; dark → #1f1f2b
→ ⌘← then text printf OSC 52 ← hud {text: "clipboard set from terminal", count: 1}
→ key ⌘↩ (chord)            ← {route: view}: exactly one pane added (the menu did not fire again)
→ menu "Reload", "Zoom In"  ← ok; workspace.zoom 1.1
→ setting fade 80           ← the unfocused pane's fade 80 (live preview)
→ quit                      ← exits in < 1 s; layout/dev.json holds the three columns
```

The release bundle (`scripts/bundle.sh`, `open --env … dist/webmux.app`)
attached the same way, typed `echo bundle-ok`, quit cleanly; it carries
`Contents/Resources/payload/payload.json` + the two Linux tarballs;
`codesign -dv`: `Identifier=me.puntium.webmux.mac`, `Signature=adhoc`.

### Phase-2 transcript (2026-11-07, single surface)

```
→ {"cmd":"dump"}
← panes: [{session: 337ec4b8-…, attached: true, linkUp: true, cols: 111, rows: 34, text: "ken@KURO ~ % "}]
→ {"cmd":"text","text":"echo wm-$((6*7))\n"}            ← {"ok":true,"typed":17}
→ {"cmd":"wait","contains":"wm-42","timeout_ms":5000}    ← {"found":true,"ok":true}
→ {"cmd":"dump"}                                         ← text: "ken@KURO ~ % echo wm-$((6*7))\nwm-42\nken@KURO ~ % "
→ {"cmd":"resize","w":600,"h":400}                       ← {"cols":74,"rows":23,"frame":{"w":600,"h":428,…},"ok":true}
→ {"cmd":"text","text":"printf \"\\033]0;hello-title\\007\"\n"}, wait 800 ms, dump
                                                         ← pane title "hello-title", window title "hello-title"
→ {"cmd":"text","text":"sleep 30\n"}, {"cmd":"key","key":"c","mods":["ctrl"]}, wait contains "^C"
                                                         ← {"found":true,"ok":true}
→ {"cmd":"text","text":"exit\n"}, wait contains "session exited"
                                                         ← text ends "…exit\n\n[session exited: 130]", finished: true, linkUp: false
→ {"cmd":"screenshot","path":"/tmp/wm-mac/dev/shot.png"} ← ok, 17 KB PNG, blank (no Screen Recording grant)
→ {"cmd":"quit"}                                         ← app exits, ctl.sock removed
```

## What was copied from Ghostty, and re-diffing at a rebase

`Sources/WebmuxTerminal/Ghostty/` is Ghostty's own macOS wrapper
(`gtk/ghostty/macos/Sources/Ghostty/` and `Helpers/`, MIT), copied at fork
commit `518ec334a` and trimmed. Every file starts with
`// Copied from ghostty macos/Sources/<path> at <sha> and trimmed for webmux`
followed by what was dropped or changed. At a rebase of the fork:

```sh
cd gtk/ghostty && git diff 518ec334a..HEAD -- macos/Sources/Ghostty macos/Sources/Helpers
```

and apply what touches the kept parts (a `git diff --stat` first tells which
files moved); then bump the sha in the headers. The trimmed files keep
upstream's structure and comments so a side-by-side diff stays readable.

Kept: `Ghostty.App` (runtime callbacks, clipboard, the action switch for a
single-surface host), `SurfaceView_AppKit` + `OSSurfaceView` +
`Ghostty.Surface` + `SurfaceConfiguration` (surface lifetime, focus, size and
scale, keyboard incl. `performKeyEquivalent`, IME/`NSTextInputClient`, mouse,
scroll, pressure/QuickLook, cursor shape, drop onto the surface, Services,
accessibility), `Ghostty.Config` (built from text), `Ghostty.Input`,
`Ghostty.Action`, `Ghostty.Event`, `NSEvent+Extension`, `GhosttyDelegate`,
`GhosttyPackage` (+Meta), `Ghostty.Shell.escape`, and the Helpers they
reference (`Cursor`, `KeyboardLayout`, `NSPasteboard+Extension`,
`NSColor/NSScreen/String/UserDefaults/Optional/Array+Extension`).

Dropped: everything SwiftUI/Combine (`@Published`, `Color`, `Backport`,
`KeyboardShortcut`, the SwiftUI `Surface` views), AppIntents, tabs, splits,
quick terminal, command palette, inspector, search overlay, progress bar,
child-exited bar, key sequences/tables, secure input, desktop/user
notifications, clipboard confirmation dialogs (the config never asks; the
callbacks allow), `UntrustedURL` (links are posted as `.ghosttyOpenURL` for the
shell), drag source, transferable, image, grab handle, AppleScript, Sparkle,
window restoration (`Codable`), title prompt/override, the ghost-emoji title
fallback, focus-follows-mouse, the right-click context menu.

Deliberate edits inside copied files (all marked `webmux:`):
`SurfaceConfiguration.webmux` + the four C fields in `withCValue` (and
`NSScreen.main ?? 2` instead of a force unwrap); `SurfaceView.titleDidChange()`,
`readText(tag:)`, `sendCommittedText`, `resetCursorRects`;
`Ghostty.Config(text:)`; `Ghostty.App.update(config:)`; `GhosttyPackage`'s
`.ghosttyOpenURL`. Everything webmux-specific that could live outside is
outside: `Terminal/WebmuxSurfaceView.swift` (`setFrameSize` → `sizeDidChange`,
`viewDidMoveToWindow`, the event callback and side-channel frames).

Since the wrapper became the `WebmuxTerminal` library, `public` was added to
the declarations the app and the other areas use: `Ghostty` (the namespace),
`Ghostty.App` (`init(config:)`, `app`, `config`, `readiness`, `appTick`,
`update(config:)`), `Ghostty.Config` (`init(text:)`, `errors`, `loaded`,
`backgroundColor`, `foregroundColor`, `fontSize`), `Ghostty.info`,
`Ghostty.Input` / `Input.Key` (+ `keyCode`), `Ghostty.Action.OpenURL`,
`Ghostty.SurfaceConfiguration` (`init()`, `fontSize`),
`Ghostty.OSSurfaceView` / `Ghostty.SurfaceView` (the class, its `init`, `surface`,
`surfaceSize`, `cellSize`, `title`, `focused`, `bell`, `backgroundColor`,
`readText(tag:)`, `sendCommittedText`, and the NSView/NSResponder overrides
and protocol witnesses Swift requires to be public in a public class),
`KeyboardLayout`, the `Notification.Name`s in `GhosttyPackage.swift`, and all of
`Terminal/`. `public` is a keyword-only change and is not listed as an edit
above; keep new additions internal unless an area needs them.

## Layout of `Sources/`

```
WebmuxTerminal/
  Ghostty/    the trimmed wrapper (above) + Helpers/
  Terminal/   TerminalConfig (the config text), TerminalTheme, WebmuxEvent, WebmuxSurfaceView (+ delegate),
              TerminalPaneView (+ TerminalPaneDelegate), TerminalLinks, TerminalScrollbar, ImagePaste
WebmuxLayout/, WebmuxHost/, WebmuxConnection/      the pure libraries (see their tests)
WebmuxWorkspace/   WorkspaceController, WorkspaceView, PaneFrame, TerminalPane, WorkspacePane(+Factories), WorkspaceCommand
WebmuxFiles/       FilesPaneView (+ columns, preview, markdown, zip, uploads, save)
WebmuxPanels/      Connections / Settings / Log window controllers, StatusHUD, LinkChooser, MenuSpec, ThemeController
webmux/
  App/        main.swift (manual NSApplication), AppDelegate, HostHub, HostWorkspace (a connection's workspace
              wired to the chrome), FilesPane (+ factory), MainWindowController (+ PaneCommandTarget), MainMenu, PaneCommands
  Control/    ControlServer (the socket) and ControlCommands (the main-thread half)
  Support/    AppEnvironment (the env knobs)
```

`WebmuxSurfaceView` is the Terminal area's base: `init(app:socketPath:sessionId:)`,
`delegate: WebmuxSurfaceDelegate` (linkUp/linkDown/snapshot/title/sessionTitle/
exit/sessionError/pasteResult/openURL/socket, all on the main queue),
`onEvent`, `sessionTitle`, `isAttached`, `isLinkUp`, `isFinished`, `grid`,
`visibleText()`, `sendPasteImage(mime:base64:)`, `sendClipboardSync(mime:base64:)`.
The C callback copies the event into a `WebmuxEvent` on the backend's reader
thread and hops to the main queue; the `userdata` is a retained box with a weak
back-reference, released after the view (and its surface) is gone.

## Known gaps

- The C API has no `ghostty_config_load_string`; `Ghostty.Config(text:)`
  writes the text to a private temporary file and `ghostty_config_load_file`s
  it. A one-line fork addition would remove the detour.
- `scrollback-limit-lines` is a `Limit` struct in the core and not readable
  through `ghostty_config_get`; the unit test checks the text, not the parsed
  value.
- `adjust-cell-width` (the GTK client's one-pixel trim to match xterm.js) is
  not applied on macOS; the Terminal area measures and decides.
- `screenshot` needs Screen Recording permission to show content.
- The payload's Linux binaries come from `make host` (nix); `make payload-pack`
  and `make mac-client` only pack and bundle what is in `host/dist/`.
- The app cannot take activation when launched from a background shell on
  macOS 14+, so the control socket's `menu` and `key` commands emulate the
  active-app paths by hand (above); a user-launched app behaves normally.
- The rest: docs/macos-client.md › Open items (fork follow-ups, PARITY items
  reported partial, signing, the Keychain-prompt quit note, first real host).
