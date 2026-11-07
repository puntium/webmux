# Using webmux

Everything about daily use: connecting, the layout and its keys, the file
browser, clipboard and image paste, and where to look when something is
off. Written for the Electron client; the GTK client follows the same
model and keys, and records where it deliberately differs in
[native-client.md](native-client.md) › Deliberate deviations.

Shortcuts are given macOS first, Linux second. On Linux, Super belongs to
the compositor, so the pane chords use **Ctrl+Shift** (as other Linux
terminals do) and the app shortcuts use **Ctrl**; where macOS adds ⌥ to a
chord, Linux adds Alt. ⇧ is spent on the Linux chord, so the few ⇧
variants on macOS have no Linux counterpart and a different key stands in
(noted in the tables).

## Connections

**Connections** (⌘⇧O / Ctrl+Shift+O, or the *Connections* page) lists your
profiles. A profile is a name and an ssh host, optionally a port, an
identity file, extra ssh options, a saved password (encrypted in the macOS
Keychain, or the OS keyring via libsecret on Linux — GNOME Keyring or
KWallet; otherwise key auth via BatchMode), and an **instance name**.

**Connect** on a profile opens an ssh tunnel to the host. The first connect
to a host pushes the server payload for its platform (one static
`webmux-host` binary plus shims) over ssh and starts the server; later
connects reuse what is there, and a client with a newer payload replaces
it on connect (sessions are not affected — see
[how-it-works.md](how-it-works.md) › Persistence).

Several hosts can be connected at once. The header shows one pill per
connected host (drag to reorder); switch with ⌘1…⌘9 / Ctrl+1…9, or
⌘⇧[ and ⌘⇧] / Ctrl+PageUp and Ctrl+PageDown for previous / next.
⌘⇧R / Ctrl+Shift+R reconnects the current host.

**Instances.** A profile's instance name (blank = `default`) selects which
named server/pty-host pair it talks to on the host. Distinct instances are
fully independent — own sockets, own sessions — so several webmux setups
can coexist on one machine.

**Pill colours.** A host whose tunnel is up but whose page has a session
socket down and retrying shows as an amber *degraded* pill: the chrome
never claims "connected" over a terminal that says "disconnected".

### When a connect fails

