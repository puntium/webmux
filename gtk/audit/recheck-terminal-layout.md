# Re-check after the fix round: terminal pane, clipboard, shims (terminal.md) and sessions, layout, shortcuts (layout.md)

Verifier: independent. I built and fixed none of this. Date: 2026-11-04. Binary: `gtk/ghostty/zig-out/bin/webmux-gtk` (Debug), used
as built. Nothing under `gtk/ghostty` was edited or rebuilt. My helper scripts are in `/tmp/rechk-tl-1139383`.

## How this was exercised

Five headless runs, all through `webmux-dev/headless`. All were stopped, and `pgrep` on every run dir and on my scratch dir shows
nothing left:

| Run | Start | Used for |
| --- | --- | --- |
| `/tmp/wm-n6UsuD` | `--host -- GTK_IM_MODULE=gtk-im-context-simple` | key encodings, IME, scrollback, padding, OSC 52, selection, scrollbar, dividers, layouts, K-18, S-09 |
| `/tmp/wm-neuFsF` | full app, `WEBMUX_GTK_SSH=fake-ssh`, hosts `alpha` and `beta` | header menu (Edit › Paste/Copy), deviation 31, S-13, app shortcuts on fr/ru/de, zoom, link chooser, vi/less/htop, bash paste, light scheme, resize, disconnect and reconnect |
| `/tmp/wm-pygcRQ` | `--host --scale 2 --size 1920x1200` | HiDPI padding and cell size, divider drag and selection at scale 2, host restarts (D-10), screenshot with settings open, strip chase, slow-motion ghost |
| `/tmp/wm-peOlxF` | `--host` | wheel and touchpad at scale 1, file browser beside a terminal, real clicks on the title bar and ✕, links and OSC 8 |
| `/tmp/wm-uAQN7S` | full app, two fake hosts | focus after every chrome control, clicked with a real pointer |

All input was real, sent through sway:

- **Keys:** `realkeys-xkb` with real XKB layouts (`us`, `ru`, `us,ru` group 1, `gr`, `il`, `fr`, `de`, `us` intl), and `realkeys`
  for plain text.
- **Pointer:** `realpointer`, `with-mods` and `chrome-click`. This covers press, double-click, drag, wheel, finger scroll and the
  header popover.
- **Key bytes:** captured by my own raw-mode reader (`rr.py`) inside the session. Expected bytes come from reading
  `@xterm/xterm/src/common/input/Keyboard.ts` directly, not from the engineers' `xterm-keys` harness.
- **Control socket:** used only to read state and to set up scenarios.
- **Safety checks before any `xdg-open`:** inside the fake-host session, `command -v xdg-open` resolved into the payload's `shims/`
  directory, and `DISPLAY` was `no-such-display.invalid:0`. The tmux check below ran no launcher; it only ran `command -v` on a
  private tmux socket.

## terminal.md

