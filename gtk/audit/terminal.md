# Audit: terminal pane, clipboard/paste/links, host shims (PARITY §1, §2, §14)

Auditor: independent (terminal slice). Date: 2026-11-04. Binary: `gtk/ghostty/zig-out/bin/webmux-gtk` as built (a Debug build:
the app logs "This is a debug build. Performance will be very poor"). No source was edited, nothing was rebuilt.

## How this was exercised

Four headless runs, all through `webmux-dev/headless`, all stopped at the end (checked with `pgrep` by run dir, pty-host name and
`XDG_RUNTIME_DIR`; nothing left):

| Run | Start command (from `gtk/ghostty`) | Used for |
| --- | --- | --- |
| `/tmp/wm-ynTgtD` | `webmux-dev/headless start --host` | most of §1 and §2 in the merged app (dev mode, the real workspace) |
| `/tmp/wm-20vGKt` | `webmux-dev/headless start --host -- GTK_IM_MODULE=gtk-im-context-simple` | IME / dead keys (T-14) |
| `/tmp/wm-Uv8ZQP` | `webmux-dev/headless start --host -- WEBMUX_GTK_DEV_SESSION=no-such-session-xyz` | `error` frame (T-39) |
| `/tmp/wm-ftGvhy` | `webmux-dev/headless start -- WEBMUX_GTK_SSH=$PWD/webmux-dev/fake-ssh WEBMUX_GTK_SLEEP_BUS=session`, then connection page → `devbox`/`me@devbox` → submit | the full app: real deploy of the payload, shims on the fake host, real window-focus clipboard sync, Edit menu, key encodings |

Techniques:

- Key bytes: a raw-mode capture script in the session's HOME (`k.py`: `tty.setraw`, read until `QQ`, print `repr`), driven
  with **real keystrokes** (`webmux-dev/realkeys`), so input goes compositor → GDK → window shortcuts → pane → IM → encoder.
- Mouse: control-socket `mouse` (no pointer device on the headless seat). Note `button=` needs a name (`right`, `middle`);
  `button:=3` silently means left.
- Clipboard: the real Wayland clipboard in the nested session (`in-session wl-copy` / `wl-paste`), with one real key first to
  give the app a fresh input serial (WEBMUX.md › Known gaps). `wl-copy -o` serves one paste only; use plain `wl-copy`.
- Pixels: screenshots decoded with a small PNG reader and sampled; the images were also looked at, both schemes.
- Wire: a stdlib-Python WebSocket client on the host's unix socket to read raw snapshots and to act as a second client.
- Host outages: killing only this run's `webmux-host serve` (last `host=` pid in `$D/pids`) and `headless host-restart`,
  with `app.log` lines timestamped by a `tail -F` loop.
- Before every `xdg-open` test: `command -v xdg-open` inside the session resolved into a `shims` directory and `DISPLAY` was
  `no-such-display.invalid:0` (dev host and fake host both). See D-11 for a case where that stops being true.

Line numbers below are in `gtk/ghostty/src/apprt/webmux/` unless a path says otherwise.

## Verdicts

### 1. Terminal pane

