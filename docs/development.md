# Development

Building, running from source, testing and packaging. The `Makefile` at
the repo root is the entry point for everything; its default target is
`deps` (the legacy node server's `npm install`), so always name a target —
they are listed below. Design-level notes
for each part are in [how-it-works.md](how-it-works.md) and the documents
it links.

## Prerequisites

- **Server (`host/`)**: Nix with flakes, nothing else. `host/flake.nix`
  pins zig and go; the first build compiles libghostty-vt for both targets
  (a few minutes, cached under `host/third_party/` afterwards).
- **Electron client**: node and npm. On NixOS also the nixpkgs `electron`
  (see below).
- **GTK client**: Nix with flakes; the fork's own dev shell has zig and
  GTK. Fetch the submodule once: `git submodule update --init gtk/ghostty`.
- **macOS packaging**: `rcodesign` on PATH, and ideally a signing
  certificate at `~/.config/webmux/codesign.pem` ([signing.md](signing.md)).
- **Native macOS client (`mac/`)**: Homebrew `zig` 0.17.x, Xcode 26+ with the
  Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), `go` (the
  dev host) and `node` (payload packing); no nix. The submodule as for the GTK
  client. Details: [macos-client.md](macos-client.md) › Toolchain.

## Building

```sh
make host          # host/build.sh in the host/ nix dev shell → host/dist/webmux-host-linux-{x64,arm64}
make payload       # host, then electron/payload/<platform>/payload.tar.gz + payload.json
make client-deps   # cd electron && npm install
make client        # harness → payload → electron/dist/webmux-<version>-arm64-mac.zip (signed)
make client-linux  # harness → payload → electron/dist/webmux-<version>-x86_64-linux.AppImage + -x64-linux.tar.gz
make linux-client  # gtk/ghostty/zig-out-release/bin/webmux-gtk (GTK_OPTIMIZE=Debug → zig-out/)
make mac-client    # payload-pack → mac/dist/webmux.app (GhosttyKit + Swift release build, ad-hoc signed, payload inside)
```

Without `make`, run the recipes directly: `cd host && nix develop . -c
./build.sh`, then `node deploy/build-payload.js`. `PAYLOAD_ONLY=linux-x64
make payload` packs a single platform.

The **payload** is what a client pushes to a host on connect: one
`webmux-host` binary plus the shims, per platform, named by a content hash
([push-deploy.md](push-deploy.md)). Both clients read it from
`electron/payload/` — the GTK client finds it by walking up from its
binary, so it has to run from a checkout. A client without a payload
reports "no server payload bundled" on connect.

### macOS client

`make client` cross-builds from Linux (there are no native modules in the
client) and signs the app there with rcodesign — a stable identity when
the certificate at `SIGN_PEM` exists, ad-hoc otherwise. Signing is not
cosmetic: macOS 26.5+/27 identifies an app by its code signature for
Local Network privacy and Keychain access, and an app it cannot validate
is silently denied every LAN connection. Setup, key handling and
troubleshooting: [signing.md](signing.md). `APP_ID=…` overrides the bundle
identifier (a fresh one makes macOS treat the app as new).

Install: unzip, drag `webmux.app` to `/Applications` in Finder (the drag
is what defeats App Translocation), then clear the download quarantine:

```sh
xattr -dr com.apple.quarantine /Applications/webmux.app
```

First launch asks for Local Network access (allow it) and Keychain access
to the saved-password store (Always Allow). With a certificate-signed
build that happens once; an ad-hoc build is a new identity every time, so
it asks again after each update.

### macOS native client

`mac/` is a Swift/AppKit shell on GhosttyKit (Ghostty's embedding library,
built from the same fork as the GTK client); the contract and status are in
[macos-client.md](macos-client.md), the how-to in
[mac/README.md](../mac/README.md). Prerequisites: zig 0.17, Xcode with the
Metal toolchain, go, node (above).

