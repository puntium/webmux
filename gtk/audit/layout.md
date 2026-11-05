# Parity audit: sections 3 (sessions), 4 (layout), 5 (keyboard shortcuts)

Auditor: independent, read-only. Binary: `gtk/ghostty/zig-out/bin/webmux-gtk` as built
(no rebuild). Date: 2026-11-04.

## How this was checked

- **Runs.** Dev mode (`webmux-dev/headless start --host`, run `/tmp/wm-gyhFJ3`) for most of
  sections 3–4. The full app with the chrome against `webmux-dev/fake-ssh` (run
  `/tmp/wm-71MEnw`) for the app shortcuts, zoom, Restart Sessions, Reconnect, the connection
  form and L-41. Two hosts were connected: `alpha` = `Me@Alpha.Example` and `beta` =
  `me@beta` with instance `inst2`. I quit and relaunched the app inside the same run, with the
  same environment, to test persistence and startup reconciliation. Both runs were stopped
  afterwards, and `pgrep` shows nothing of mine left.
- **Keys.** Every chord was sent as a real keystroke through sway (`webmux-dev/realkeys`), with
  focus in a terminal, a file browser, a file rename field, the connection form, the settings
  dialog, the log window and the file browser's delete confirmation.
- **Pointer.** The headless seat has no pointer, and `wlrctl` adds and removes a device per
  command, which GTK never sees. I built a small persistent `zwlr_virtual_pointer_v1` client
  (`$SCRATCH/vp/vptr`, 60 lines of C, built from nixpkgs and outside the tree). With it I sent
  **real** pointer presses, drags, hover, wheel and touchpad scroll through sway and GDK. This
  covers L-20, L-27, L-29 and L-30, which WEBMUX.md calls untestable.
- **Geometry.** I compared it against the real Electron CSS. A script builds the `index.html`
  `#layout` / `.column` / `.divider` / `.pane` rules and `app.js` `columnWidths()` into a page.
  Headless Chrome lays out the same columns, weights and full flags at the same window size and
  cell width, and the boxes are compared with the native `wmctl workspace` dump (±0.5 px).
  Configurations tested: 33, covering widths 700–1920, 1–10 columns, stacks of 2–4 with dragged
  weights, full columns, and min/max column settings 40/60, 40/400, 60/100, 90/200, 120/120 and
  200/400. **All matched.**
- **Pixels.** Read from `wmctl screenshot` PNGs in both colour schemes (focus ring, borders,
  fade at 0/40/100, title bars, divider hover).
- **Resizes sent to the host.** Counted from the `io_thread: mailbox message=resize` lines in
  `app.log`, which come before Termio's coalescing, so they are an upper bound.

Abbreviations used in the repro steps: `wmctl` is `webmux-dev/wmctl -s $D/ctl.sock`, and `rk`
is `webmux-dev/realkeys $D`. A chord such as Ctrl+Shift+X is sent with
`rk -M ctrl -M shift -k x -m shift -m ctrl`.

## Section 3 — Session lifecycle