| ID | Verdict | Evidence |
| --- | --- | --- |
| T-01 | PASS | Built-in JetBrains Mono, four faces (log: four `variation axes font=JetBrains Mono`), 9.75 pt = 13 px. Regular, bold, italic, bold-italic, Nerd glyphs (U+E0B0, U+F015, U+F113, U+F02A2), box drawing, CJK and emoji render (`font.png`). Cell is 8×17 px at scale 1. Observation, not verified: xterm's WebGL renderer floors the cell width (`addon-webgl/src/WebglRenderer.ts:541`, `Math.floor(7.8)` = 7 px), so the Electron client probably fits about 12% more columns in the same width. I could not run the Electron client to confirm. |
| T-02 | READ (looks right) | No load race: the font is embedded and the grid is measured from it (`config.zig:14-17`). |
| T-03 | **FAIL** (low) | Expected 5000 lines of scrollback (`electron/ui/app.js:763`). Kept: 4759 (`seq 1 7000` → scrollbar total 4809 with 50 rows; scrolled to the top it shows `2193`). With `seq 1 30000` the total is 4793; with `clear; seq 1 5100` it is 4827. So 200–250 lines **fewer** than 5000. WEBMUX.md › Known gaps says "slightly more than 5000 survive"; that is wrong. Repro: `D=$(webmux-dev/headless start --host)`; `wmctl -s $D/ctl.sock text text='clear; seq 1 7000\n'`; `wmctl … dump text:=false --get panes.0.scrollbar` → total 4809. |
| T-04 | PASS | Focused: block cursor alternating `#ffffff` / background in screenshots 270 ms apart. `wmctl focus value:=false`: hollow 1 px outline, identical in 4 shots over 1.1 s, so it does not blink. |
| T-05 | PASS | Sampled: background `#1f1f2b`; ANSI 0–15 exactly as listed; 256-colour 196/244/33 = `#ff0000 #808080 #0087ff`; foreground and cursor `#ffffff`; the character under the cursor is drawn dark. Selection `#62626b` = the 0.3 white overlay blended (deviation 16, matches). |
| T-06 | PASS | Light: background `#f4f5f9`, all 16 ANSI colours as listed, selection `#c2d7f5` (blended, deviation 16, matches). |
| T-07 | PASS | `wmctl settings-set theme=light` (the panel's path): both panes repaint at once (checked the other pane too); a selection (`110`) and scrollback (total 122, offset 72) are kept. |
| T-08 | PASS | `\e[1;3Nm` draws the bright variant (B0…B7 in `pal-dark.png`); `printf 'a\tb\tc'` puts b at col 8, c at col 16. Minimum contrast: Ghostty default 1, not overridden. |
| T-09 | **FAIL** (low) | Expected 4 px padding (`electron/ui/index.html:339-340`). Measured **5 px** on every side: the pane body starts at x=7 and the first glyph column at x=12; the title bar ends at y=31 and the first row starts at y=37. Cause: `config.zig:62-63` sets `window-padding-x/y = 4`, which Ghostty reads as **points** and converts with `floor(4 × 96 / 72)` = 5 (`src/Surface.zig:447-462`); the font size was converted (9.75 pt), the padding was not. It should be `3` (→ 4 px). Knock-on: WEBMUX.md's width rule ("`C * cellWidthPx / scale + 8 + 10`") is 2 px short, so the column-width rule (L-15) can give one column fewer than intended. Repro: any screenshot; sample row 45 from x=0: frame to x=6, background from x=7, first swatch pixel at x=12. |
| T-10 | PASS | 10 px column right of the terminal; thumb 4 px wide (3 px inset), rounded, `#c4c7d1` in light = `rgba(52,59,88,0.25)` on `#f4f5f9`; length proportional (50/122 of the column). Hidden when there is no scrollback. Hover colours: READ (`terminal/terminal.css`), matches `index.html:102-111`. |
| T-11 | PASS | Ghostty's OpenGL renderer; every frame arrives as a DMABUF (`dump` → frames.dmabuf counting, 0 import failures), `renderer_health` healthy. Not measured for smoothness: the binary is a Debug build. |
| T-12 | **FAIL** (high) | Plain keys, arrows, F-keys, application cursor mode (`\eOA`, `\eOD`, `\eOH`), Alt as ESC prefix (`\ex`, `\e\x7f`), the kitty protocol when enabled (`\e[27u`, `\e[99;5u`, `\e[97;6u`) and drop-while-down (typed `echo LOST1` while the host was down; it never arrived) are all right. But several common keys are **not** xterm's encoding (`electron/node_modules/@xterm/xterm/src/common/input/Keyboard.ts:84-125`). Real keys, captured bytes: Shift+Enter `\e[27;2;13~` (xterm `\r`); Ctrl+Enter `\e[27;5;13~` (xterm `\r`); Ctrl+Tab `\e[27;5;9~` (xterm `\t`); Ctrl+Shift+Tab `\e[27;6;9~` (xterm `\e[Z`); Ctrl+Esc `\e[27;5;27~` (xterm `\e`); Alt+Left/Right `\e[1;3D`/`\e[1;3C` (xterm on Linux sends `\e[1;5D`/`\e[1;5C`, Keyboard.ts:118-124). User-visible: in `bash --norc`, typing `echo hi` then Shift+Enter leaves `echo hi;2;13~` on the line instead of running it. These are Ghostty's modifyOtherKeys-style defaults; the pane overrides only Ctrl+[ / I / M (`pane.zig:557-568`). Repro: start the run, `wmctl text text='bash --norc --noprofile\n'`, `realkeys $D 'echo hi'`, `realkeys $D -M shift -k Return -m shift`, then `dump`. Bytes: copy `k.py` (raw read until `QQ`) into the session HOME and use `realkeys $D -M ctrl -k Return -m ctrl` and so on. |
| T-13 | PASS | Ctrl+A `\x01`, Ctrl+Space `\x00`, Ctrl+[ `\x1b`, Ctrl+\ `\x1c`, Ctrl+] `\x1d`, Ctrl+/ `\x1f`, Ctrl+I `\t`, Ctrl+M `\r`; Ctrl+Shift+A sends nothing (with kitty on: `\e[97;6u`). Ctrl+2…8 send nothing because they are host shortcuts (`shortcuts.zig:43-50`, `last_shortcut` = `app.host-N`). That matches the Electron client, where K-24/K-28 take precedence (`electron/main.js:289-298`); the checklist line contradicts K-28, so the lead may want to fix T-13's wording. |
| T-14 | **FAIL** (medium, partly READ) | Dead keys compose with GTK's simple IM (dead_acute + e → `é`, dead_diaeresis + u → `ü`), and the pre-edit is drawn underlined at the cursor. But the IM's own Ctrl+Shift+U Unicode entry never reaches the input method: `paneKey` runs before `filterKeypress` and swallows every Ctrl+Shift+letter (`pane.zig:429` then `pane.zig:569-573`). Exercised with the simple IM: Ctrl+Shift+U 2 6 0 3 Space gives `2 6 0 3 ` instead of ☃. IBus and fcitx use the same Ctrl+Shift+U hotkey through the same GTK IM path, so they will be blocked too (not testable here: no IM server). In Chromium the IM sees the key first [inferred]. |
| T-15 | PASS | Real keys Ctrl+Shift+L, Ctrl+Shift+Left, Ctrl+, , Ctrl+PageUp, Ctrl+Shift+Alt+H, Ctrl+Shift+[ into a raw reader: nothing arrived. Ctrl+, opened the settings panel. |
| T-16 | PASS | Real Ctrl+Alt+V with text on the clipboard → `\x16`. |
| T-17 | PASS | Scrolled 30 lines up, real key `a`: back at the bottom. Ctrl+Shift+V paste also snaps to the bottom. |
| T-18 | PASS (minor differences) | Drag selects a range; double-click gives `word`, `one`, `two`, `three`, `b`, `x:y/z.w` (separators as listed); triple-click selects the line; Shift+click extends an existing selection. Two edge cases differ from xterm (`SelectionService.ts:832-870`): double-clicking a space selects the run of separator characters around it (`" \``) where xterm selects only the spaces; and a plain click followed by Shift+click selects nothing, where xterm selects from the click point. |
| T-19 | PASS | With `\e[?1000h\e[?1006h`: left click → `\e[<0;4;1M`/`m`, right → `\e[<2;…`, middle → `\e[<1;…`, wheel → `\e[<64;…` (3 reports per notch, deviation 18). Shift+drag made a local selection (`hell`) and sent nothing. |
| T-20 | PASS | Typed `echo abcdef` (cursor col 13), Alt+click col 5 → cursor col 5; a typed `X` landed there (`echXo abcdef`). |
| T-21 | PASS | Drag selection → `wl-paste -p` returns it; middle-click pasted PRIMARY into the shell. |
| T-22 | PASS | A selection leaves CLIPBOARD untouched. Copy is Ctrl+Shift+C (ruling A-03; real key → `wl-paste` = selection) and Edit › Copy works (see D-04 for its wrong toast). |
| T-23 | PASS | Right-click without mouse tracking: no selection, no menu (no menu code exists; `right-click-action = ignore`, `config.zig:83`). |
| T-24 | PASS (see READ note) | Hover underlines the plain URL (the 28-cell `https://example.com/path?x=1`, measured in the screenshot). Click → URL service records `https://example.com/path?x=1`; `(http://foo.bar/baz).` yields `http://foo.bar/baz`; `mailto:` text is inert. Shift+click → `wl-paste` = URL, toast `link copied`. A drag that starts on a URL selects text. READ: a click in a pane that does not have focus only focuses it (`pane.zig:937-941`), so a link (or a selection drag) in an unfocused pane needs a second click; in the Electron client the first click does it. Not testable (synthesized mouse skips this path). |
| T-25 | DEVIATION 17 + 26 (matches) | OSC 8 http link: click opens, Shift+click copies (toast `link copied`); `mailto:` and `file:` OSC 8 links: click does nothing; no confirmation. Hover gives the pointer cursor and no underline, as deviation 17 says. |
| T-26 | PASS | There is no web view; URLs go only to the URL service (recorded by the url-sink in tests). |
| T-27 | DEVIATION 18 (matches) | Wheel: 3 lines per notch; Alt+wheel: 15 (5×); no animation. Missing xterm behaviour next to it: D-01 (Shift+PageUp/PageDown). |
| T-28 | PASS | While a loop prints a line every 100 ms, the view follows at the bottom. |
| T-29 | PASS | One notch up while output streams: the view stays put (distance from the bottom grows 6 → 16 → 26). |
| T-30 | PASS (wheel) / READ (scrollbar, looks wrong) | 50 rows → band 8. Up 12, down 3 → distance 9 (no snap); down 3 more → 0 (snapped). While streaming, distance 24 → 22: no snap, correct. READ: dragging the scrollbar down into the band does not snap: `scrollbarValueChanged` only does `scroll_to_row` (`pane.zig:1329-1335`), while Electron's `onScroll` handles any downward viewport move (`app.js:834-841`). |
| T-31 | DEVIATION 1 (matches) | One WebSocket per pane on the tunnel's unix socket (`/ws?session=<id>`), opened at first allocation. |
| T-32 | PASS | Server killed, window resized 1400×900 → 900×600 while down, server restarted: after reconnect `stty size` = `32 108`, the new grid. Link up is reported (workspace log `link up`). |
| T-33 | PASS | Restart with scrollback and an OSC title: the visible text is identical, title `MYTITLE` restored, `snapshots` counts up. Replays at the remote size (deviation 13). |
| T-34 | PASS | Covered by T-28/T-29. |
| T-35 | PASS | Yellow (`#c4a000`) `[disconnected — reconnecting…]` printed once. Timestamped retries 1.00 s, 2.00 s, 4.00 s, 8.00 s, 10.00 s, 10.00 s after the drop; reconnect after the server came back; delay reset (the next outage starts again at 1 s). No line printed for a first connect that fails (`termio/webmux/Client.zig:336-339`). |
| T-36 | PASS | One loop owns the socket (`Client.zig:292-346`); after several reconnects `ss -x` showed one connection on the host socket. |
| T-37 | PASS | `exit 3` → red (`#cc0000`) `[session exited: 3]`; the pane disappears between 1.33 s and 1.52 s (1200 ms timer plus the close animation); `closePane(id, false)`, no DELETE (`workspace/workspace.zig:577`); no reconnect. |
| T-38 | PASS | Window resize → `stty size` follows (`38 120` at 1001×703); resize on open (T-32). The 100 ms debounce is not kept (deviation 20). Panes that are not on screen get no allocation, so they are not fitted (READ). |
| T-39 | PASS | Unknown session: log `session gone on the host — closing its tab (session no-such-session-xyz: no such session)`, pane closed, no reconnect attempts afterwards. |
| T-40 | DEVIATION 19 (matches) | `title` frames and OSC 0/2 set the title (`MYTITLE`); `session-title` is ignored by design. |
| T-41 | PASS | Empty title (`printf '\e]0;\a'`) → the label goes back to the session id. |
| T-42 | PASS | A second client (raw WebSocket) sent resize 80×24: `stty size` in the session = `24 80`; the native pane is not disturbed and does not fight it. |

### 2. Clipboard, paste and links

| ID | Verdict | Evidence |
| --- | --- | --- |
| C-01 | **FAIL** (low) | Targets `c`, `p` and empty all land on CLIPBOARD (`héllo wörld ✓`, `primary-target`, `empty-target`); PRIMARY untouched; toast `clipboard set from terminal`; malformed base64 ignored with no toast. Wrong: a payload that is not valid UTF-8 is put on the clipboard raw, advertised as `text/plain;charset=utf-8` (`printf '\e]52;c;/w==\a'` → `wl-paste` gives the single byte `0xFF`). Electron decodes with `TextDecoder` (`app.js:794`), which gives U+FFFD. Repro: real key first, then `wmctl text text='printf "\\033]52;c;/w==\\007"\n'`, `in-session $D wl-paste -n \| od -c`. Also through tmux: `tmux set -s set-clipboard on; tmux set-buffer -w X` reached the client clipboard (H-01). |
| C-02 | PASS | `\e]52;c;?\a` and `\e]52;s;?\a` followed by DA1/DA2 queries: only the DA replies came back as input; the log says `'clipboard-read' is set to deny`. |
| C-03 | READ (looks right) | `Clipboard.set` shows `could not write to the clipboard` when `setContent` fails (`pane.zig:1681-1704`). Could not provoke a failure. |
| C-04 | PASS | Real Ctrl+V: text → pasted, bracketed when enabled (`\e[200~pasted text\e[201~`); empty clipboard (`wl-copy --clear`) → `\x16`; empty string → `\x16`; PNG → image flow (C-07). |
| C-05 | PASS | Real Ctrl+Shift+V: text pasted; PNG → `uploading pasted image…` then `pasted image → …`; empty → nothing. |
| C-06 | **FAIL** (medium) | Edit › Paste (header menu, N-16) with an image on the clipboard does nothing: no toast, nothing sent. Expected: the image-paste flow (`app.js:881-893`). Cause: `actPaste` runs Ghostty's `paste_from_clipboard` (`chrome/menu.zig:395-397`), whose request returns `.unavailable` when there is no text (`pane.zig:1719-1724`); it never reaches `terminal/clipboard.zig` `paste`. Text through Edit › Paste works. Repro (full app run): `in-session $D sh -c "wl-copy -t image/png < some.png"`, `realkeys $D -k Shift_L`, `wmctl menu action=activate label=Paste` → no `status:` line in app.log, nothing in the session. |
| C-07 | PASS | PNG via Ctrl+V: toast `uploading pasted image…`, the host stored a byte-identical file and typed its path. With the host down, Ctrl+V with an image does nothing (no toast). Encode error toast: READ (`terminal/clipboard.zig:212-224`). |
| C-08 | PASS (`path`) / READ (`claude`) | `pasted image → /tmp/…/paste-….png` shown. The `claude` string is in `terminal/remote.zig:258-260`; needs Claude Code in the foreground to exercise. |
| C-09 | PASS | Full app: switched sway to an empty workspace (window inactive), `wl-copy` a PNG, switched back → toast `clipboard image synced to sessions`, the host's slot is byte-identical. Same image again → no second toast (dedupe); a text clipboard is not synced; repeat within 1 s throttled (`wmctl clipboard-sync`). |
| C-10 | RULED A-11 (matches) | A hand-made `image/tiff` on the clipboard → converted, the host got `image/png` (102-byte PNG, `clipboard.mime` = `image/png`). |
| C-11 | PASS | `xdg-open https://…` in a session → chooser (Cancel / Copy / Open in browser); Open → URL service. `WEBMUX_SESSION= xdg-open …` with two panes attached (broadcast to both sockets) → exactly one chooser. Two different URLs → two stacked choosers. |

### 14. Host shims

| ID | Verdict | Evidence |
| --- | --- | --- |
| H-01 | PASS | In a fake-host session: `TERM=xterm-256color`, `TMUX` and `TERM_PROGRAM` empty, `BROWSER` and `PATH` point at the deployed payload's `shims/`, `WEBMUX_SESSION` and `WEBMUX_CLIPBOARD_DIR` set (the test harness overrides `DISPLAY` to `no-such-display.invalid:0`). The client acts as xterm-256color for OSC 52 and tmux's `Ms` (C-01). |
| H-02 | PASS | `xdg-open https://…` and `$BROWSER http://…` → rc 0 and a chooser; `xdg-open mailto:…` → rc 4, nothing shown. |
| H-03 | PASS | `xclip -selection clipboard -t TARGETS -o` → `image/png`; `-t image/png -o \| wc -c` = 33119, the synced image's size. `echo x \| xclip -selection clipboard` → rc 0 and the client clipboard is unchanged. |

## Defects outside the checklist

- **D-01** (high): Shift+PageUp / Shift+PageDown send `\e[5;2~` / `\e[6;2~` to the program instead of scrolling the view by a page (rows − 1 lines). xterm.js scrolls (`Keyboard.ts:225-240`, `browser/Terminal.ts:1027-1030`). There is no other keyboard way to scroll back. Repro: `seq 1 300`, then `cat -v`, then real `realkeys $D -M shift -k Prior -m shift -k Return`: `^[[5;2~` printed, scrollbar offset unchanged.
- **D-02** (medium): Shift+Insert / Ctrl+Insert send `\e[2;2~` / `\e[2;5~`. xterm.js sends nothing for them (`Keyboard.ts:189-196`, "used to copy-paste on some systems") and Chromium's textarea pastes on Shift+Insert [inferred]. Repro: raw reader, `realkeys $D -M shift -k Insert -m shift`.
- **D-03** (medium): see T-12: Shift/Ctrl+Enter, Ctrl+Tab, Ctrl+Esc arrive as `CSI 27;m;k~`. Listed here again because it is the one most users will hit (Shift+Enter puts `;2;13~` on the command line in bash).
- **D-04** (low): Edit › Copy shows the toast `clipboard set from terminal`, which is the OSC 52 message; Electron's Edit › Copy shows nothing. Cause: the menu uses Ghostty's `copy_to_clipboard = .mixed` (`chrome/menu.zig:392-394`), and `Clipboard.set` treats every core clipboard write as OSC 52 (`pane.zig:1673-1684`). `.mixed` also puts a `text/html` copy on the clipboard. Ctrl+Shift+C goes another way and has no toast.
- **D-05** (medium): Ctrl+Shift+U (IBus / GTK Unicode entry) is swallowed before the input method; see T-14.
- **D-06** (low): the selection edge cases in T-18.
- **D-07** (low, READ): the first click in an unfocused pane only focuses it (T-24).
- **D-08** (low, READ): scrollbar drag into the sticky band does not re-stick (T-30).
- **D-09** (observation, not verified): the cell is 8 px wide where xterm's WebGL renderer uses 7 px at scale 1 (T-01), so the native client fits fewer columns in the same width.
- **D-10** (observation, host side, seen once): after one server restart the host's own snapshot started at line 21 of a `seq 1 300` (lines 1–20 gone). Raw snapshot read with a separate WebSocket client, so the host lost them, not the native client. Not reproduced on a second try.
- **D-11** (test-harness safety): in a dev-mode session (`headless --host`), `tmux` starts a login bash that rebuilds `PATH` from this machine's profile: inside it `command -v xdg-open` resolved to `/run/current-system/sw/bin/xdg-open` (the real one), not the shim, with the user's real prompt configuration. `DISPLAY` stayed `no-such-display.invalid:0` and `WAYLAND_DISPLAY` was empty, and I ran no launcher there. Any test that runs tmux or `bash -l` in a session must not call `xdg-open`. The same PATH loss would affect real remote hosts whose login shells reset PATH (H-02 then silently stops working inside tmux), which is a host/shim design point for the lead.
- **D-12** (low, panels' area, seen in logs): at a window of 900×600 the settings dialog logs `Adwaita: GtkBox … exceeds AdwDialog height: requested 550 px, 509 px available` and several `Widget reports min height … but overall min height …` warnings.
- **D-13** (low): `warning(stream): invalid C0 character, ignoring: 0x18` on the first attach to a fresh session (dev and fake host). Harmless, but it is in every run's log.
- Tooling note: `wmctl mouse button:=3` (JSON int) is silently treated as left; only `button=right|middle` works.

## Summary

Counts (56 items: 42 in §1, 11 in §2, 3 in §14):

| Verdict | Count | Items |
| --- | --- | --- |
| PASS | 43 | T-01, T-04…T-08, T-10, T-11, T-13, T-15…T-24, T-26, T-28…T-30, T-32…T-39, T-41, T-42, C-02, C-04, C-05, C-07, C-08, C-09, C-11, H-01, H-02, H-03 (T-18, T-24 and T-30 with notes; C-08 `claude` mode by reading) |
| FAIL | 6 | T-03, T-09, T-12, T-14, C-01, C-06 |
| DEVIATION (matches the recorded text) | 4 | T-25 (17, 26), T-27 (18), T-31 (1), T-40 (19) |
| RULED (matches) | 1 | C-10 (A-11) |
| READ | 2 | T-02, C-03 (both look right) |
| MISSING / N/A | 0 | |

Failures, ordered by how much a user would care:

1. **T-12 / D-03**: Shift+Enter, Ctrl+Enter, Ctrl+Tab, Ctrl+Shift+Tab and Ctrl+Esc send Ghostty's `CSI 27;…~` sequences instead of xterm's. Shift+Enter in bash puts garbage on the command line.
2. **D-01**: Shift+PageUp/PageDown do not scroll back. They are sent to the program.
3. **C-06**: Edit › Paste ignores an image on the clipboard.
4. **T-14 / D-05**: the IM's Ctrl+Shift+U Unicode entry is swallowed by the pane's Ctrl+Shift+letter rule.
5. **D-02**: Shift+Insert / Ctrl+Insert go to the program instead of paste/copy.
6. **T-09**: 5 px padding instead of 4 (points vs pixels), which also makes the documented width rule 2 px short.
7. **T-03**: about 4760 lines of scrollback instead of 5000.
8. **C-01**: an OSC 52 payload that is not valid UTF-8 goes onto the clipboard raw.
9. **D-04**: Edit › Copy shows the OSC 52 toast.
10. Minor: T-18 edge cases, unfocused-pane first click (READ), scrollbar drag not re-sticking (READ).

Not auditable here: real pointer input (GTK gesture/scroll controllers, cursor shapes, focus-on-click, scrollbar hover/drag; no pointer device on the headless seat); IBus/fcitx (no IM server; the simple IM was used); the `claude` paste-result mode (needs Claude Code); the Electron client itself (not run, so the cell-width comparison is from xterm's source only); smoothness (Debug build).

Wider pattern: where the pane hands a key straight to Ghostty, Ghostty's defaults leak through instead of xterm's. Examples are the modified Enter/Tab/Esc encodings, Shift+PageUp/Down, Shift/Ctrl+Insert, Alt+arrows and the padding unit. The pane already overrides some of these one key at a time (Ctrl+[ / I / M, `pane.zig:554-568`), but nobody went through xterm's `Keyboard.ts` systematically. Separately, the pane assumes every clipboard write from the core is OSC 52 (`pane.zig:1673-1676`), and the chrome's Edit menu breaks that assumption (D-04, C-06).