```sh
make mac-ghosttykit     # gtk/ghostty → mac/GhosttyKit.xcframework (about 2 min cold; redo after a fork change)
make mac-client         # payload-pack (node deploy/build-payload.js from host/dist, no nix) → mac/dist/webmux.app
make mac-client-run     # ... and open it
make mac-test           # cd mac && swift test (every target; the live tests start their own dev hosts)
```

The bundle carries the server payload in `Contents/Resources/payload/`, so
`host/dist/webmux-host-linux-{x64,arm64}` must exist first (`make host`, with
nix, or copied in). Dev mode without ssh: `mac/scripts/dev-host.sh build` once
(a native Darwin `webmux-host`, dev only), then `mac/scripts/dev-host.sh run
dev` and run the app with `WEBMUX_MAC_DEV_SOCKET=/tmp/wm-mac/dev/http.sock`
(`WEBMUX_MAC_CONTROL=<socket>` adds the control socket for scripted smokes;
mac/README.md › Smoke); `mac/scripts/dev-host.sh stop dev` afterwards.

### Linux Electron client

`make client-linux` produces an AppImage (needs FUSE; on NixOS run it with
`appimage-run`) and a tar.gz of the unpacked app whose `./webmux` is the
same npm-style binary. There is no code signing on Linux. On NixOS the
practical install is the nixpkgs Electron plus the source tree, run with
`make client-run`.