| ID | Verdict | Evidence / notes |
| --- | --- | --- |
| S-01 | RULED A-07 — matches | Quit the app, stopped the host server and relaunched. The strip shows `Cannot list the sessions on dev (FileNotFound). Retrying in 4 s…`, retries at 1 s, 2 s and 4 s, and logs `ERROR [dev] page: session list fetch failed api=… error=FileNotFound` each time. After the server came back: `page attached sessions=7`, and 9 panes were restored. |
| S-02 | PASS | I wrote a layout file with a stale id in a stack, a column holding only a stale id, a deleted session (`574d…`), a malformed column and duplicate/number ids, then relaunched. Stale terminal ids were dropped, both file browsers kept, the emptied column gone. The result is identical to app.js run on the same input. |
| S-03 | PASS | Two sessions created through the API while the app was down were appended at the right end, in creation order (`… \| 9e28 \| 31d6`). |
| S-04 | PASS / READ | The saved focus named a dead session, so focus fell back to the first column's active pane (`838f`), as app.js does. Seeding titles from the session list I judged by reading only (`workspace.zig:362-370`): the dev host's titles are empty. Looks right. |
| S-05 | PASS | An orphan `widgets["files-orphan123"]` entry added to the file was gone after relaunch. |
| S-06 | PASS | A fresh run opened one terminal by itself. A relaunch restored keyboard focus to the saved focused pane (`has_keyboard_focus_in` equals `focused`). |
| S-07 | PASS | `INFO [dev] page: page attached sessions=7 api=/tmp/wm-…/h.sock` (deviation 11 wording). |
| S-08 | PASS | `POST {"cols":80,"rows":24}` (`sessions.zig:126`). The new pane opens at once and resizes once on attach. |
| S-09 | **FAIL (minor)** | The ✕ button and close-pane both send the DELETE. But the pane's socket stays open through the 200 ms leave animation, so the host's `exit` frame arrives and the connection log gets `INFO … page: session exited session=<id> exitCode=0` for every terminal the user closes. app.js closes the socket first and logs only a debug `session socket closed (tab closed…)`. Repro: in dev mode create a terminal, press Ctrl+Shift+W, then `tail $D/home/.local/state/webmux-gtk/logs/webmux.log`. Reproduced 4 out of 4 times. |
| S-10 | PASS | `exit 3`: the exit frame was seen at 14 ms and the pane left the layout at 1209 ms (1.195 s later), with no DELETE (`closePane(id,false)`). |
| S-11 | PASS | There is no polling. A session created by another client did not appear, and did not appear after Ctrl+Shift+R either (see S-13). |
| S-12 | PASS (exercised) / READ (differs) | `headless host-restart` logs one `WARN … link down — a session socket dropped and is retrying` and then one `INFO … link up — …`. By reading (`workspace.zig:619-634`), the native client is "offline while **any** pane is down", whereas app.js clears the flag when **any** socket opens. With one pane that keeps failing and another that recovers, Electron reports up and native stays degraded. The native behaviour is arguably better, but it is not a recorded deviation. |
| S-13 | RULED A-15 — **FAIL (partial)** | A-15 says Reconnect covers Reload. Ctrl+Shift+R restarts the tunnel, but the workspace does not re-list sessions. A session created on the host by another client (`curl -X POST …/api/sessions` on the tunnel socket) did not appear after Reconnect. `Workspace.reload` runs only after Restart Sessions or after `retry → connected` (`chrome/hub.zig:515`), not after a user Reconnect (`connecting → connected`). |
| S-14 | PASS (deviation 12) | Connection page ⋯ › Restart Sessions on `beta`: `reloading workspace after session restart`, the 2 old panes closed, and one fresh session opened. |

## Section 4 — Layout