A connect that never succeeded (typo'd host, wrong password) parks as
*failed* with ssh's stderr and waits for you; nothing retries in the
background while you edit profiles. A connection that was established and
then interrupted retries by itself (backoff 1 s → 15 s), and every retry
re-runs the deploy step, which restarts a dead server before tunnelling.

On macOS, **Local Network privacy** (macOS 15+, stricter on 26.5+/27)
gates ssh to LAN hosts (`.local` names, RFC 1918 and link-local addresses)
behind a per-app grant. Allow it when asked. If a connect fails instantly
with `No route to host`, the connection page says so in those words and
points at *System Settings › Privacy & Security › Local Network*; the
parked connection keeps probing for three minutes and reconnects by itself
once a connection goes through. If the app never appears in that list, or
the toggle is on and connects still fail, the app's signature is the
likely cause — see [signing.md](signing.md) › Troubleshooting.

## The layout

The workspace is a horizontal strip of **columns**, each a vertical stack
of one or more **panes** — a terminal or a file browser — like niri or
PaperWM. Column widths follow two settings, in characters: *Minimum
terminal width* (default 90) and *Maximum terminal width* (default 200).
As many columns as fit the window at the minimum share it exactly, so a
wide window shows three, four or five whole columns; fewer columns than
that grow to share the window up to the maximum and sit centred; open more
and the strip scrolls sideways, following the focused pane. The focused
pane wears an accent border and its title bar spans the pane's width.

| macOS | Linux | Action |
| --- | --- | --- |
| ⌘↩ | Ctrl+Shift+↩ | new terminal, as a new column right of the focused one |
| ⌘⇧↩ | Ctrl+Shift+B | new file browser, likewise |
| ⌥⌘↩ | Ctrl+Shift+Alt+↩ | new terminal stacked directly below the focused pane |
| ⌘W | Ctrl+Shift+W | close the focused pane (kills a terminal's session, no confirmation) |
| ⌘F | Ctrl+Shift+F | toggle the focused pane to the whole window; a stacked pane first splits out into its own column |
| ⌘← → ↑ ↓, ⌘h j k l | Ctrl+Shift+arrows, Ctrl+Shift+h j k l | move focus between columns / within a stack (each column remembers its active pane) |
| ⌘[ ⌘] | Ctrl+Shift+[ ] | expel or merge, as in niri: a pane sharing a column splits out into its own column on that side; a pane alone in its column merges into the neighbouring column on that side (at the bottom; the column it empties goes away). Two taps carry a stacked pane into the next column |
| ⌥⌘← → | Ctrl+Shift+Alt+← → | move the whole column (stack and all) left / right, swapping with its neighbour |
| ⌥⌘↑ ↓ or ⇧⌘↑ ↓ | Ctrl+Shift+Alt+↑ ↓ | move the pane up / down within its stack |

The same commands sit in the **Pane** menu. On GNOME, Ctrl+Shift+Alt+arrows
is taken by the desktop (move window to workspace), so there the vim
letters are the way to move columns and panes. The Linux menu bar is
hidden; a lone Alt tap shows it (Esc or another tap hides it), chords
don't.

Other pointers:

- **+ New terminal** / **+ Files** in the header do what ⌘↩ / ⌘⇧↩ do.
- Drag the divider between stacked panes to resize them; widths follow the
  column rule. Two-finger horizontal scrolling pans the strip.
- **✕** in a pane's title bar closes it — for terminals that kills the
  session; a shell exiting closes its pane on its own. A closing column
  shrinks away and its neighbours slide in; a closing stacked pane
  collapses while the rest of its stack grows into its place. Focus moves
  to the next pane in the stack, else to a neighbour.
- Panes are titled with the terminal title when the running program sets
  one (shell prompts, vim); titles survive reattach.
- ⌘R reloads the page: live sessions reattach with state and layout
  intact. Sessions opened elsewhere (another client, or before the last
  reload) appear as columns on the right. On Linux a focused terminal
  takes Ctrl+R (reverse search), so reload is in the *View* menu; in
  practice *Reconnect* covers it.
- The layout is remembered per client, per host, so each of your machines
  keeps its own arrangement matching its own screen.

## Settings and the connection log

**⚙** in the header (⌘, / Ctrl+,) opens the settings panel: the colour
scheme (*Dark mode default* or *Light mode*), how much unfocused panes
fade, and the minimum and maximum terminal widths. Settings are
client-wide: every connected host follows a change at once.

**Open log…** in that panel (also ⌃⌘L / Ctrl+Shift+G, the *Log* button on
the connection page, or *Connection Log…* in the app menu) opens the
connection log: every tunnel setup, deploy step, probe miss, tunnel exit,
retry, and every session-socket drop and reconnect reported by a host
page. Live tail, filter by host / level / text, *Copy visible* / *Copy
all* for pasting into a bug report. The same lines go to
`<userData>/logs/webmux.log` (rotated at 1 MB). Passwords never appear —
only which auth mode was used.

## Links and browsers

- Click a URL in a terminal (plain text, or an OSC 8 hyperlink such as
  Claude Code's `/login` link) to open it in your default browser.
  Shift-click copies it to the clipboard instead.
- Programs on the host that try to launch a browser (`xdg-open`,
  `sensible-browser`, `x-www-browser`, `$BROWSER` — e.g. `gh pr view
  --web`, OAuth logins) reach shims instead, and the URL pops up in the
  client viewing that session with an open / copy chooser.

## File browser

**+ Files** (⌘⇧↩ / Ctrl+Shift+B) opens a Finder-style Miller-columns file
browser pane: one column per directory level, rooted at `/`, starting in
`$HOME`. It is a pane like any other — it moves around the strip, stacks,
and comes back with the layout.

- **Navigate** by clicking, or with the arrow keys / `hjkl` like yazi.
  Drilling back into a directory visited earlier re-selects the entry the
  cursor was on there. The title bar shows the path to the selection
  (`$HOME` as `~`), collapsing parents to `…` before it would cut into the
  file name. Columns size themselves to their longest name.
- **Preview.** Selecting a file shows a preview column: text (first
  64 KB), images, a zip's table of contents as a `tree`-style listing, or
  just size and mtime for binaries. Markdown renders by default with a
  *Rendered / Source* toggle; relative images load, web links open in the
  browser (shift-click copies), relative links navigate the browser to
  that entry. `→` on a file drills into the preview — `↑`/`↓`,
  PageUp/PageDown, Home/End scroll it — and `←` steps back.
- **Download.** The preview header's ⤓ button (or `D`) saves the file to
  the local machine through the usual save dialog; the outcome is noted
  in the connection log.
- **Upload.** Drag files or folders onto a column to upload into that
  directory — several at once is fine, folders recreate their tree (empty
  subdirectories are skipped). Files or images pasted while the browser
  is focused upload into the rightmost directory shown. Colliding names
  are deduplicated Finder-style.
- **Rename / delete.** `r` or `F2` renames inline; `d`, `Delete` or
  `Backspace` deletes after a confirmation centred in the pane
  (directories recursively). The ✎ / ✕ buttons on a row do the same.
- **Listings stay live.** The cursor's directory and the folder it points
  at are watched and re-list on change; a pane regaining focus re-lists
  every column shown.

## Clipboard: copying from the host (OSC 52)

Any program that copies via OSC 52 — vim/neovim clipboard providers,
Claude Code's copy actions, `tmux set-buffer -w` — lands on your local
clipboard. Clipboard *reads* via OSC 52 are ignored.

**Running tmux inside a webmux pane** needs one line of tmux config to
pass copies through:

```tmux
set -s set-clipboard on
```

tmux intercepts OSC 52 from its inner programs rather than forwarding it.
What reaches webmux depends on `set-clipboard` (verified with tmux 3.5a):

| `set-clipboard` | action inside tmux | tmux buffer | forwarded to webmux |
|---|---|---|---|
| `on` | program emits OSC 52 | ✅ | ✅ |
| `external` (default) | program emits OSC 52 | ❌ dropped | ❌ |
| `on` / `external` | `tmux set-buffer -w` / copy-mode copy | ✅ | ✅ |
| `on` / `external` | `tmux set-buffer` (no `-w`) | ✅ | ❌ |

So with the default `external`, a copy from e.g. Claude Code running
inside tmux is silently discarded; with `on`, tmux stores it as a buffer
*and* re-emits the OSC 52 outward, where webmux picks it up.

One more prerequisite (satisfied on most systems): tmux only forwards if
the outer terminal's terminfo advertises the `Ms` capability. webmux
sessions run with `TERM=xterm-256color`, whose standard terminfo entry
includes it; if yours doesn't (`infocmp -x xterm-256color | grep Ms`
prints nothing), add:

```tmux
set -as terminal-overrides ',xterm-256color:Ms=\E]52;%p1%s;%p2%s\007'
```

## Pasting

⌘V / Ctrl+V (and Ctrl+Shift+V on Linux) paste. Text pastes as usual. An
**image** on the clipboard is uploaded to the host and handed to the
pane's foreground program:

- If it is Claude Code, Claude attaches the image natively — exactly as
  if you had pasted it into a local terminal.
- Otherwise the image's temp-file path on the host is typed at the
  prompt.

The clipboard image is also synced to the host whenever the window
regains focus, so a plain paste into Claude Code finds it too. Ctrl+Alt+V
always sends a literal `^V` (vim visual-block). The mechanics are in
[how-it-works.md](how-it-works.md) › Image paste.

## Known limitations

- One shared size per session: the last attached client's resize wins, so
  viewing one session from two differently sized windows reflows it.
- Sessions live in the pty host process; they do not survive a host
  reboot or an explicit pty-host shutdown (no on-disk persistence).
- The clipboard slot on the host is global — one clipboard for all panes,
  like a real desktop.
