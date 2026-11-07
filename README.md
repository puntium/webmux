# webmux

Persistent terminal sessions on a remote host, tiled in a native desktop
client over SSH.

Your shells run on the remote machine inside a small daemon and keep
running — screen buffer, scrollback, cursor and all — whether or not a
client is attached. The client tiles them in scrolling columns (niri /
PaperWM style), and on reattach every pane repaints from a snapshot of
exactly what the session looks like now. Think tmux, with the layout and
the rendering on your side of the wire.

## Features

- **Sessions that survive everything short of an explicit shutdown.**
  Tunnel drops, laptop sleep, network changes, client restarts and server
  upgrades all just detach; reattaching replays the session's state.
- **Zero install on the host.** The host needs nothing but `sshd`.
  Connecting pushes a single static binary (`webmux-host`, linux-x64 and
  linux-arm64, glibc or musl) over ssh and starts it; later connects reuse
  it, and a new client version replaces it in place.
- **Scrolling column layout.** A horizontal strip of columns, each a stack
  of panes, driven from the keyboard: new terminal, close, focus by
  direction or `hjkl`, expel/merge a pane out of or into a neighbouring
  column, move columns and panes, toggle a pane to the whole window.
  Column widths follow a min/max terminal width you set; the layout is
  kept per client, per host.
- **Several hosts at once.** One connection profile per host (ssh host,
  port, identity file, extra options, optional saved password in the OS
  keychain), pills in the header to switch between them, independent
  named instances on the same host when you want separate setups.
- **A Finder-style file browser pane.** Miller columns rooted at `/`,
  keyboard navigation like yazi, live-updating listings, previews (text,
  images, rendered Markdown, zip contents), download, drag-and-drop and
  paste upload, rename and delete.
- **Clipboard that works across the wire.** OSC 52 copies from vim,
  tmux or Claude Code land on your local clipboard. Pasting an image into
  a pane uploads it and hands it to the foreground program — Claude Code
  attaches it directly; anything else gets the file path typed in.
- **Links and browsers.** URLs in terminal output are clickable (plain
  text and OSC 8). Programs on the host that try to open a browser
  (`xdg-open`, `gh pr view --web`, OAuth logins) open one on your desk
  instead.
- **Connection resilience that explains itself.** Keepalives and probes
  notice a dead link in seconds, retries restart a dead server, and the
  client's connection log records every tunnel, deploy, probe and retry
  for pasting into a bug report. Passwords never appear in it.
- **No TCP ports, no TLS, no auth of its own.** The server listens on a
  unix socket; filesystem permissions and `sshd` are the whole access
  story.

## Clients

| Client | Platforms | Where |
| --- | --- | --- |
| **Electron** — the original client; xterm.js panes, the UI bundled in the app | macOS, Linux | `electron/` · [docs/electron-client.md](docs/electron-client.md) |
| **webmux-gtk** — a native GTK4 client built as a fork of Ghostty, using Ghostty's terminal core and renderer | Linux | `gtk/` · [gtk/README.md](gtk/README.md) · [docs/native-client.md](docs/native-client.md) |
| **webmux.app** — a native Swift/AppKit client on GhosttyKit (the same fork's terminal core and Metal renderer), native toolbar, menus, Settings and Connections windows, Keychain | macOS (arm64) | `mac/` · [mac/README.md](mac/README.md) · [docs/macos-client.md](docs/macos-client.md) |

Both push the same server payload and share the same protocol, so they can
be pointed at the same host and even the same sessions.

## Getting started

1. **Build or install a client** — see [docs/development.md](docs/development.md)
   › Building. On macOS, drag `webmux.app` to `/Applications` and clear
   the quarantine flag (`xattr -dr com.apple.quarantine /Applications/webmux.app`);
   allow Local Network and Keychain access on first launch.
2. **Add a connection** — *Connections* (⌘⇧O on macOS, Ctrl+Shift+O on
   Linux): a name and an ssh host, plus whatever ssh needs. **Connect**.
   The first connect pushes the server to the host; it takes a few
   seconds.
3. **Open a terminal** — ⌘↩ (Ctrl+Shift+↩ on Linux). The full key table
   and everything else about daily use is in [docs/using.md](docs/using.md).

## Documentation

| | |
| --- | --- |
| [docs/using.md](docs/using.md) | User guide: connections, layout and keys, the file browser, clipboard and tmux, image paste, the log |
| [docs/how-it-works.md](docs/how-it-works.md) | Architecture: the pty host, the server, the clients, persistence, the wire protocol, resilience, clipboard and paste mechanics, limitations |
| [docs/development.md](docs/development.md) | Building, running from source, tests, the dev server, pty-host lifecycle, packaging, repository layout |
| [docs/native-host.md](docs/native-host.md) | The Go + libghostty-vt server (`host/`): design, build pins, deviations from the node reference, verification |
| [docs/electron-client.md](docs/electron-client.md) | The Electron client: tunnel supervision, liveness, client-owned pages |
| [docs/native-client.md](docs/native-client.md) | The GTK client: the contract it was built against, rulings, status |
| [docs/push-deploy.md](docs/push-deploy.md) | Connect-is-deploy: payloads, remote layout, versioning |
| [docs/signing.md](docs/signing.md) | Signing the macOS app and why it is required |
| [docs/restart-resilience.md](docs/restart-resilience.md) | Why the pty host exists (design history) |
