# webmux-gtk: the native Linux client

A fork of Ghostty with a new GTK4 shell that speaks the webmux protocol
directly (no local pty, no bridge command). Built to match the Electron
client feature for feature.

| What | Where |
| --- | --- |
| The contract: goal, architecture, rulings, deliberate deviations, status | `../docs/native-client.md` |
| The fork: <https://github.com/puntium/ghostty>, branch `webmux-shell` (ghostty-org/ghostty at `f54340ad` plus our commits). A git submodule of this repo, which pins the fork commit | `ghostty/` |
| How to build, run headless, test, and the list of edits to Ghostty's own files | `ghostty/WEBMUX.md` |
| Feature checklist with a status per item | `PARITY.md` |
| Audit, re-check and final-check reports | `audit/` |
| Everything left open, and decisions waiting on you | `FOLLOWUPS.md` |

## Build

```sh
git submodule update --init gtk/ghostty   # once, from the repo root
cd gtk/ghostty
webmux-dev/build                      # Debug: zig-out/bin/webmux-gtk
nix develop . -c zig build -Dapp-runtime=gtk -Dwebmux=true \
  -Doptimize=ReleaseFast --prefix "$PWD/zig-out-release"   # release, about 5 minutes
```

Use the release binary for real work: the Debug build parses terminal
output about a hundred times slower.

## Test

```sh
cd gtk/ghostty
webmux-dev/smoke --all                                         # Debug binary
WEBMUX_GTK_BIN=$PWD/zig-out-release/bin/webmux-gtk webmux-dev/smoke --all
```

Everything runs under a nested headless compositor with an isolated host
or a fake ssh; nothing touches the desktop session, real ssh, or your
config, keys or keyring.

## Run

```sh
make linux-client-run        # from the repo root: release build, payload, run
make linux-client            # build only; GTK_OPTIMIZE=Debug for a debug build
gtk/ghostty/zig-out-release/bin/webmux-gtk    # the binary itself
```

`ARGS=…` passes arguments to the app.

It has run on a real GNOME desktop once (2026-11-05, which led to the
standard header bar); as far as the records here go it has not yet been
connected to a real sshd. It keeps its own state
(`~/.config/webmux-gtk/`, `~/.local/state/webmux-gtk/`, passwords in the
system keyring), imports profiles from the Electron client's
`~/.config/webmux/config.json` on first run (without passwords), and on
connect pushes the same host payload the Electron client pushes
(`electron/payload/`, found by walking up from the binary). See
`FOLLOWUPS.md` › Decisions waiting on you.