| ID | Verdict | How verified / what happens now |
| --- | --- | --- |
| T-03 scrollback | FIXED | After `seq 1 30000` finished: scrollbar total 5625, and the top of the scrollback is `24379`, so 5622 lines are kept (5000 or more). |
| T-09 padding | FIXED | Pixels at scale 1: the pane body starts at x=7 and the first glyph pixel is at x=11. The body top is y=32 and the first row is at y=36, so 4 px on both axes. At scale 2, `padding_px` is 8 device px (4 CSS px). |
| T-12 modified Enter/Tab/Esc, Alt+arrows | FIXED | Real keys into the raw reader: Shift/Ctrl+Enter and KP_Enter → `\r`; Alt+Enter → `\e\r`; Ctrl+Tab → `\t`; Ctrl+Shift+Tab and Alt+Shift+Tab → `\e[Z`; Ctrl/Shift+Esc → `\e`; Alt+Esc → `\e\e`; Alt+←/→/↑/↓ → `\e[1;5D/C/A/B`. Also checked about 60 other combinations against Keyboard.ts, all byte-exact: Ctrl/Alt/Shift+BackSpace, Ctrl+Alt+BackSpace `\e\b`, Ctrl+Alt+← `\e[1;7D`, Shift+Alt+← `\e[1;4D`, Insert and Alt+Insert `\e[2~`, Delete with modifiers, Home/End with modifiers, Alt+PgUp/PgDn `\e[5~`/`\e[6~`, F1/F5/F11/F12 with modifiers, Ctrl+letters, Ctrl+Space/[/\/], Ctrl+/ (nothing, as in xterm.js), Ctrl+Shift+- `\x1f`, Ctrl+Shift+2 `\0`, Alt(+Shift)(+Ctrl)+letter, Alt+digit and punctuation, Ctrl+Shift+Alt+[ `\e{`, Ctrl+Shift+Alt+B `\e\x02`, Ctrl+Shift+1 and Ctrl+' and Ctrl+; (nothing). Application cursor mode gives `\eOA \eOD \eOH \eOF`. Russian layout: С→`с`, Ctrl+С `\x03`, Alt+Ч `\ex`. German: Ctrl+Z (the physical Y key) `\x1a`. With the Kitty protocol on (`\e[>1u`), Ghostty's encoder is used (`\e[13;2u`, `\e[9;5u`, `\e[97;6u`), as the ruling says. In bash, Shift+Enter and Ctrl+Enter run the line. |
| T-14 IM Ctrl+Shift+U | FIXED (simple IM) | With `gtk-im-context-simple`: Ctrl+Shift+U 2 6 0 3 Space → `☃`; Ctrl+Shift+U 1 F 6 0 0 Enter → `😀`. The pre-edit `u26` is drawn underlined at the cursor (screenshot). Dead keys: de ´+e → `é`, ^+a → `â`; us intl ¨+u → `ü`, `+a → `à`. With the default IM and no IM server, Ctrl+Shift+U sends nothing, as xterm does. IBus and fcitx: CANNOT VERIFY (no IM server). |
| C-01 OSC 52 invalid UTF-8 | FIXED | `\e]52;c;/w==` → `wl-paste` gives `EF BF BD` (U+FFFD). A mixed payload gives `héllo � world`, and the toast appears. |
| C-06 Edit › Paste with an image | **NOT FIXED** (for a real user) | The action is now correct: with a terminal focused, `wmctl menu action=activate label=Paste` runs the image flow (`uploading pasted image…`, then `pasted image → …`). With the real ☰ menu (real pointer: ☰ → Edit → Paste) nothing happens: no toast, nothing typed. The popover holds keyboard focus when the item fires, so `focusedTerminal()` (`chrome/menu.zig:357`) finds no terminal and calls `clipboard.paste` on the popover. See new defect N1. |
| T-02 font load race | CANNOT VERIFY (READ, unchanged) | Embedded font, nothing to race. The judgement stands. |
| C-03 clipboard write failure toast | CANNOT VERIFY (READ, unchanged) | I could not provoke a failure. The code path is unchanged. |
| D-01 Shift+PgUp/PgDn | FIXED | `seq 1 300`, real Shift+PgUp: offset 251 → 202 → 104 (49 = rows−1 per press); Shift+PgDn → 153. Nothing reaches the shell. In `less` (alternate screen) the view does not move and nothing is sent, as in xterm. With the Kitty protocol on, the key goes to the app (Ghostty's encoder, per the ruling). |
| D-02 Shift/Ctrl+Insert | FIXED | Shift+Insert pastes CLIPBOARD. Ctrl+Insert copies the selection (made with a real drag) to CLIPBOARD and sends nothing to the pty. |
| D-03 | FIXED | Same as T-12. |
| D-04 Edit › Copy toast | PARTLY | Through the control socket with a terminal focused: CLIPBOARD gets the selection, offered only as `text/plain` (no `text/html`), and there is no toast. Through the real ☰ menu, Edit › Copy does nothing: CLIPBOARD stays at its old value. Same cause as C-06 (N1). |
| D-05 | FIXED | Same as T-14. |
| D-06 selection edge cases | **NOT FIXED** | Real double-click on the space in `` foo ` bar `` selects `` ` `` with its surrounding spaces. On a space or on `(` in `bar (  ) baz` it selects ` (  ) `. xterm selects only the run of spaces, or only `(` (`SelectionService.ts:832-900`). A plain click, then Shift+click elsewhere, still selects nothing. Shift+click after a drag does extend. Low severity. |
| D-07 first click in an unfocused pane | FIXED | With two panes, one real click on a URL in the unfocused pane focused it and opened the URL (url-sink). One real drag in the unfocused pane focused it and selected `399\n40`. |
| D-08 scrollbar drag into the band | FIXED | Real drags of the scrollbar thumb, 403 lines with 50 rows: ending 9 lines from the bottom it stays at 9; ending about 4 lines from the bottom it snaps to the bottom (offset 353). |
| D-09 cell width | DEVIATION 42 (matches) | The cell is now 7×17 at scale 1 and 15 device px wide at scale 2, the same as xterm's WebGL floor. |
| D-10 host lost the head of a snapshot | CANNOT VERIFY (not reproduced) | `seq 1 300`, then two `host-restart`s: after each, scrollback total 301 and the top line is `1`. |
| D-11 tmux login shell loses the shims | NOT FIXED (host side; the same in the Electron client) | In a fake-host session, tmux on a private socket: `command -v xdg-open` gives `/run/current-system/sw/bin/xdg-open`, with `$0` = `-sh`. `DISPLAY` stays invalid. The host's shims design is unchanged and was not part of the fix round. |
| D-12 settings dialog GTK warnings | FIXED | Opened settings at 900×600 and 1000×700: no `Gtk`/`Adwaita` height warnings in `app.log`. The dialog fits. |
| D-13 `invalid C0 character 0x18` | FIXED | 0 occurrences in `app.log` across all runs, about 15 attaches. |

## layout.md

| ID | Verdict | How verified / what happens now |
| --- | --- | --- |
| S-09 false "session exited" on close | FIXED / DEVIATION 45 (matches) | Real Ctrl+Shift+W: only `DEBUG … session socket closed (tab closed or session exited) … code=1005`. Real `exit 3`: the socket-closed line comes first, then `INFO … session exited … exitCode=3` 1.2 s later, as deviation 45 says. |
| S-13 Reconnect re-lists sessions | FIXED | Full app: a session was created on beta by `curl -X POST` on the tunnel socket, then real Ctrl+Shift+R. The log shows `beta: reload`, and the new session appeared as a column (2 → 3 panes). The existing panes and keyboard focus were kept, and typing worked. |
| L-30 divider drag | FIXED | Real pointer, 20 steps of 10 px up: the divider ends under the pointer, with weights 0.5495/1.4505 (exactly app.js's `(clientY−top)/size`). With the pointer held still for 2 s (repeated motion at the same y), the divider stayed put (sampled 4 times). Dragging back down 300 px ended under the pointer. Same at scale 2. Note: in this Debug build the divider trails a fast drag by about 1 s (observation O1). |
| K-16 chords by physical key | FIXED | Real keys, focus in a terminal and in a file browser. Ctrl+Shift+H/L/J/K and the arrows under `ru`, `us,ru` group 1, `gr`, `il`, `fr`, `de` move focus correctly. Ctrl+Shift+[ and ] under `fr` (dead ^ key), `de` (ü key) and `ru` expel and merge. Ctrl+1 and Ctrl+2 under `fr` (& and é) and `ru` switch hosts; Ctrl+Shift+O under `ru` opens the connection page; Ctrl+PgUp under `fr` cycles. No CSI-u text reached any shell. Ctrl+Shift+A under `ru` sends nothing. Zoom: see N4. |
| K-18 chords under the file browser's delete confirmation | FIXED | `Delete "rr.out"?` open. Real Ctrl+Shift+L, H, Enter, Alt+Enter, W, F, ], Alt+L and B were all swallowed: no focus move, no new pane, the confirmation still open, the file still there. Also swallowed over the settings dialog and the link chooser. |
| Deviation 31 (app shortcuts under a dialog) | FIXED (DEVIATION 31 now true as written) | Settings dialog open: real Ctrl+1 → alpha, Ctrl+2 → beta, Ctrl+PgUp and Ctrl+PgDn cycle, Ctrl+Shift+O → connection page, Ctrl+Shift+G → log window. Ctrl+Shift+L, Enter and W did nothing. Ctrl+1 also works with the link chooser open. |
| S-12 link-down aggregation | CANNOT VERIFY live (READ: now matches app.js) | `workspace.zig:618-630`: the last socket event wins ("down when any drops, up when any opens"), which is app.js `setLinkDown`. |
| L-32 ghost under a shrinking pane | OK (now seen) | Slow-motion screenshot (time_scale 15) during new-terminal-below: the ghost band lies under the shrinking pane, and `ghosts: 1`. Looks right. |
| L-35 overlap draw order | CANNOT VERIFY (READ, unchanged) | Not checked frame by frame. Nothing looked wrong in the mid-flight screenshots. |
| L-36 divider identity across merges | CANNOT VERIFY (READ, unchanged) | Expel and merge under three layouts animated without visible jumps. Not checked frame by frame. |
| Outside 1 (non-Latin chords type garbage) | FIXED | Same as K-16. |
| Outside 2 (false exit log) | FIXED | Same as S-09. |
| Outside 3 (Ctrl+Shift+Alt+[ ] F B, Ctrl+Shift+1 send bytes) | FIXED | They now send xterm's bytes: `\e{`, `\e\x02`, `\e\x06`; Ctrl+Shift+1 sends nothing. |
| Outside 4 (settings GTK warnings) | FIXED | Same as D-12. |
| Outside 5 (black host view behind settings in screenshots) | FIXED | A `wmctl screenshot` with settings open shows the dimmed host view behind the dialog. grim shows the same. |
| Outside 6 (first chase frame jumps) | CANNOT VERIFY (not reproduced) | Sampled a 3816 px chase every 1–2 ms: it shrinks about 6 % per few ms at the start and 0.76 per 16 ms after, with no outsized step. The last 4 px go 1 px per frame (a linear tail), which is cosmetic. |
| Outside 7 (resize per terminal per frame) | DEVIATION 20 (unchanged) | |
| Outside 8 (layout save debounce) | DEVIATION 35 (now recorded) | |
| Outside 9 (`invalid C0` at attach) | FIXED | Same as D-13. |
| K-23 note (settings from the connection page) | DEVIATION 32 (matches) | |
| K-29 note (`^[[200~` garbage on paste) | FIXED | Dev-host `sh` (bash 5.3): real Ctrl+V then Ctrl+Shift+V gives `$ PASTED2PASTED2`, with no escape text. bash `--norc`: pasted commands run cleanly. |

## New defects

Ordered by how much a user would care.

### N1 (high): the ☰ header menu leaves the window with no keyboard focus, and its Edit items act on nothing

**What happens.** After the popover closes, by Escape or by choosing an item that does not create a pane, no widget has keyboard
focus (`workspace --get has_keyboard_focus_in` = null).

- Typed text goes nowhere.
- Pane chords do nothing; Ctrl+Shift+Enter opened no column.
- Opening and closing settings does not bring focus back.

Only clicking a pane does, or a chrome action that moves focus. Other chrome controls hand focus back correctly when clicked with a
real pointer: the gear and Escape, a pill, "+ New terminal", and Connections then Show. Pane › New Terminal Below from the menu also
works, because the new pane takes focus.

**Edit menu.** Edit › Copy, Paste and Select All run while focus is inside the popover. So `focusedTerminal()`
(`chrome/menu.zig:357`) finds no terminal, and they call the GTK text action on the popover instead. This is why C-06 and D-04 are
not fixed for a real user. `header.zig:163` `onMenuClosed → hub.focusContent()` exists but has no visible effect.

**Repro** (full app):

1. Click in a terminal.
2. `chrome-click $D header.menu`.
3. `realkeys-xkb $D Escape`.
4. `realkeys $D 'echo X' -k Return`. Nothing appears.

For Edit: put a selection or an image on the clipboard, then ☰ → Edit → Copy or Paste with `realpointer`. The clipboard is
unchanged, or nothing is pasted.

### N2 (medium): scrolling distance is wrong for touchpads, and doubles on HiDPI

- **Touchpad.** A finger scroll of 4 × 20 px moved the scrollback **44 lines** at scale 1. The Electron client (pixel-based,
  17 px rows) would move about 5. This is Ghostty's stock ×10 precision multiplier on top of GTK's pixel deltas
  (`pane.zig:1189`).
- **HiDPI wheel.** At scale 2, one wheel notch scrolls **6 lines** (12 for 2 notches), and Alt+wheel scrolls 30. At scale 1 it is
  3 per notch. `scaledCoordinates()` is applied to the scroll deltas (`pane.zig:1191`). Deviation 18 promises 3 lines per notch.

**Repro.** Scale 1: `realpointer $D abs X Y, fscroll 0 -20, sleep 16, …×4, fstop` → offset 346 → 302. Scale 2:
`realpointer $D abs X Y, scroll 0 -2` → 12 lines.

### N3 (low–medium): an xdg-open chooser from one host stays on screen after switching to another host

A session on `beta` ran `xdg-open https://example.org/a`, and the chooser showed. Ctrl+1 then switched to `alpha`, and the chooser
for beta's URL now sits over alpha's terminals (screenshot `/tmp/rechk-tl-1139383/g7.png`). In the Electron client the modal belongs
to beta's page and is hidden with it. It is not recorded as a deviation. Escape closes it, and focus returns correctly.

### N4 (low): Ctrl++ does not zoom in on layouts where + is unshifted

Example: German. Real `--layout de ctrl+plus` left the cell size unchanged. Only Ctrl+= and Ctrl+Shift+= are bound, by keyval
(`shortcuts.zig:83-86`). Deviation 40 says zoom matches "the layout's character", and Electron's zoomIn accelerator is
Ctrl+Plus. On `fr`, Ctrl+= zooms. Ctrl+- (the physical 6 key) is taken by the host-6 shortcut, which also happens in the Electron
client, because Ctrl+Digit6 is always prevented there.

### O1 (observation, Debug build only)

During a fast real divider drag (30 motions in about 0.45 s), the divider trailed the pointer by about 1–1.5 s, then settled exactly
under it. Each step re-fits two terminals. Check this in the release build.

### O2 (observation, negligible)

A key pressed within about 10 ms of Ctrl+V or Ctrl+Shift+V reaches the pty **before** the pasted text: the paste reads the
clipboard asynchronously. With a gap of 20 ms or more the order is correct. No human types that fast.

## Summary

42 rows: 21 from terminal.md and 21 from layout.md, including the outside-the-checklist items and two notes.

| Verdict | Count | Items |
| --- | --- | --- |
| FIXED | 26 | T-03, T-09, T-12, T-14, C-01, D-01, D-02, D-03, D-05, D-07, D-08, D-12, D-13; S-09, S-13, L-30, K-16, K-18, deviation 31, layout outside 1/2/3/4/5/9, K-29 note |
| NOT FIXED | 3 | C-06 (real menu), D-06, D-11 (host side) |
| PARTLY | 1 | D-04 (no toast now, but real Edit › Copy does nothing) |
| DEVIATION (matches) | 4 | D-09 (42), outside 7 (20), outside 8 (35), K-23 (32) |
| CANNOT VERIFY | 7 | T-02, C-03, D-10, S-12, L-35, L-36, outside 6 |
| OK, now seen | 1 | L-32 |

Plus 4 new defects (N1–N4) and 2 observations.

**Judgement.** The terminal and layout work is in good shape for daily use:

- Key encoding now matches xterm.js across the whole table.
- Chords work on every layout tried.
- The divider follows the mouse.
- Scrollback, padding, the IME, dialogs and Reconnect behave.
- vi, less and htop, links, selection, copy and paste, image paste, resize, host switching and disconnect/reconnect all worked under
  real input.

What stands in the way:

1. **N1.** Anyone who opens the ☰ menu loses the keyboard until they click a pane, and Edit › Copy and Paste never work from it.
   This is a must-fix.
2. **N2.** Touchpad users and HiDPI users get much faster scrolling than in the Electron client.

N3, N4 and D-06 are minor.