Native Wayland is used when the Electron build enables it (nixpkgs' does);
otherwise set `ELECTRON_OZONE_PLATFORM_HINT=auto`. Saved passwords go
through libsecret (GNOME Keyring or KWallet); the startup log line records
which backend was picked.

### GTK client

`make linux-client` runs `zig build -Dapp-runtime=gtk -Dwebmux=true` inside
the fork's nix dev shell. zig decides what is stale, so the build runs
every time: seconds when nothing changed, about five minutes from cold.
Use the release binary for real work — the Debug build parses terminal
output about a hundred times slower. The fork itself, its edits to
Ghostty's own files, headless running and the smoke suites are documented
in `gtk/ghostty/WEBMUX.md`; the shell's contract in
[native-client.md](native-client.md).

The fork is <https://github.com/puntium/ghostty>, branch `webmux-shell`
(a git submodule at `gtk/ghostty`). When fork work lands, push the fork
first, then commit the submodule pointer here, so the pointer never names
a commit that isn't on GitHub. The Ghostty commit is pinned in three
places that move together: the fork's base, `host/build.sh`
(`GHOSTTY_COMMIT`) and `host/go.mod`.

## Running from source

```sh
make payload                      # the server payloads the client pushes on connect
make client-run                   # Electron: electron/node_modules/.bin/electron . (or an electron on PATH)
make linux-client-run             # GTK: release build, payload, run (ARGS=… passes arguments)
```

`client-run` uses an `electron` found on PATH, else the binary npm
downloaded. That binary needs the usual FHS libraries (NSS, GTK 3, …) on
the loader path, and on NixOS it won't start (`libnspr4.so: cannot open
shared object file`), so install the nixpkgs one — `pkgs.electron` (plus
`gnumake` and `nodejs`) in `environment.systemPackages`, or a dev shell —
and `make client-run` picks it up. One-off:
`make client-run ELECTRON=$(nix build --print-out-paths nixpkgs#electron)/bin/electron`.

Both clients keep their own state. Electron: `~/.config/webmux/config.json`
(profiles, settings) and `<userData>/logs/webmux.log`. GTK:
`~/.config/webmux-gtk/`, `~/.local/state/webmux-gtk/`, passwords in the
system keyring; it imports profiles (not passwords) from the Electron
config on first run.

## Tests

```sh
make client-test                  # Electron: profile store, IPC, tunnel state machine, lan.js, local deploy flow
cd host && nix develop . -c go test ./...          # host unit tests (go only works from host/)
cd host && node test/e2e.js && node test/migrate.js   # end-to-end harness, node → native migration
make linux-client-quick           # GTK: release build + the quick smokes (~1 min)
make mac-test                     # native macOS client: swift test, every target (~1 min; 343 tests)
```

The host's test matrix and what each harness covers:
[native-host.md](native-host.md) › Verification. The GTK client's smokes
run under a nested headless compositor with an isolated host or a fake
ssh and never touch the desktop session, real ssh or your keyring; the
quick set is for the edit-and-try loop (`make linux-client-try` runs them
and then the app), the full suite (`webmux-dev/smoke --all`, on both the
Debug and release binaries) is for the final commit — `gtk/README.md` ›
Test has the details and the performance tooling.

## Running the server by hand

```sh
make host                               # or: cd host && nix develop . -c ./build.sh --host-only
host/dist/webmux-host-linux-x64 serve   # listens on $XDG_RUNTIME_DIR/webmux/default.http.sock
curl --unix-socket $XDG_RUNTIME_DIR/webmux/default.http.sock http://localhost/api/sessions
```

The legacy node reference runs the same way (`make deps` — needs make and
g++ for node-pty — then `make start`; `make stop` shuts its pty host down).
Either is useful for hacking on the server locally; note that a client
replaces a hand-started server with its bundled payload on the next
connect. Config is env vars only (a deployed payload has no config file):

- `WEBMUX_PTYHOST=<name>` picks which pty host the server fronts (default
  `default`).
- `WEBMUX_SOCKET=/path/to.sock` overrides the http socket path. Such a run
  is a dev server on a private socket and does not write the advert.

### Pty host lifecycle

The server spawns the named pty host if it isn't running (detached,
logging to `$XDG_RUNTIME_DIR/webmux/<name>.log`). Killing or restarting
the server leaves the host — and every shell in it — running; clients
reconnect on their own. The host only stops on an explicit shutdown:

```sh
webmux-host ptyhost --name X shutdown   # shut down a specific host (kills its shells)
webmux-host ptyhost --name X list       # list a host's sessions
webmux-host ptyhost --name X ping       # is it up?
webmux-host ptyhost --name X            # run a host standalone in the foreground
```

On a deployed host the binary is `~/.webmux/dist/payload/<hash>/webmux-host`;
in a checkout it is `host/dist/webmux-host-linux-x64`. The legacy
`node ptyhost.js --name X list|shutdown` takes the same commands and works
against either implementation's daemon — the socket protocol is shared.

## Repository layout

```
electron/        Electron client: main.js (tunnels, views, IPC), deploy.js (push flow),
                 lan.js (macOS Local Network probe + hint), connect.html / header.html /
                 logs.html (client-owned pages), ui/ (the frontend: app.js, files-widget.js),
                 test/ (headless harness, lan.js unit tests, fake deploy),
                 pack-mac.js (symlink-keeping zip of the signed .app), payload/ (built)
gtk/             native GTK client: ghostty/ (the fork, a submodule), PARITY.md (feature
                 checklist), FOLLOWUPS.md (open items), audit/ (audit records); see gtk/README.md
host/            the server: Go module → static webmux-host (serve · ptyhost · start · version),
                 libghostty-vt mirror; build.sh, flake.nix, test/ (e2e, migration); see host/README.md
server.js        legacy node server (reference for the port; no longer pushed)
ptyhost.js       legacy node pty daemon; ptyhost-client.js is its control-socket client
deploy/          build-payload.js (per-platform payload tarballs from host/dist),
                 remote-start.js (legacy node starter; now `webmux-host start`)
shims/           xdg-open / xclip / xsel … stand-ins put on each session's PATH
docs/            this and the other design notes
Makefile         host-libs · host · payload · client-deps · client-test · client · client-run ·
                 client-linux · linux-client · linux-client-run · linux-client-quick ·
                 linux-client-try · clean · deps/start/stop (legacy node)
```

Project conventions (what "commit and push" means for the two repos) are
in `CLAUDE.md`.