| ID | Verdict | Evidence / notes |
| --- | --- | --- |
| L-01 | PASS | Strip of columns with stacks of terminals and `files-…` panes. |
| L-02 | PASS | The layout file has `{panes,sizes,active,full}` per column (plus `version` and `widgets`, deviation 2). |
| L-03 | PASS | New-terminal-below in a column weighted [1.4359, 0.561, 1.003] gave the new pane weight 1.0 (the average). |
| L-04 | PASS / READ | Removing the active pane made the pane at the same index (else the last) active (observed). The case where the active pane is not the focused one I judged by reading. |
| L-05 | PASS | A lone survivor with weight 0.3968 fills its 988 px column. |
| L-06 | PASS | Ctrl+Shift+Enter opens a column right of the focused one and focuses it; the entry is animated. |
| L-07 | PASS / DEVIATION 6 | Inserted directly below the focused pane with the average weight, and becomes active. The deviation's race (focus moving during the POST) was not exercised. |
| L-08 | PASS | Ctrl+Shift+B; no server call. |
| L-09 | PASS | Ctrl+Shift+W closes terminals (DELETE) and file browsers. |
| L-10 | PASS | Next pane down, else the one above, else the right-hand column's active pane, else the left-hand one's — each case observed. |
| L-11 | PASS | A stacked pane splits out to the right as `full`; a lone pane toggles. A full column is exactly the strip's inner width (1908 at 1920, 1588 at 1600). |
| L-12 | PASS | Ctrl+Shift+H/L/←/→; no wrap at either end. |
| L-13 | PASS | Ctrl+Shift+J/K/↑/↓; no wrap, never crosses columns. |
| L-14 | PASS | Ctrl+Shift+Alt+H/L/←/→ swap whole columns; focus stays; no-op at the ends. |
| L-15 | PASS | 33 configurations matched Chrome's layout of the real CSS: `fit`, `min`, `max`, every column x/width, centring of fewer columns, overflow, columns capped at the viewport (700 px window). The cell width is Ghostty's whole-pixel cell (8 px at scale 1, 9 px after one zoom step) rather than Electron's measured 7.8 px. That is the right input, because 90 cells of 8 px must fit; it means Electron and native columns differ by about 2 % for the same settings. |
| L-16 | PASS / DEVIATION 20 | The settings change refit each changed terminal once (5 resizes for 5 non-full terminals) and re-revealed the focused column. A window resize refits at once with no debounce, as deviation 20 says. Consequence: 5 window sizes 30 ms apart gave 35 resize messages for 7 terminals (one per terminal per step). A zoom step updates the rule (max went from 1624 to 1824 at 9 px cells). |
| L-17 | PASS | Ctrl+Shift+Alt+J/K swap panes within the stack, weights included. |
| L-18 | PASS | Ctrl+Shift+[ / ]: expel to the left (inserted before) or right (after), merge at the bottom, no-op for a lone pane at the end. Two presses carry a pane into the next column. Focus stays. |
| L-19 | PASS | One focused pane at all times; focus updates `active`; layout saved. |
| L-20 | PASS | A **real pointer** press on an unfocused, partly visible terminal focused it, put keyboard input into it and scrolled the strip to reveal it. Title-bar click and ✕ were exercised through the frame handlers (`workspace-click`): the bar moves keyboard focus into the content; ✕ on an unfocused pane focuses it first, then closes it (same as app.js). |
| L-21 | PASS | Keyboard focus followed every focus command and stayed on the pane after every structural command, both from terminals and from file browsers. |
| L-22 | PASS | 5 focus moves gave 0 resizes and 0 renderer resizes. |
| L-23 | PASS | Pixels in dark: border `#7aa2f7` at x=6 (inside the box) plus a ring at x=5 (outside); unfocused border `(52,52,74)`; body `(31,31,43)`. Light: `#2e7de9`, `(196,200,216)`, `(244,245,249)`. |
| L-24 | PASS / DEVIATION 21 | Unfocused body pixel against expected `(1-0.375k)(1-0.7k)·c + 0.375k·c`: fade 40 gives (24,24,32) vs (23.6,23.6,32.8); fade 100 gives (18,18,24) vs (17.4,17.4,24.2); fade 0 gives (31,31,43), no effect; light at 40 gives (187,188,190) vs (186,187,190). The title bar is unfaded (38,38,50). The 0.12 s CSS `ease` transition I judged by reading (`frame.zig:183-236`). |
| L-25 | PASS | Focus to a fully visible column: no scroll. Off-screen: the minimum scroll (e.g. target 3828 = right edge + 6 − 1920). The in-flight target is used for the judgement (`workspace.zig:1103-1119`). |
| L-26 | PASS (note) | Sampled chase: remaining distance shrinks by 0.758 per 16 ms frame, so τ ≈ 58–60 ms; snaps within 0.5 px; settles in about 380 ms for a 957 px move. Note: the second frame of a chase steps as if dt ≈ 50 ms (733 → 318 px remaining in 4 ms), a visible jump at the start. GTK's frame clock time after idle is the likely cause (`workspace.zig:983`). Cosmetic. |
| L-27 | PASS (real pointer) | Discrete horizontal wheel: −2 notches panned −106 px (53 px per notch). Touchpad swipe of 10 × −30 px panned exactly −300. Vertical wheel scrolled the terminal 15 lines and left the strip alone. Over a file browser: swiping right at its right edge pans the strip; swiping left scrolls its columns first. One quirk is for the file-browser auditor: the inner columns move far more than Δx (a 5 × 30 px swipe moved them 449 px, or to 0), which looks like kinetic scrolling Electron does not have. |
| L-28 | PASS | Closing the last column while scrolled to the end: the scroll eased 4380 → 3982 over about 300 ms with the keeper held, and the keeper was cleared afterwards. |
| L-29 | PASS / READ | Real pointer hover over a divider turned it `(122,162,247)` (accent); `(52,52,74)` otherwise. 6 px tall with 1 px margins (pane 661 → divider 662–667 → pane 669). The row-resize cursor I judged by reading (`setCursorFromName("row-resize")`). |
| L-30 | **FAIL (major)** | A real drag does not follow the pointer. Dragging the divider 200 px up in 20 steps moved it about 99 px. Holding the pointer still mid-drag (repeated motion at the same y) makes the divider **oscillate** between two positions (471 ↔ 518 px while the pointer sat at 549). Cause: the `GtkGestureDrag` is attached to the divider widget itself, which the workspace re-allocates on every update, so GTK reports each offset relative to the moved widget (`workspace.zig:1180-1190`, `dragUpdate` uses `drag_start_y + off_y`). The model's arithmetic is right: the control path `workspace-divider` matches app.js exactly, including the `min(110/pair, 0.45)` clamp (1.66463 / 0.33537 and 0.33234 observed). So only real users hit this, and the test knob hides it. Repro: needs a pointer. With the virtual-pointer client: press at the divider's middle, then send absolute motion 10 px at a time. On a desktop it is visible by dragging any stack divider. |
| L-31 | PASS | Every structural command animated; measured animation end at 188–200 ms. Final boxes were allocated at once (`box` final, `visual` interpolated). Exactly one terminal resize per affected pane per change (toggle-full: 1; new-below: 2, the shrunk pane and the new one). |
| L-32 | PASS / READ | Growing panes are revealed by a clip (seen mid-flight). The ghost under a shrinking pane, with fade overlay and focus ring, I judged by reading (`workspace.zig:1436-1448`, `style.css` `.strip-ghost`). Looks right. |
| L-33 | PASS | Mid-flight at time_scale 15: the new column grows from zero width at the left neighbour's edge (`visual.w` 401 of 525) while fading in, and the columns to the right slide. |
| L-34 | PASS | A stacked pane closing at slow speed is clipped from the top towards the meet line at the column bottom while the survivor grows (dump `leaving`, screenshot). The lone-column wipe from the right I judged by reading (`anim.zig:156-177`). |
| L-35 | READ — looks right | Draw order: ghosts, dividers, leaving panes, panes, focused pane last (`workspace.zig:1434-1470`). |
| L-36 | READ — looks right | Column matching by shared panes in `layout/change.zig`, covered by the model's differential trace. Not checked frame by frame. |
| L-37 | PASS | At time_scale 10, move-column-left, then move-column-right 0.8 s later: every pane's visual box was identical immediately before and after the second command, with no snap. |
| L-38 | PASS | With `gtk-enable-animations=false` (GTK `settings.ini` in the run's config dir), `reduced_motion: true`; move, new, close and focus finished with 0 ms of animation and no chase. File-browser animations are for the files audit. |
| L-39 | PASS | Animations ended within 200 ms; a 250 ms settle timeout exists (`settleTimeout`). |
| L-40 | PASS / DEVIATION 2 | Saved to `layout/<slug>.json`, debounced 250 ms (`save_delay_ms`) and flushed on dispose. Quit and relaunch restored ids, weights (0.396761), `active`, `full` and focus exactly. The debounce is not recorded as a deviation: a crash within 250 ms of a change loses it. Minor. |
| L-41 | PASS | Layout file names were `me-alpha-example-1563e4b1.json` and `me-beta-53985c6c.json`, the same as the slugs computed with main.js's `appOrigin` in node. Renaming the profile `alpha` to `alpha-renamed`, then disconnecting and reconnecting, restored its 3-pane layout from the same file. |
| L-42 | PASS / DEVIATION 5 | Malformed column skipped, null/number/duplicate ids dropped, a weight of `"abc"` became 1, `active:"zzz"` fell back to the first pane, `full:"true"` became false. |

## Section 5 — Keyboard shortcuts

All of these were sent as real keystrokes through the compositor.

| ID | Verdict | Evidence / notes |
| --- | --- | --- |
| K-01 | PASS | Ctrl+Shift+Enter → new column. |
| K-02 | PASS | Ctrl+Shift+Alt+Enter → new terminal below. |
| K-03 | PASS | Ctrl+Shift+B → file browser. |
| K-04 | PASS | Ctrl+Shift+W, on a terminal and on a file browser. |
| K-05 | PASS | Ctrl+Shift+F on a stacked pane and on a lone pane. |
| K-06 | PASS | Ctrl+Shift+← and Ctrl+Shift+H. |
| K-07 | PASS | Ctrl+Shift+→ and Ctrl+Shift+L, including the no-op at the end. |
| K-08 | PASS | Ctrl+Shift+↑ and Ctrl+Shift+K. |
| K-09 | PASS | Ctrl+Shift+↓ and Ctrl+Shift+J. |
| K-10 | PASS | Ctrl+Shift+[ (expel, then merge). |
| K-11 | PASS | Ctrl+Shift+] (expel, merge, no-op at the end). |
| K-12 | PASS | Ctrl+Shift+Alt+← / H. |
| K-13 | PASS | Ctrl+Shift+Alt+→ / L. |
| K-14 | PASS | Ctrl+Shift+Alt+↑ / K. |
| K-15 | PASS | Ctrl+Shift+Alt+↓ / J. |
| K-16 | **FAIL** | Chords are matched by the **level-0 keyval of the active layout group** (`key_event.zig:110-127`, `shortcuts.zig:13-16`), not by physical key as app.js does with `ev.code`. Consequences: (1) With a non-Latin group active (Russian, Ukrainian, Greek, Hebrew…), Ctrl+Shift+H/J/K/L/W/F/B do nothing. Worse, the key falls through to the terminal, which writes a CSI-u sequence into the shell: the pane received `ESC[1088;6u` for Ctrl+Shift+р and the shell printed `sh: 6u88: command not found`. (2) On layouts where `[`/`]` are not level 0 of those keys (German QWERTZ: ü/+; French AZERTY: dead ^/$), Ctrl+Shift+[ / ] never match. (3) The same lookup serves the app shortcuts, so on AZERTY the level-0 keyvals of the digit row are `& é " ' ( - è _ ç`, and Ctrl+1…9 (K-24) cannot work. Repro (simulates a non-Latin group, since wtype uploads its own keymap): with a terminal focused, `rk -M ctrl -M shift -k Cyrillic_er -m shift -m ctrl` → no `pane.focus-left` in `app.log`, and the shell prints garbage. `rk -M ctrl -M shift -k h …` → focus-left. |
| K-17 | PASS (note) | Ctrl+Shift+Alt+W/[/]/F/B are not matched or swallowed by the shortcut layer; they reach the terminal. Note for T-13: the terminal then sends bytes Electron/xterm would not. `cat -v` showed `^[[91;8u` for Ctrl+Shift+Alt+[, `^[^]`, `^[^F`, `^[^B`, and `1` for Ctrl+Shift+1. |
| K-18 | **FAIL** | Passes in the file rename field (all six chords logged `swallowed in a text field`, field text unchanged), the connection form (`abc` typed around Ctrl+Shift+H and Ctrl+Shift+Enter stayed `abc`), the settings dialog (spin value unchanged, no pane commands) and the log window. **Fails with the file browser's delete confirmation open** (the pane-scoped modal, which app.js counts as a `.modal-overlay`): Ctrl+Shift+L moved focus out of the browser to the next pane, and Ctrl+Shift+Enter opened a new terminal, leaving the confirmation open in a pane that is now off-screen and unfocused. `inTextField` only knows `GtkText`, `GtkTextView` and `AdwDialog` (`shortcuts.zig:167-174`). Repro (dev mode): open a browser (Ctrl+Shift+B), `rk -k G`, `rk -k d` (confirmation shows), then Ctrl+Shift+L or Ctrl+Shift+Enter. |
| K-19 | PASS | `cat -v` showed nothing for Ctrl+Shift+K, Ctrl+Shift+Alt+K or Ctrl+Shift+[. |
| K-20 | PASS | Ctrl+Shift+O → connection page (`front: null`), from a host and from the form. |
| K-21 | PASS | Ctrl+Shift+R → `reconnect requested host=me@beta …`, back to connected. |
| K-22 | PASS | Ctrl+Shift+G opens the log window; from the log window, Ctrl+, opens settings. |
| K-23 | PASS (note) | Ctrl+, opens settings over the host. Note: it also opens settings on the connection page, where app.js `chromeCmd('settings')` does nothing. Unrecorded, harmless. |
| K-24 | PASS | Ctrl+1 → alpha, Ctrl+2 → beta, Ctrl+3 → no-op with 2 hosts. |
| K-25 | PASS | Ctrl+PageUp cycles and wraps; from the connection page it lands on the last host. |
| K-26 | PASS | Ctrl+PageDown cycles and wraps; from the connection page it lands on the first host. |
| K-20…K-26 + DEVIATION 31 | **FAIL against deviation 31** | Deviation 31 says app shortcuts still run while a dialog is open ("for example Ctrl+Shift+O over the settings dialog"). With the settings dialog open, real Ctrl+Shift+O, Ctrl+Shift+G and Ctrl+1 do nothing: no `webmux_shortcuts` line, `front` unchanged, dialog still open. Real keys never reach the window's capture controller while an `AdwDialog` is presented. The integration smoke uses synthesized `wmctl key`, which calls `Window.dispatchKey` directly and so cannot see this. Repro (chrome run): `rk -M ctrl -k comma -m ctrl`, then `rk -M ctrl -M shift -k o -m shift -m ctrl` → `wmctl conns --get front` is unchanged and `settings-dump` shows `open: true`. The pane chords are blocked there too, which is K-18's required outcome. |
| K-27 | PASS | The shortcut table has no collision between app shortcuts and pane chords (`shortcuts.zig:34-84`). |
| K-28 | PASS | Ctrl+3, Ctrl+9 (no-op host keys) and the chords left `cat -v` empty. |
| K-29 | PASS | Ctrl+Shift+V pasted the text, Ctrl+Alt+V sent `^V`, Ctrl+V pasted the text. Note for the clipboard auditor: with bash's bracketed paste on, the screen showed `^[[200~PASTED2~PASTED2` after Ctrl+V and then Ctrl+Shift+V. |
| K-30 | PASS | In a focused browser, Ctrl+J, Alt+J and Super+J did not move the cursor; `j` did. |
| K-31 | PASS / DEVIATION 24 / RULED A-15 | Ctrl+= moved the cell from 8 to 9 px with one resize per visible terminal, and the width rule followed (max 1624 → 1824). Ctrl+- and Ctrl+0 work. F11 (`^[[23~`), Ctrl+R (`^R`) and Ctrl+Q reach the terminal; the window was not made full-screen and did not quit. In dev mode zoom does nothing (`menu.zig:409` needs `hub.active`); that only matters for testing. |
| K-32 | PASS / READ | Pill tooltip `beta — connected (Ctrl+2)` observed. Header button tooltips (`header.zig:61-79`), the Log button (`page.zig:121`) and the hint paragraph (`page.zig:31-34`, seen on screen) match the Linux strings word for word. |

## Defects outside the checklist

1. **Chord keys on non-Latin layouts type escape garbage into the shell.** See K-16. A Ctrl+Shift+letter that does not match (because the layout group's keyval is not Latin) reaches Ghostty's encoder, which sends `ESC[<codepoint>;6u` to the pty. A Russian-layout user pressing what they think is focus-left gets `6u88: command not found`. This belongs with T-13 (terminal key encoding) as well as K-16.
2. **The ✕ / close-pane path logs a false "session exited".** See S-09. Every user-closed terminal adds `INFO … page: session exited … exitCode=0` to the connection log that users read.
3. **Ctrl+Shift+Alt+[ ] F B and Ctrl+Shift+1 send bytes to the pty.** See K-17. xterm sends nothing for Ctrl+Shift combinations (T-13). This is for the terminal auditor.
4. **Settings dialog GTK warnings, repeated in `app.log` each time it opens.** `Gtk: Widget reports min height of 457 for width of 1918, but overall min height of 550`, the same for 70/74/83/509/511, and `Adwaita: GtkBox … exceeds AdwDialog height: requested 550 px, 509 px available` at a 1000 px window. For the panels auditor.
5. **Screenshots with the settings dialog open show the whole host view black behind it**, with no panes or title bars. app.js dims the page with `rgba(0,0,0,.55)`. I could not tell whether the window really draws this or the `screenshot` command only re-renders part of it. Worth a look by the panels/modals auditor.
6. **The first frames of a strip chase jump too far** (L-26 note). The second step acts as if about 50 ms elapsed. Cosmetic.
7. **Window resize sends a resize to the host per terminal per frame** (deviation 20). Recorded, but the cost is real: 7 terminals × every configure. Electron's 100 ms debounce sent one per terminal.
8. **Layout save is debounced 250 ms** and not listed as a deviation (L-40).
9. `warning(stream): invalid C0 character, ignoring: 0x18` appears at attach in dev mode (6 times over the run); it comes from the snapshot. For the terminal auditor.

## Not audited / limits

- **Real pointer coverage.** A real pointer exists only through my virtual-pointer client. The title bar and ✕ were driven through the frame handlers rather than real clicks. The row-resize cursor shape cannot be observed.
- **Keyboard layouts.** wtype uploads its own keymap, so K-16 is shown by sending the keysyms a Russian layout produces. The AZERTY and QWERTZ consequences are judged by reading the code: the lookup is level 0 of the active group.
- **Reduced motion.** Tested through GTK's `gtk-enable-animations` in a `settings.ini`, not through the desktop's reduce-motion setting (no portal or GSettings in the headless session). The code also reads `gtk-interface-reduced-motion` on GTK 4.20 and later.
- **L-36 divider identity across merges, L-35 overlap order:** judged by reading, not checked frame by frame.
- **Deviation 6 race:** not exercised.

## Summary

Counts (one verdict per row above; a row carrying a ruling or deviation is counted under its
main verdict):

| Verdict | Count |
| --- | --- |
| PASS (incl. PASS with a deviation or ruling that matches) | 79 (S 11, L 38, K 30) |
| FAIL | 6 |
| READ only | 4 (S-12 aggregation, L-32 ghost, L-35, L-36) |
| MISSING | 0 |
| N/A | 0 |

That is 89 rows: S-01…S-14, L-01…L-42, K-01…K-32, plus the separate deviation-31 row. The 6
failures are S-09, S-13, L-30, K-16, K-18 and deviation 31. Several PASS rows also lean on
reading for one sub-point (S-04 titles, L-04, L-29 cursor, L-34 wipe, K-32 tooltips).

Failures ordered by how much a user would care:

1. **L-30: divider drag is broken with a real mouse.** The divider moves at about half the pointer's speed and oscillates when the pointer pauses. Every user who resizes a stack sees it, and the smoke cannot see it because `workspace-divider` bypasses `GtkGestureDrag`.
2. **K-16: chords depend on the keyboard layout.** With a non-Latin layout group, all letter chords fail and type CSI-u garbage into the shell. On AZERTY/QWERTZ, Ctrl+Shift+[ / ] and (AZERTY) Ctrl+1…9 cannot work.
3. **K-18: pane chords run under the file browser's delete confirmation.** Focus leaves it, or a new terminal opens, leaving an armed "Delete folder …?" prompt in an off-screen pane.
4. **Deviation 31 not met: app shortcuts are dead while any `AdwDialog` is open.** Settings, link chooser: Ctrl+Shift+O, Ctrl+Shift+G and Ctrl+1…9 do nothing until the dialog is closed.
5. **S-13 (ruling A-15): Reconnect does not re-list sessions.** Sessions opened by another client never appear until a tunnel outage or Restart Sessions.
6. **S-09: closing a terminal writes a false `session exited … exitCode=0` line** to the connection log.

Wider pattern: the control-socket test knobs (`workspace-divider`, `wmctl key`) enter below the
GTK event layer. Every one of failures 1, 2 and 4 lives exactly in the layer those knobs skip
(gesture coordinates, keymap lookup, dialog event routing), so the green smokes say nothing
about them. Testing through the compositor (`realkeys`, a virtual pointer) found them in
minutes.
