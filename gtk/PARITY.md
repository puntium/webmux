# webmux native client: feature-parity checklist

## Status

Ticked on 2026-11-05 from the audit records: the first audit
(`gtk/audit/terminal.md`, `layout.md`, `files.md`, `connections.md`,
`panels-protocol.md`), the re-check after the first fix round
(`gtk/audit/recheck-terminal-layout.md`,
`recheck-files-connections-panels.md`), and the rulings and deviations in
`docs/native-client.md`. The latest record wins. The final check of the
second fix round (`gtk/audit/final-check.md`) did not exist yet when this
was written, so nothing here rests on it.

Each item ends with its status: `[x]` ✅ audited (PASS, or FAIL then
FIXED at re-check) or ✅ deviation/ruling (differs on purpose, confirmed to
match the recorded deviation or ruling); `[~]` ⚠ partly (PARTLY at
re-check, or a later record contradicts the tick and the fix landed in the
second fix round without an independent check yet) or 👁 judged by
reading only; `[ ]` ❌ open or ❓ no audit record; `[-]` n/a. "(… by
reading)" on a ticked item means one sub-point was judged by reading.

| Section | ✅ audited | ✅ deviation / ruling | ⚠ partly | 👁 reading only | ❌ open | ❓ no record | n/a | Items |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1. Terminal pane | 35 | 3 | 3 | 1 | 0 | 0 | 0 | 42 |
| 2. Clipboard, paste, links | 8 | 1 | 1 | 1 | 0 | 0 | 0 | 11 |
| 3. Session lifecycle | 9 | 4 | 0 | 1 | 0 | 0 | 0 | 14 |
| 4. Layout | 35 | 5 | 0 | 2 | 0 | 0 | 0 | 42 |
| 5. Keyboard shortcuts | 10 | 2 | 0 | 0 | 0 | 0 | 0 | 12 |
| 6. File browser | 45 | 6 | 1 | 2 | 0 | 0 | 0 | 54 |
| 7. Connections | 20 | 8 | 2 | 2 | 0 | 0 | 2 | 34 |
| 8. Deploy | 9 | 0 | 0 | 0 | 0 | 0 | 0 | 9 |
| 9. Window chrome | 24 | 7 | 4 | 1 | 0 | 0 | 0 | 36 |
| 10. Settings | 11 | 2 | 0 | 0 | 0 | 0 | 0 | 13 |
| 11. Connection log | 17 | 1 | 0 | 1 | 0 | 0 | 0 | 19 |
| 12. Status messages, modals | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 6 |
| 13. Wire protocol | 21 | 0 | 0 | 1 | 0 | 0 | 0 | 22 |
| 14. Host shims | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 3 |
| **Total** | **253** | **39** | **11** | **12** | **0** | **0** | **2** | **317** |

**Update after the final check and the third fix round (lead, 2026-11-05):**
of the 11 items marked partly above, 8 are now confirmed by the final check
on the release binary (T-18, T-22, C-06, F-42, X-01, X-03, W-11, W-21: ticked
below), and 3 remain partly because their last fix (third round) has not been
re-checked independently (T-27, W-05, W-42). Current totals: 257 audited, 43
deviation/ruling, 3 partly, 12 by reading only, 2 n/a. The per-section table
above is as of the first ticking.

- **Open:** none.
- **Partly:** T-18, T-22, T-27, C-06, F-42, X-01, X-03, W-05, W-11, W-21, W-42.
  Each was fixed in the second fix round and waits for the final check.
- **Judged by reading only:** T-02, C-03, S-12, L-35, L-36, F-54, F-58, X-13, X-31, W-19, G-29, P-27.
- **No audit record:** none.
- **Not applicable:** X-40, X-41 (macOS only).

K-01…K-15 and K-20…K-26 are one checklist item each; the audit gave each
binding its own row. All K-01…K-15 rows passed; the K-20…K-26 rows passed
except under an open dialog (deviation 31), which the re-check found fixed.

---

This is the definition of "done" for the native Linux client (Ghostty fork,
GTK4). Every behaviour the Electron client (`electron/`) has is listed here
as one checkbox. A later audit ticks each one off against the native build.

Conventions:

- References are `path:line` relative to the repo root, pointing at the
  place in the Electron client (or the host, for the wire contract) that
  implements the behaviour. Where docs and code disagree, the code wins and
  the disagreement is listed under [Ambiguities](#ambiguities).
- Linux is the target. Where the code branches on platform, the Linux branch
  is the requirement and the macOS equivalent is noted in passing.
- Tags:
  - `[mac-only]` exists only for macOS. Listed for completeness; not
    required on Linux.
  - `[electron-artifact]` exists only because the client is a browser. The
    mechanism is not required, but the user-visible outcome it serves (given
    in the item) is.
  - `[implicit]` nobody wrote it down; it falls out of xterm.js or Chromium
    defaults, and users rely on it anyway.
  - `[inferred]` I worked this out from library internals or from how the
    code paths combine, rather than reading it in this repo's code. Verify it
    against the running Electron client before treating it as contractual.
- IDs (`T-01` …) are stable handles for the audit.

Colours are the dark theme unless a light value is given. The light theme
uses the same token names (`electron/ui/index.html:73-97`).

---

## 1. Terminal pane: rendering, input, scrolling, lifecycle messages

### Rendering options

- [x] **T-01** Font: JetBrainsMono Nerd Font, bundled with the client in regular, bold, italic and bold-italic (`electron/ui/fonts/*.woff2`, about 1 MB each). Size 13px, line height 1.0, letter spacing 0, normal weight `normal`, bold weight `bold`. — `electron/ui/app.js:40`, `electron/ui/app.js:759-764`, `electron/ui/index.html:18-41` — ✅ audited
- [~] **T-02** Fallback: if the bundled font has not loaded within 3000 ms at startup, render with the system `monospace`. Once the font arrives, re-measure every terminal's cell grid and the column-width rule (L-15). Glyphs must never sit on a grid measured from a different font. — `electron/ui/app.js:1713-1738` `[electron-artifact]`: with an embedded font there is no load race, but the outcome (grid sized from the real font) is required. — 👁 by reading only
- [x] **T-03** Scrollback: 5000 lines per terminal on the client. The host mirror also keeps 5000 (`host/internal/ptyhost/session.go:19`). — `electron/ui/app.js:763` — ✅ audited
- [x] **T-04** Cursor: block cursor (xterm default) that blinks while the terminal is focused (`cursorBlink: true`). A terminal without focus draws an outlined, non-blinking cursor (xterm `cursorInactiveStyle: 'outline'`). — `electron/ui/app.js:760` `[implicit]` for the inactive style — ✅ audited
- [x] **T-05** Dark palette: background `#1f1f2b` (matches the pane panel colour). All other colours are xterm.js 5.5 defaults: foreground `#ffffff`, cursor `#ffffff`, cursor accent `#000000`, selection `rgba(255,255,255,0.3)`, ANSI 0–15 `#2e3436 #cc0000 #4e9a06 #c4a000 #3465a4 #75507b #06989a #d3d7cf #555753 #ef2929 #8ae234 #fce94f #729fcf #ad7fa8 #34e2e2 #eeeeec`, and the standard 256-colour cube and greys. — `electron/ui/settings.js:17-21`; defaults from `electron/node_modules/@xterm/xterm/src/browser/services/ThemeService.ts:23-52` `[implicit]` — ✅ audited
- [x] **T-06** Light palette: background `#f4f5f9`, foreground `#343b58`, cursor `#343b58`, cursor accent `#f4f5f9`, selection `rgba(46,125,233,0.25)`, inactive selection `rgba(46,125,233,0.15)`, ANSI black `#3b3e4d` red `#c8283f` green `#587539` yellow `#8c6c3e` blue `#2e7de9` magenta `#9854f1` cyan `#007197` white `#7d84a3`, bright black `#6a6f87` red `#f52a65` green `#4d8a2f` yellow `#a5772a` blue `#1c5fc4` magenta `#7c3de0` cyan `#0a8fb5` white `#343b58`. — `electron/ui/settings.js:22-48` — ✅ audited
- [x] **T-07** A theme change repaints every open terminal immediately. Nothing is reopened, and scrollback and selection are kept. — `electron/ui/app.js:721-726` — ✅ audited
- [x] **T-08** Bold text in ANSI colours 0–7 is drawn in the bright variant (xterm `drawBoldTextInBrightColors: true`). No minimum-contrast adjustment (`minimumContrastRatio: 1`). Tab stops every 8 columns. — xterm defaults `[implicit]` — ✅ audited
- [x] **T-09** The terminal area inside the pane body has 4px padding on all sides. The grid takes the largest whole number of cells that fit, and the remainder is blank. — `electron/ui/index.html:339-340` — ✅ audited
- [x] **T-10** Each terminal has a vertical scrollbar 10px wide on a transparent track: a pill-shaped thumb inset by 3px, colour `rgba(200,200,216,0.22)`, `rgba(200,200,216,0.4)` on hover (light theme `rgba(52,59,88,0.25)` / `0.45`). The column-width rule counts this 10px (L-15). — `electron/ui/index.html:102-111`, `electron/ui/app.js:396-398` — ✅ audited
- [x] **T-11** GPU-accelerated rendering, so several visible terminals across several hosts stay smooth. — `electron/ui/app.js:804-821` `[electron-artifact]`: the WebGL addon, the 16-context cap, context-loss fallback to the DOM renderer and its log lines are browser workarounds. The requirement is "many visible terminals repaint without main-thread stalls". — ✅ audited

### Input

- [x] **T-12** Every keystroke the terminal produces (xterm encoding of keys, including application cursor/keypad modes, Alt as ESC prefix on Linux, and the kitty keyboard protocol if the app enables it) goes to the host as `{"type":"input","data":<string>}`, but only while the session socket is open. Keystrokes typed while it is closed are dropped, not queued. — `electron/ui/app.js:850-854` — ✅ audited
- [x] **T-13** Ctrl+letter sends the C0 control code. Ctrl+Space sends NUL. Ctrl+3…7 send ESC, FS, GS, RS, US. Ctrl+8 sends DEL. Ctrl+[ \ ] send ESC, FS, GS. Ctrl+Shift+letter sends nothing to the pty: it falls through to the application layer (xterm only encodes Ctrl+letter without Shift). — `electron/node_modules/@xterm/xterm/src/common/input/Keyboard.ts:330-392` `[implicit]` — ✅ audited
- [x] **T-14** IME and dead-key composition work in the terminal, with the composition preview drawn at the cursor. — xterm hidden-textarea composition `[implicit]` — ✅ audited (simple IM; IBus/fcitx not verifiable headlessly)
- [x] **T-15** Chord keys are taken out of the input stream before the terminal sees them. The pane chords (K-*) and app shortcuts (K-20…K-26) never reach the pty. — `electron/ui/app.js:1599-1614`, `electron/main.js:289-298` — ✅ audited
- [x] **T-16** Ctrl+Alt+V sends a literal `\x16` (^V, e.g. vim visual-block), whatever is on the clipboard. — `electron/ui/app.js:868-871` — ✅ audited
- [x] **T-17** Typing into the terminal snaps the viewport back to the bottom (xterm `scrollOnUserInput: true`). — xterm default `[implicit]` — ✅ audited

### Mouse, selection, links

- [x] **T-18** Mouse selection: drag selects a character range, double-click selects a word, triple-click selects a line, Shift+click extends the selection. Word separators are space and `()[]{}',"` and backtick. — xterm defaults `[implicit]` — ✅ deviation 58: confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **T-19** When the running program enables mouse tracking, clicks and wheel go to the program. Shift+drag still makes a local selection. — xterm defaults `[implicit]` `[inferred]` — ✅ audited
- [x] **T-20** Alt+click on the prompt line moves the shell cursor there by sending arrow keys (xterm `altClickMovesCursor: true`). — xterm default `[implicit]` — ✅ audited
- [x] **T-21** Linux PRIMARY selection: a finished mouse selection becomes the PRIMARY selection (middle-click pastes it into other apps). Middle-click in a terminal pastes PRIMARY into that terminal. — xterm `onLinuxMouseSelection` (`electron/node_modules/@xterm/xterm/src/browser/Terminal.ts:360-368,529-535`) `[implicit]` `[inferred]` — ✅ audited
- [x] **T-22** Copy is not automatic: selecting text does not touch the CLIPBOARD selection. The selection is copied by Edit › Copy, which the Linux build reaches only through the menu bar (see A-03). On macOS it is ⌘C. — `electron/main.js:1462` `[implicit]` — ✅ audited: fixed in round 2, confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **T-23** Right-click shows no context menu, and on Linux it does not select a word (xterm `rightClickSelectsWord` is macOS-only). — `electron/node_modules/@xterm/xterm/src` defaults; no context-menu handler anywhere in `electron/` `[implicit]` — ✅ audited
- [x] **T-24** Plain-text `http://` and `https://` URLs in terminal output are detected and underlined while the pointer hovers them. A click opens the URL in the system default browser. Shift+click copies it to the clipboard instead and shows the toast `link copied`. — `electron/ui/app.js:779-784`, `electron/ui/app.js:545-553` — ✅ audited
- [x] **T-25** OSC 8 hyperlinks (e.g. Claude Code's `/login`, `ls --hyperlink`, `gh`) behave exactly like T-24: click opens, Shift+click copies. Only http(s) targets are active; `mailto:`, `file:` and other schemes stay inert. There is never a "do you want to navigate" confirmation. — `electron/ui/app.js:765-774` — ✅ deviation 17, 26
- [x] **T-26** Nothing opens inside the app window. Any http(s) navigation the page attempts goes to the system browser, and anything else is denied. — `electron/main.js:311-314`, `electron/main.js:497-501` `[electron-artifact]`: the outcome is "links always land in the real browser". — ✅ audited

### Scroll behaviour

- [~] **T-27** The wheel scrolls the viewport through scrollback when the program has not enabled mouse tracking. Alt+wheel scrolls 5× faster (xterm `fastScrollModifier: 'alt'`, `fastScrollSensitivity: 5`). Scroll sensitivity 1, no smooth-scroll animation. — xterm defaults `[implicit]` — ⚠ partly: deviation 57's numbers confirmed by the final check (`gtk/audit/final-check.md`), which found the distance depended on how a swipe is sliced; fixed in round 3 (deviation 63), covered by the pane smoke on both binaries, not independently re-checked
- [x] **T-28** Sticky bottom. Each terminal keeps a "sticky" flag, initially on. While sticky, every output chunk scrolls the viewport to the bottom after it is parsed. — `electron/ui/app.js:746`, `electron/ui/app.js:927-929` — ✅ audited
- [x] **T-29** Any upward scroll (a wheel-up gesture or a viewport move upward) turns sticky off at once, so output never yanks a reader back down. — `electron/ui/app.js:837`, `electron/ui/app.js:842-846` — ✅ audited
- [x] **T-30** A downward scroll that lands within `max(3, round(rows × 0.15))` lines of the bottom turns sticky back on and snaps to the very bottom. The band is measured in screen rows, not as a fraction of scrollback. — `electron/ui/app.js:834-841` — ✅ audited

### Session socket, snapshot, reconnect, exit messages

- [x] **T-31** Each terminal pane opens its own WebSocket to `ws://127.0.0.1:<localPort>/ws?session=<id>` as soon as the pane is created or restored. — `electron/ui/app.js:902-908`, `electron/ui/env.js:16-18` — ✅ deviation 1
- [x] **T-32** When the socket opens: mark the tile online, reset the retry delay to 0, clear the page-level "link down" flag (S-12), and send a resize with the current grid (T-38). — `electron/ui/app.js:910-918` — ✅ audited
- [x] **T-33** On a `snapshot` frame: fully reset the terminal (clear screen, scrollback and modes), write `data` verbatim, set the pane title from `title`, then fit and send a resize. Every attach and reattach repaints this way, scrollback included. — `electron/ui/app.js:921-926` — ✅ audited
- [x] **T-34** On an `output` frame: write `data`. If sticky, scroll to the bottom once the chunk is parsed (T-28). — `electron/ui/app.js:927-929` — ✅ audited
- [x] **T-35** On a socket close that was not caused by closing the pane or by the session exiting: (a) if the socket had been open, write `\r\n` followed by `[disconnected — reconnecting…]` in yellow (SGR 33, then SGR 0) and `\r\n`; (b) set the page "link down" flag; (c) reconnect after a delay of `min((previous || 500) × 2, 10000)` ms, i.e. 1 s, 2 s, 4 s, 8 s, then 10 s for every later attempt. The delay resets on a successful open. Retries never stop while the pane exists and the session has not exited. — `electron/ui/app.js:958-982` — ✅ audited
- [x] **T-36** A reconnect is skipped if a newer socket for the same tile already exists, so there is never more than one live socket per pane. — `electron/ui/app.js:978-981` — ✅ audited
- [x] **T-37** On an `exit` frame: write `\r\n`, then `[session exited: <exitCode>]` in red (SGR 31, then SGR 0), then `\r\n`. 1200 ms later remove the pane, without a DELETE (the session is already gone). Do not reconnect. The host reports exit code 0 for a signal death (`host/internal/ptyhost/session.go:187-202`). — `electron/ui/app.js:937-941` — ✅ audited
- [x] **T-38** Resize reporting: after any change to the pane's pixel size (window resize debounced 100 ms, divider drag on every move, layout render, settings change, font load, socket open, snapshot), refit the grid to the pane and send `{"type":"resize","cols":C,"rows":R}` if the socket is open. Batch fits to at most one per frame. Never fit a terminal that is not on screen. — `electron/ui/app.js:455-463`, `electron/ui/app.js:1023-1031`, `electron/ui/app.js:1696-1700` — ✅ audited
- [x] **T-39** On an `error` frame (the host has no such session): log `session gone on the host — closing its tab` and remove the pane without a DELETE. — `electron/ui/app.js:953-956` — ✅ audited
- [x] **T-40** On a `title` frame, set this pane's title. On a `session-title` frame (`{session, title}`, which arrives on every open socket for every session), set the title of the pane showing `session`, if there is one. Setting a title is idempotent. — `electron/ui/app.js:930-936` — ✅ deviation 19
- [x] **T-41** The pane label shows the terminal title, or the session id while the title is empty. — `electron/ui/app.js:750-754`, `electron/ui/app.js:256` — ✅ audited
- [x] **T-42** The host keeps one shared terminal size per session: the last attached client's resize wins. Viewing the same session from two clients is allowed and not prevented. — `README.md:456-457`, `host/internal/ptyhost/session.go:328-341` — ✅ audited

---

## 2. Clipboard, paste and links

- [x] **C-01** OSC 52 write (`ESC ] 52 ; <target> ; <base64> BEL/ST`): base64-decode the payload, decode it as UTF-8 and write it to the system CLIPBOARD, then show the toast `clipboard set from terminal`. The target field (c/p/s…) is ignored and always goes to CLIPBOARD. Malformed base64 is ignored silently. — `electron/ui/app.js:786-798`, `electron/ui/app.js:516-536` — ✅ audited
- [x] **C-02** An OSC 52 read query (payload `?`) is swallowed and never answered, so no session can read the client's clipboard. — `electron/ui/app.js:791-792` — ✅ audited
- [~] **C-03** If the clipboard write fails, show the toast `clipboard write blocked by the browser` (on native, reword it to a native failure message). — `electron/ui/app.js:524-535` `[electron-artifact]`: the execCommand fallback is a browser workaround. — 👁 by reading only
- [x] **C-04** Ctrl+V (no Shift, Meta or Alt) in a terminal reads the system clipboard. If it holds an image (any `image/*`), run the image-paste flow (C-07). Otherwise, if it holds non-empty text, paste it as a normal terminal paste, with bracketed paste when the app enabled it. Otherwise (empty, or unreadable) send a literal `\x16`. It never sends a bare ^V while text or an image is on the clipboard. — `electron/ui/app.js:856-879`, `electron/ui/app.js:996-1022` — ✅ audited
- [x] **C-05** Ctrl+Shift+V in a terminal pastes the clipboard text (README says "Ctrl+V / Ctrl+Shift+V paste as before"). An image on the clipboard goes through C-07 too, because it arrives as a paste event (C-06). — `README.md:108-109`; reached via Chromium's native paste on the hidden textarea, `electron/ui/app.js:885-893` `[implicit]` `[inferred]` — ✅ audited
- [x] **C-06** Any paste event that carries an image (native paste, Edit › Paste, ⌘V on macOS) is diverted to C-07. Text pastes go through the terminal's normal paste. — `electron/ui/app.js:881-893` — ✅ audited: fixed in round 2, confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **C-07** Image paste: with the session socket open, show the toast `uploading pasted image…`, then send `{"type":"paste-image","mime":<image mime>,"data":<base64 of the bytes>}`. If the socket is closed, do nothing. On an encoding error, show the toast `image paste failed: <error>`. — `electron/ui/app.js:984-995` — ✅ audited
- [x] **C-08** On `paste-result` with mode `claude`, show the toast `image in clipboard — Ctrl+V forwarded to Claude`. With mode `path`, show `pasted image → <path>`. — `electron/ui/app.js:942-945` — ✅ audited (`claude` mode by reading)
- [x] **C-09** Proactive clipboard image sync: whenever the client window gains focus (throttled to once per 1000 ms), read the clipboard. If it holds an image whose base64 differs from the last one synced, send `{"type":"clipboard-sync","mime","data"}` on the first open session socket of that host page and show the toast `clipboard image synced to sessions`. Text clipboards are never synced. Read failures are silent. — `electron/ui/app.js:485-511` — ✅ audited
- [x] **C-10** Clipboard image sync and image paste only make sense for the host formats `image/png`, `image/jpeg`, `image/gif`, `image/webp` and `image/bmp`. The host silently ignores anything else (`host/internal/server/paste.go:23-29`), so the client should convert to PNG or refuse with a toast (see A-11). — `host/internal/server/paste.go:87-106` — ✅ ruling A-11
- [x] **C-11** The "open-url" chooser: a program in a session that runs `xdg-open`/`sensible-browser`/`x-www-browser`/`$BROWSER` with an http(s) URL triggers an `open-url` frame `{url, id}`. Show a modal (M-04) offering Cancel / Copy / Open in browser. Each `id` is shown at most once per host page, because the frame is broadcast on every socket when the session is unknown. — `electron/ui/app.js:538-540`, `electron/ui/app.js:946-952`, `electron/ui/app.js:555-601` — ✅ audited

---

## 3. Session lifecycle

- [x] **S-01** Startup reconciliation, once the host page is ready (after settings and fonts, T-02): `GET /api/sessions`. On a fetch failure, log `session list fetch failed` (error) and stop; the page stays empty (see A-07). — `electron/ui/app.js:1620-1627` — ✅ ruling A-07
- [x] **S-02** Load the saved layout (L-40) for this host. Drop every terminal pane whose id is not in the live session list. File-browser panes are always kept. A column left empty disappears. — `electron/ui/app.js:1632-1637` — ✅ audited
- [x] **S-03** Every live session not in the saved layout (opened by another client, or saved by a client that lost its layout) is appended as a new single-pane column at the right end, in the server's list order (creation order). — `electron/ui/app.js:1638-1641` — ✅ audited
- [x] **S-04** Restore focus to the saved focused pane if it still exists, else to the first column's active pane. Seed every terminal pane's title from the session list before its snapshot arrives. — `electron/ui/app.js:1643-1651` — ✅ audited (title seeding by reading)
- [x] **S-05** Prune file-browser state entries (F-02) whose pane is no longer in the layout, then save the layout. — `electron/ui/app.js:1652-1653` — ✅ audited
- [x] **S-06** If the reconciled layout has no panes, create one new terminal automatically. Otherwise give keyboard focus to the focused pane. — `electron/ui/app.js:1655-1656` — ✅ audited
- [x] **S-07** Log `page attached` (info) with `{sessions: <count>, api: <base url>}`. — `electron/ui/app.js:1628` — ✅ audited
- [x] **S-08** Create a terminal: `POST /api/sessions` with body `{"cols":80,"rows":24}` and use the `id` from the 201 response. The pane opens at once and fits/resizes on attach (T-32). — `electron/ui/app.js:1389-1397` — ✅ audited
- [x] **S-09** Close a terminal pane (✕, close-pane command): stop its reconnect loop, close its socket, `DELETE /api/sessions/<id>` (errors ignored), animate the pane out (L-34), then dispose the terminal. There is no confirmation dialog. — `electron/ui/app.js:1353-1383` — ✅ deviation 45
- [x] **S-10** A session that exits on the host (shell exited, or killed by another client) shows the exit message and its pane closes by itself after 1200 ms (T-37). — `electron/ui/app.js:937-941` — ✅ audited
- [x] **S-11** Sessions created by another client while this page is open are not picked up until the page reloads or reconnects to a fresh page (there is no list polling). — `electron/ui/app.js:1620-1657` (only call site, at startup) `[implicit]` — ✅ audited
- [~] **S-12** Page-level "link down": set when any session socket closes unexpectedly, cleared when any socket opens. Log a transition to down as `link down — a session socket dropped and is retrying` (warn) and back to up as `link up — a session socket is open again` (info). The host's chrome state is derived from this flag (W-12). — `electron/ui/app.js:200-210` — 👁 by reading only (transitions exercised; link-down aggregation judged by reading)
- [x] **S-13** Reload of a host page (View › Reload, ⌘R on macOS) rebuilds everything from the server: sessions reattach from snapshots, layout and file-browser state come back from persistence. — `electron/main.js:1466`, `README.md:287-288` — ✅ ruling A-15
- [x] **S-14** After Restart Sessions succeeds (X-22) on a host whose page is live, reload that host page so it starts clean against the new pty host. — `electron/main.js:1090-1096` — ✅ deviation 12

---

## 4. Layout (scrolling columns, niri/PaperWM style)

### Model

- [x] **L-01** The workspace of each host is a horizontal strip of columns. Each column is a vertical stack of one or more panes. A pane is either a terminal (server session id, a UUID) or a file browser (client-only id `files-<…>`). — `electron/ui/app.js:42-47`, `electron/ui/app.js:22-26` — ✅ audited
- [x] **L-02** Column record: `{panes:[id…], sizes:[weight…], active:id, full?:true}`. `sizes` are relative height weights parallel to `panes`. `active` is the pane that takes focus when the column is entered from the side. `full` marks a full-window column. — `electron/ui/app.js:42-46`, `electron/ui/app.js:53` — ✅ audited
- [x] **L-03** A pane inserted into an existing column gets the column's average weight. — `electron/ui/app.js:59-66` — ✅ audited
- [x] **L-04** Removing a pane removes its weight. An emptied column disappears. If the removed pane was the column's active pane, the pane now at the same index (else the last pane) becomes active. — `electron/ui/app.js:68-78` — ✅ audited (non-focused active pane by reading)
- [x] **L-05** Pane heights within a column are the weights normalised to sum to 1, so a lone survivor of a resized stack fills its whole column. — `electron/ui/app.js:222-228` — ✅ audited

### Commands (exact semantics)

- [x] **L-06** **new-terminal**: create a session (S-08) and open it as a new single-pane column immediately to the right of the focused pane's column (at the right end if nothing is focused). The new pane takes focus. Animated. — `electron/ui/app.js:1399-1415` — ✅ audited
- [x] **L-07** **new-terminal-below**: create a session and insert it into the focused pane's column directly below the focused pane, with the average weight. The new pane takes focus and becomes the column's active pane. With nothing focused it behaves like new-terminal. Animated. — `electron/ui/app.js:1417-1428` — ✅ deviation 6
- [x] **L-08** **new-files**: create a file-browser pane (F-01) as a new column right of the focused column, as in L-06. It takes focus. No server call. — `electron/ui/app.js:1430-1435` — ✅ audited
- [x] **L-09** **close-pane**: close the focused pane (S-09 for terminals, F-60 for file browsers). — `electron/ui/app.js:1508-1512` — ✅ audited
- [x] **L-10** Focus after a removal: the next pane down the same stack, else the one above, else the right-hand neighbouring column's active pane, else the left-hand one's, else nothing. — `electron/ui/app.js:80-94` — ✅ audited
- [x] **L-11** **toggle-full**: if the focused pane shares its column, split it out into a new column directly right of its old column, marked full. If it is alone, toggle its column's `full` flag. A full column is exactly the strip's width and ignores the width rule. Animated. — `electron/ui/app.js:1514-1530`, `electron/ui/index.html:210` — ✅ audited
- [x] **L-12** **focus-left / focus-right**: focus the active pane of the neighbouring column. No-op at either end (no wrap). — `electron/ui/app.js:1441-1444` — ✅ audited
- [x] **L-13** **focus-up / focus-down**: focus the neighbouring pane in the same stack. No-op at the ends (no wrap, never crosses columns). — `electron/ui/app.js:1446-1450` — ✅ audited
- [x] **L-14** **move-column-left / right**: swap the focused pane's whole column (its stack included) with the neighbouring column. No-op at the ends. Focus stays on the same pane. Animated. — `electron/ui/app.js:1460-1469` — ✅ audited
- [x] **L-15** Column width rule. Measure the cell width as the advance of `W` in the 13px terminal font (100 glyphs ÷ 100). Then `px(cols) = ceil(cols × cell) + 24` (pane border 2 + padding 8 + scrollbar 10 + slack 4), `min = px(minCols)`, `max = max(min, px(maxCols))`, `inner = stripWidth − 12`, `fit = max(1, floor((inner + 6) / (min + 6)))` and `share = floor((inner − (fit − 1) × 6) / fit)`. Each column starts at `basis = clamp(share, min, max)`, capped at the strip width; it never shrinks and may grow up to `max`. With `fit` or fewer columns they grow equally to share the strip up to `max` each, and any space left over centres the group. With more columns than `fit`, every column has width `basis` and the strip scrolls horizontally. Gap between columns 6px, strip padding 6px. — `electron/ui/app.js:373-418`, `electron/ui/index.html:178-210` — ✅ audited
- [x] **L-16** The width rule follows the settings live (minimum and maximum width, E-03/E-04), window resizes (debounced 100 ms) and font loads. Each recompute refits the terminals and re-reveals the focused column. — `electron/ui/app.js:1696-1707`, `electron/ui/app.js:1735-1737` — ✅ deviation 20
- [x] **L-17** **move-pane-up / down**: swap the focused pane with its stack neighbour, weights included. No-op at the ends. Focus stays. Animated. — `electron/ui/app.js:1479-1489` — ✅ audited
- [x] **L-18** **consume-expel-left / right** (niri consume-or-expel): if the focused pane shares its column, expel it into a new single-pane column on that side of its old column (left: inserted before it; right: inserted after it). If it is alone, merge it into the neighbouring column on that side, appended at the bottom with the average weight, and the emptied column disappears. A lone pane with no column on that side does nothing. Two presses carry a stacked pane into the next column, each step visible. Focus stays on the pane. Animated. — `electron/ui/app.js:1471-1477`, `electron/ui/app.js:1491-1506` — ✅ audited

### Focus

- [x] **L-19** Exactly one pane is focused per host page. Focusing a pane also makes it its column's active pane and saves the layout. — `electron/ui/app.js:282-298` — ✅ audited
- [x] **L-20** Pressing the mouse anywhere in a pane focuses it, before the click is handled. Clicking the title bar (not ✕) also moves keyboard focus into the pane's content. — `electron/ui/app.js:276`, `electron/ui/app.js:267-268` — ✅ audited
- [x] **L-21** Keyboard focus commands (L-12, L-13) move keyboard input into the newly focused pane's content. After every structural command the focused pane keeps keyboard focus. — `electron/ui/app.js:1443`, `electron/ui/app.js:1452-1458` — ✅ audited
- [x] **L-22** Focus changes alone do not rebuild or refit any terminal. Only the focus ring and fade change. — `electron/ui/app.js:167-171`, `electron/ui/app.js:286-298` — ✅ audited
- [x] **L-23** The focused pane's border is the accent `#7aa2f7` (light `#2e7de9`), 1px plus a 1px outer ring of the same colour, so it reads as a 2px ring. Unfocused panes have a 1px border in `#34344a` (light `#c4c8d8`). Panes have 8px corner radius and background `#1f1f2b` (light `#f4f5f9`). — `electron/ui/index.html:226-241` — ✅ audited
- [x] **L-24** Unfocused fade: with fade setting `f` (0–100, E-02) and `k = f/100`, every unfocused pane body is drawn at opacity `1 − 0.375k` with a black overlay of alpha `0.7k` on top. Both transition over 0.12 s. At 0 there is no effect at all. The default 40 gives opacity 0.85 and overlay 0.28. The title bar is not faded. — `electron/ui/index.html:293-318`, `electron/ui/settings.js:84-95` — ✅ deviation 21

### Horizontal scrolling of the strip

- [x] **L-25** After every focus change and structural change, scroll the strip the minimum distance that shows the focused pane's whole column plus 6px of margin on each side. A column that is already fully visible never causes a scroll (no re-centring). Visibility is judged against the scroll target in flight, not the current position. — `electron/ui/app.js:300-329` — ✅ audited
- [x] **L-26** Strip scroll animation: exponential approach to the target with time constant τ = 60 ms (`step = Δ × (1 − e^(−dt/τ))`, at least 1px per frame), dt capped at 100 ms per frame, snapping when within 0.5px. A new target mid-flight redirects the motion without restarting it. — `electron/ui/app.js:331-371` — ✅ audited
- [x] **L-27** A two-finger horizontal swipe or horizontal wheel (|Δx| > |Δy|) pans the strip directly by Δx, cancelling any reveal animation. Over a file browser, its own Miller columns scroll first and the strip takes over at their edge. Vertical wheel stays with the terminal. — `electron/ui/app.js:1676-1694` — ✅ audited
- [x] **L-28** After a structural change that made the strip narrower while it was scrolled past its new end, the strip eases to the new end instead of jumping. — `electron/ui/app.js:1322-1330`, `electron/ui/app.js:1304-1310` — ✅ audited

### Dividers

- [x] **L-29** Between stacked panes sits a horizontal divider 6px tall with 1px margin above and below (8px pane-to-pane), radius 3px, colour `#34344a`, accent on hover and while dragging (0.15 s transition), row-resize cursor. — `electron/ui/index.html:214-225` — ✅ audited (cursor shape by reading)
- [x] **L-30** Dragging a divider re-splits the combined weight of the two panes it separates, following the pointer, with each pane at least `min(110px / pairHeight, 0.45)` of the pair. Terminals refit live during the drag. The layout is saved on release. — `electron/ui/app.js:420-453`, `electron/ui/app.js:39` — ✅ audited

### Animations

- [x] **L-31** Every structural change (new pane, new below, close, expel/merge, move column, move pane, toggle full) animates. Each pane and divider travels from its old box to its new one over 200 ms with easing `cubic-bezier(0.4, 0, 0.2, 1)`. The final layout is in place from the first frame. Only transforms, clips and opacity animate, so terminals are not relaid out per frame. — `electron/ui/app.js:1042-1088`, `electron/ui/app.js:1246-1301` — ✅ audited
- [x] **L-32** A growing box is revealed by a clip from its old size up to its full size. A shrinking box shows its new size at once, with a ghost of its shell (panel background, border, focus ring if focused, the unfocused fade overlay) underneath, clipped from the old box down to the new one. — `electron/ui/app.js:1261-1288`, `electron/ui/index.html:319-330` — ✅ audited
- [x] **L-33** A new pane enters from a zero-size box at the bottom edge of the pane above it (8px gap; dividers 1px), else the top edge of the pane below, else as a zero-width sliver at the edge of the neighbouring column (left, else right), else grows in place. It fades from opacity 0 to 1. — `electron/ui/app.js:1190-1206`, `electron/ui/app.js:1265-1268` — ✅ audited
- [x] **L-34** A closing pane stays on screen at its old box, its content frozen but still drawing, while a clip closes in. A pane alone in its column is wiped from the right while the columns beyond slide in. A stacked pane is squeezed to the line where its neighbours meet (half a gap below the new bottom of the pane above, else half a gap above the pane below, else its own middle) while they grow into its room. Its terminal is disposed once the animation ends. — `electron/ui/app.js:1222-1244`, `electron/ui/app.js:1290-1301`, `electron/ui/app.js:1362-1380` — ✅ audited
- [~] **L-35** While boxes overlap in flight, the focused pane is drawn above other panes, and panes above dividers. — `electron/ui/app.js:1255-1259` — 👁 by reading only
- [~] **L-36** Columns are matched across a change by shared panes (greedy, most shared first, each old column used once), so dividers keep their identity: the divider left behind by a merge is the one that separated the top survivor from the leaver, and it slides as the survivors grow. — `electron/ui/app.js:1156-1178`, `electron/ui/app.js:1075-1079` — 👁 by reading only
- [x] **L-37** A change that lands mid-animation continues from the current in-flight geometry. Nothing snaps back to the end state first. — `electron/ui/app.js:1134-1154`, `electron/ui/app.js:1111-1132` — ✅ audited
- [x] **L-38** With the system "reduce motion" preference on, structural changes, strip scrolling and file-browser animations are instant. — `electron/ui/app.js:192`, `electron/ui/app.js:340-344`, `electron/ui/index.html:433-436,448` — ✅ audited
- [x] **L-39** Every animation is bounded: it settles no later than 250 ms (200 ms + 50 ms) after it starts, even if an end event never arrives. — `electron/ui/app.js:1312-1319` — ✅ audited

### Persistence and scoping

- [x] **L-40** The layout is saved on every structural change, focus change and divider release as `{"columns":[{panes,sizes,active,full}],"focused":<id|null>}` under the key `webmux-layout`. — `electron/ui/app.js:100-102` — ✅ deviation 2, 35
- [x] **L-41** Scope: one layout per client and per host+instance, not per profile name or forward port. The Electron key is the origin `webmux://<slug>-<hash8>/`. `slug` is the host string lower-cased, with runs outside `[a-z0-9-]` replaced by `-` and leading/trailing `-` trimmed. `hash8` is the first 8 hex chars of `sha256(host + "\n" + (instance || "default"))`. The layout survives app restarts, profile renames and port changes. — `electron/main.js:419-429` `[electron-artifact]`: localStorage by origin is the mechanism; the scoping rule is the requirement. — ✅ audited
- [x] **L-42** Loaded layouts are sanitised: drop malformed columns, ids that are neither string nor number, duplicate ids and empty columns. Weights that are not finite and positive become 1. `active` must name a pane in the column, else the first pane. `full` is true only if it was exactly `true`. — `electron/ui/app.js:132-152`, `electron/ui/app.js:154-161` — ✅ deviation 5

---

## 5. Keyboard shortcuts

Linux bindings are the requirement; the macOS column is for reference. The
pane chords go to the focused host page. The app shortcuts are intercepted
ahead of every view (host pages, header, connection page, log window).

### Pane chords (chord = Ctrl+Shift on Linux, ⌘ on macOS; secondary = Alt / ⌥)

| ID | Linux | macOS | Command |
| --- | --- | --- | --- |
| K-01 | Ctrl+Shift+Enter | ⌘↩ | new-terminal (L-06) |
| K-02 | Ctrl+Shift+Alt+Enter | ⌥⌘↩ | new-terminal-below (L-07) |
| K-03 | Ctrl+Shift+B | ⌘⇧↩ | new-files (L-08) |
| K-04 | Ctrl+Shift+W | ⌘W | close-pane (L-09) |
| K-05 | Ctrl+Shift+F | ⌘F | toggle-full (L-11) |
| K-06 | Ctrl+Shift+← / H | ⌘← / ⌘H | focus-left |
| K-07 | Ctrl+Shift+→ / L | ⌘→ / ⌘L | focus-right |
| K-08 | Ctrl+Shift+↑ / K | ⌘↑ / ⌘K | focus-up |
| K-09 | Ctrl+Shift+↓ / J | ⌘↓ / ⌘J | focus-down |
| K-10 | Ctrl+Shift+[ | ⌘[ | consume-expel-left (L-18) |
| K-11 | Ctrl+Shift+] | ⌘] | consume-expel-right |
| K-12 | Ctrl+Shift+Alt+← / H | ⌥⌘← / ⌥⌘H | move-column-left (L-14) |
| K-13 | Ctrl+Shift+Alt+→ / L | ⌥⌘→ / ⌥⌘L | move-column-right |
| K-14 | Ctrl+Shift+Alt+↑ / K | ⌥⌘↑ / ⌥⌘K, also ⇧⌘↑ / ⇧⌘K | move-pane-up (L-17) |
| K-15 | Ctrl+Shift+Alt+↓ / J | ⌥⌘↓ / ⌥⌘J, also ⇧⌘↓ / ⇧⌘J | move-pane-down |

- [x] **K-01…K-15** Each binding in the table runs its command. — `electron/ui/app.js:1550-1590`, `electron/main.js:1156-1177` — ✅ audited
- [x] **K-16** Chord detection on Linux: Ctrl and Shift held, Meta/Super not held. Alt optional (it is the secondary modifier). Letters and brackets are matched by physical key (`KeyH`, `BracketLeft`…), not by the character produced, so layouts and Shift do not change them (Shift turns `[` into `{`). Arrows and Enter are matched by key. — `electron/ui/app.js:1561-1572`, `electron/ui/app.js:1574-1584` — ✅ audited
- [x] **K-17** Combinations outside the table (e.g. Ctrl+Shift+Alt+W, Ctrl+Shift+Alt+[) do nothing and are not swallowed. — `electron/ui/app.js:1573-1590` — ✅ audited
- [x] **K-18** When keyboard focus is in a text field (settings inputs, file rename box, connection form) or any modal is open, the pane chords do not run. On Linux they are swallowed (not passed on) so a field never sees a chord as text and focus never moves out from under a modal. — `electron/ui/app.js:1599-1608` — ✅ audited
- [x] **K-19** A recognised pane chord never reaches the terminal (T-15). — `electron/ui/app.js:1609-1613` — ✅ audited

### App shortcuts (Linux: Ctrl-based, intercepted ahead of everything)

| ID | Linux | macOS | Action |
| --- | --- | --- | --- |
| K-20 | Ctrl+Shift+O | ⌘⇧O | show the connection manager (W-20) |
| K-21 | Ctrl+Shift+R | ⌘⇧R | reconnect the visible host (X-30) |
| K-22 | Ctrl+Shift+G | ⌃⌘L | open/focus the connection log window (G-20) |
| K-23 | Ctrl+, | ⌘, | open the settings panel on the visible host page (E-10) |
| K-24 | Ctrl+1 … Ctrl+9 | ⌘1 … ⌘9 | show the Nth connected host in pill order (no-op if none) |
| K-25 | Ctrl+PageUp | ⌘⇧[ | previous host in pill order, wrapping; from the connection page, the last host |
| K-26 | Ctrl+PageDown | ⌘⇧] | next host in pill order, wrapping; from the connection page, the first host |

- [x] **K-20…K-26** Each binding in the table performs its action. On Linux they are matched on key-down with Ctrl held, Alt and Meta not held, by physical key, and the key never reaches the page. — `electron/main.js:265-298`, `electron/main.js:358-365`, `electron/main.js:1440-1449`, `electron/main.js:1490-1503` — ✅ deviation 31, 32
- [x] **K-27** No app shortcut may collide with a pane chord. That is why the log is Ctrl+Shift+G (Ctrl+Shift+L is focus-right) and host cycling is Ctrl+PageUp/PageDown (Ctrl+Shift+[ ] are consume-or-expel). Keep this invariant when adding bindings. — `electron/main.js:272-276` — ✅ audited
- [x] **K-28** Ctrl+1…9, Ctrl+PageUp/PageDown, Ctrl+, and the Ctrl+Shift app keys therefore never reach the terminal on Linux. — `electron/main.js:289-298` `[implicit]` — ✅ audited

### Terminal and file-browser keys

- [x] **K-29** Ctrl+V: smart paste (C-04). Ctrl+Alt+V: literal ^V (T-16). Ctrl+Shift+V: paste (C-05). — `electron/ui/app.js:856-879` — ✅ audited
- [x] **K-30** File-browser keys (F-20…F-31) apply only while the file browser itself has focus and no Ctrl/Meta/Alt is held. — `electron/ui/files-widget.js:992-994` — ✅ audited
- [x] **K-31** Zoom: Ctrl+0 resets zoom, Ctrl+= / Ctrl+Shift+= zoom in, Ctrl+- zooms out. Zoom scales the whole host page, terminal font included, and the width rule follows. These reach the menu because xterm leaves them unhandled. Ctrl+R (reload) and F11 (full screen) are consumed by the terminal when it has focus. — `electron/main.js:1466-1473` `[implicit]` `[inferred]` — ✅ deviation 24, ruling A-15
- [x] **K-32** Shortcut hints in tooltips and help text show the Linux bindings on Linux: header buttons `New terminal in a new column (Ctrl+Shift+Enter)`, `New file browser in a new column (Ctrl+Shift+B)`, `Settings (Ctrl+,)`, `Manage connections (Ctrl+Shift+O)`, pill suffix `(Ctrl+N)`, connection-page Log button `Connection log (Ctrl+Shift+G)`, and the connection-page hint paragraph. — `electron/header.html:152-165`, `electron/connect.html:184-188`, `electron/connect.html:167-178` — ✅ audited (header tooltips by reading)

---

## 6. File browser (Miller columns)

### Identity and persistence

- [x] **F-01** A file-browser pane has the client-only id `files-<base36 of epoch ms><random 0–9999>` and needs no server session. It moves around the strip like any pane. — `electron/ui/files-widget.js:53-58` — ✅ audited
- [x] **F-02** Per-pane state `{type:'files', dir, cursor}` (initially `dir:'~'`, `cursor:null`) is persisted per host (same scope as L-41) under the key `webmux-widgets` as `{<id>: state}`, after every render. It is removed when the pane closes and pruned at startup for ids not in the layout (S-05). — `electron/ui/files-widget.js:47-71`, `electron/ui/files-widget.js:799` — ✅ audited
- [x] **F-03** On first open, list `state.dir` and learn the host's home directory (the `path` returned by listing `~`, unless it is `/`) at the same time. If the listing fails (e.g. the directory was deleted), clear the cursor and list `~`. Then set `dir` to the absolute path the server returned. — `electron/ui/files-widget.js:1095-1113`, `electron/ui/files-widget.js:89-100` — ✅ deviation 28

### Columns and rows

- [x] **F-04** Columns show the chain from `/` down to `dir`, one listing per level, plus one extra column for the cursor entry: the listing of that directory if it is a directory, the preview if it is a file, nothing if there is no cursor. — `electron/ui/files-widget.js:766-806` — ✅ audited
- [x] **F-05** In each ancestor column the entry on the path is highlighted with `rgba(255,255,255,0.1)` (light `rgba(0,0,0,0.07)`). In the cursor's column the cursor row is highlighted with `rgba(122,162,247,0.3)` and white text (light `rgba(46,125,233,0.28)` / `#1b2140`). Row hover background `rgba(255,255,255,0.05)`. — `electron/ui/index.html:361-373`, `electron/ui/files-widget.js:486` — ✅ audited
- [x] **F-06** Rows: 12.5px UI font, padding 2px 10px, no wrap, ellipsised names. Dot-files are drawn at 55% opacity, symlinks in italics, directories with a trailing `›` at 50% opacity. Symlinks to directories count as directories; broken links are files. — `electron/ui/index.html:361-391`, `electron/ui/files-widget.js:483-516`, `host/internal/server/fs.go:100-112` — ✅ audited
- [x] **F-07** Order is as served: directories first, then case-insensitive, accent-folded name order. — `host/internal/server/fs.go:114-120` — ✅ audited
- [x] **F-08** Each listing column is as wide as its longest name measured in the row font plus 72px of row chrome, clamped to 200–420px. The default is 200px. Columns are separated by a 1px border and scroll vertically on their own. — `electron/ui/files-widget.js:454-467`, `electron/ui/index.html:352-360` — ✅ audited
- [x] **F-09** Messages inside a column, in italic at 50% opacity: `(empty)`, `(list truncated)` (more than 2000 entries), or the server's error code (e.g. `EACCES`, `ENOENT`). — `electron/ui/files-widget.js:475-482`, `electron/ui/files-widget.js:526`, `electron/ui/index.html:415` — ✅ audited
- [x] **F-10** The selected row (cursor row only) shows two small buttons, ✎ `Rename (r)` and ✕ `Delete (d)`, at 55% opacity (100% on hover). — `electron/ui/files-widget.js:492-510`, `electron/ui/index.html:392-403` — ✅ audited
- [x] **F-11** Clicking a row moves the cursor there (dir = that column's directory), leaves drilled mode and focuses the browser. — `electron/ui/files-widget.js:517-523` — ✅ audited
- [x] **F-12** Listing cache with a 4000 ms TTL per directory, so keyboard navigation does not refetch. Watch events, focus refresh and mutations invalidate it. — `electron/ui/files-widget.js:305-326` — ✅ audited
- [x] **F-13** Cursor memory: for each directory visited in this pane's lifetime (not persisted), remember which entry the cursor was on. Entering that directory again re-selects it, otherwise the first entry. — `electron/ui/files-widget.js:312-314`, `electron/ui/files-widget.js:1044-1047` — ✅ audited

### Pane title

- [x] **F-14** The pane title is the path to the selection (`dir/cursor`, or `dir` with no cursor), with the home directory shown as `~`. — `electron/ui/files-widget.js:1086`, `electron/ui/files-widget.js:98-100` — ✅ audited
- [x] **F-15** The title is fitted to the label width, measured in the focused bar's bold (600) weight: interior directories collapse into `…` next to the anchor (`~` or root) one at a time, then the anchor goes (`…/name`), then only the name is left, which then ellipsises. Example: `~/src/webmux/electron/ui/app.js → ~/…/electron/ui/app.js → ~/…/ui/app.js → ~/…/app.js → …/app.js → app.js`. The full path is the tooltip. It refits on every render and every label resize. — `electron/ui/files-widget.js:109-127`, `electron/ui/files-widget.js:975-990` — ✅ audited

### Keyboard

- [x] **F-20** ↑/k and ↓/j move the cursor within its directory, clamped (no wrap). With no cursor, ↓ selects the first entry and ↑ the last. — `electron/ui/files-widget.js:1021-1031` — ✅ audited
- [x] **F-21** →/l/Enter on a directory enters it (F-13 picks the cursor). On a file it drills into the preview (F-40) if the preview has content (not the narrow stat-only column). — `electron/ui/files-widget.js:1032-1048` — ✅ audited
- [x] **F-22** ←/h goes to the parent with the cursor on the directory just left. No-op at `/`. — `electron/ui/files-widget.js:1049-1054` — ✅ audited
- [x] **F-23** r or F2 starts an inline rename of the cursor entry (F-50). — `electron/ui/files-widget.js:1055-1058` — ✅ audited
- [x] **F-24** d, Delete or Backspace deletes the cursor entry after confirmation (F-52). — `electron/ui/files-widget.js:1059-1062` — ✅ ruling A-17
- [x] **F-25** Shift+D downloads the cursor file (F-55). On a directory it shows the toast `select a file to download`. — `electron/ui/files-widget.js:1063-1070` — ✅ audited
- [x] **F-26** Keys with Ctrl, Meta or Alt held are ignored by the browser, so the pane chords pass through. — `electron/ui/files-widget.js:993` — ✅ audited

### Preview

- [x] **F-30** The preview column is 600px wide (fits 80 columns of the 11.5px mono preview font). For files with nothing to show but the header (binary, socket/other, stat error) it is 280px ("narrow"). Width changes ease over 180 ms. A new preview starts at the width the previous one had and settles once the stat arrives. — `electron/ui/index.html:441-448`, `electron/ui/files-widget.js:698-744` — ✅ audited
- [x] **F-31** Preview header: file name (bold, breaks anywhere), then a meta line at 60% opacity: `<size> · [<N> entry/entries ·] <local date-time of mtime>`. Size format: `N B` under 1024, otherwise KB/MB/GB/TB with one decimal below 10 and none above (`1.5 KB`, `12 MB`). — `electron/ui/files-widget.js:557-571`, `electron/ui/files-widget.js:195-202` — ✅ deviation 28
- [x] **F-32** For every kind except `other`, the header has a ⤓ download button (tooltip `Download (D)`). Clicking it downloads the file (F-55) and keeps keyboard focus on the columns. — `electron/ui/files-widget.js:573-586` — ✅ audited
- [x] **F-33** Image preview (png jpg jpeg gif webp bmp svg ico avif) loads the bytes from `/api/fs/raw` and shows them scaled down to the column width. — `electron/ui/files-widget.js:596-600`, `host/internal/server/fs.go:34-38` — ✅ deviation 33
- [x] **F-34** Text preview shows the first 64 KiB in the terminal font at 11.5px, line height 1.45, unwrapped (horizontal scroll), with `(empty file)` for an empty file and `(preview truncated)` below when cut. A NUL byte in the first 64 KiB makes the file binary instead. — `electron/ui/files-widget.js:590-595`, `electron/ui/index.html:501-513`, `host/internal/server/fs.go:310-333` — ✅ audited
- [x] **F-35** Markdown (`.md .markdown .mdown .mkd`, case-insensitive) renders by default with GitHub-flavoured markdown. A Rendered / Source segmented toggle sits in the preview header. The choice is remembered for the life of the pane (not persisted), so stepping to the next `.md` keeps it, and a new pane starts on Rendered. If rendering is unavailable or the file is empty, show the source view. — `electron/ui/files-widget.js:548-551`, `electron/ui/files-widget.js:601-633`, `electron/ui/files-widget.js:87` — ✅ audited
- [x] **F-36** Markdown safety: raw HTML in the source is shown as literal text (block HTML as a paragraph). Scripts, styles, iframes, objects, embeds, links, metas and all `on*` attributes are removed. Task-list checkboxes are shown disabled. — `electron/ui/files-widget.js:159-193` — ✅ audited
- [x] **F-37** Markdown images with relative or absolute paths (no scheme) load through `/api/fs/raw`, resolved against the file's directory. — `electron/ui/files-widget.js:187-190`, `electron/ui/files-widget.js:146-157` — ✅ deviation 29
- [x] **F-38** Markdown links: http(s) behave as terminal links (click opens, Shift+click copies, T-24). `mailto:` opens the open/copy chooser (M-04). `#anchors` do nothing. Relative links navigate the browser to that entry (dir = its parent, cursor = it). Anything else shows the toast `can't open <href>`. — `electron/ui/files-widget.js:634-650` — ✅ audited
- [x] **F-39** Markdown typography: 13px UI font, line height 1.5. Headings at 1.5/1.3/1.15/1em (h1 and h2 underlined by a 1px border). Code in the terminal font at 11.5px; inline code on `rgba(255,255,255,0.1)` with radius 3px; code blocks on `rgba(0,0,0,0.4)` with radius 4px. Blockquote with a 3px left border at 80% opacity. Bordered tables. Links in the accent colour, underlined on hover. — `electron/ui/index.html:529-578` — ✅ deviation 43
- [x] **F-40** Zip-family files (zip jar war ear whl egg epub xpi apk ipa nupkg vsix docx xlsx pptx odt ods odp, at least 22 bytes) show their table of contents as a `tree`-style listing: `├── ` / `└── ` connectors and `│   ` indents, folders first then names (case-insensitive), folders with a trailing `/` at 70% opacity, files with their uncompressed size right-aligned. `(empty archive)` and `(list truncated)` (cap 2000 entries) as needed. A file that turns out not to be a zip falls back to the text/binary sniff. — `electron/ui/files-widget.js:653-687`, `electron/ui/files-widget.js:129-144`, `host/internal/server/fs.go:288-309` — ✅ audited
- [x] **F-41** Binary files show `binary file`, other non-regular files show `no preview`, a stat error shows its code, a pending preview shows `…`, a failed fetch shows `preview failed`. — `electron/ui/files-widget.js:688-692`, `electron/ui/files-widget.js:720`, `electron/ui/files-widget.js:742` — ✅ audited
- [x] **F-42** A re-render of the same file (watch event, focus refresh) keeps the preview's scroll position. Previews from a superseded render are discarded. — `electron/ui/files-widget.js:715-738` — ✅ deviation 54: confirmed by the final check (`gtk/audit/final-check.md`)

### Drilled preview

- [x] **F-43** Drilling in (→/l/Enter on a file, or clicking a wide preview anywhere other than its links/buttons) moves the selection highlight from the cursor row to the preview header. The row drops to the on-path look. The strip scrolls so the whole preview column is visible. — `electron/ui/files-widget.js:746-760`, `electron/ui/files-widget.js:721-726`, `electron/ui/index.html:374-383` — ✅ audited
- [x] **F-44** While drilled: ↑/k and ↓/j scroll the preview by 48px. PageUp/PageDown/Space scroll by 90% of its height. Home/End go to top/bottom. ←/h/Escape leave drilled mode. →/l/Enter do nothing. r, d, D… still act on the cursor file. — `electron/ui/files-widget.js:995-1020`, `electron/ui/files-widget.js:762` — ✅ audited
- [x] **F-45** Moving the cursor anywhere else, or the preview turning out narrow, leaves drilled mode. — `electron/ui/files-widget.js:777`, `electron/ui/files-widget.js:739` — ✅ audited

### Mutations

- [x] **F-50** Rename: the cursor row's name becomes an inline text field (accent 1px border, radius 3px) with the stem preselected (everything before the last `.`; the whole name for dot-files or names without an extension). Enter commits; Escape or losing focus cancels. Typed keys never trigger navigation. On commit with a non-empty name (trimmed) that differs, `POST /api/fs/rename`, put the cursor on the new name and show the toast `renamed <old> → <new>`. On error show `rename failed: <error>`. Focus returns to the columns. — `electron/ui/files-widget.js:388-427`, `electron/ui/index.html:404-414` — ✅ audited
- [x] **F-51** No watch- or focus-triggered re-render happens while a rename field is open. — `electron/ui/files-widget.js:936`, `electron/ui/files-widget.js:952` — ✅ audited
- [x] **F-52** Delete confirmation is a modal centred over the file-browser pane only (the rest of the layout stays usable underneath), with the text `Delete folder “<name>” and everything in it?` for directories or `Delete “<name>”?` for files, and buttons Cancel and Delete. Delete is red `#c34f5e` with white bold text and has initial focus. Escape or a click on the backdrop cancels. — `electron/ui/files-widget.js:242-278`, `electron/ui/files-widget.js:363-373`, `electron/ui/index.html:524-528,614-620` — ✅ audited
- [x] **F-53** After a confirmed delete, `POST /api/fs/delete` (recursive on the host), show the toast `deleted <name>`, and move the cursor to the entry that took its index (else the new last entry). On error show `delete failed: <error>`. The host refuses `/` and `$HOME`. — `electron/ui/files-widget.js:374-386`, `host/internal/server/fs.go:402-423` — ✅ audited
- [~] **F-54** Upload by drag-and-drop of local files or folders. Dropped on a listing column, the files go to that column's directory. Dropped on the preview column, they go to the previewed file's directory. Dropped elsewhere in the browser, they go to the rightmost directory shown (the cursor directory if it is a directory, else the cursor's directory). Folders upload recursively under their relative paths, and empty subdirectories are skipped. Only file drags are accepted; text drags fall through. While a valid drag hovers a target, it shows a 2px inset accent ring and an accent wash `rgba(122,162,247,0.07)`. — `electron/ui/files-widget.js:204-240`, `electron/ui/files-widget.js:429-452`, `electron/ui/files-widget.js:962`, `electron/ui/index.html:437-440` — 👁 by reading only (real drag and drop not possible headlessly)
- [x] **F-55** Download: fetch `/api/fs/raw?path=<p>&download=1`, show the toast `downloading <name>`, and save through a native save dialog. The dialog opens in the folder this profile last saved to (per profile, `downloadDir`, only if it still exists), with the file name prefilled. After a completed save, record that folder for the profile; cancelled or interrupted saves change nothing. Log `download started` `{file, bytes}`, then `download saved` `{file, path}` or `download cancelled` / `download interrupted` `{file}`, under the host's name. — `electron/ui/files-widget.js:530-546`, `electron/main.js:1321-1350`, `electron/main.js:436-444` — ✅ audited
- [x] **F-56** Paste into the browser: files or images on the clipboard, pasted while the browser has focus, upload into the rightmost directory shown. Pasted text is ignored. — `electron/ui/files-widget.js:964-973` — ✅ audited
- [x] **F-57** Uploads run one file at a time with `POST /api/fs/upload?dir=<d>&name=<relative name or "pasted">` and the raw bytes as the body (200 MiB limit per file). Show the toast `uploading <N> file(s)…`, then `uploaded <N> file(s) → <dir>`, and stop at the first failure with `upload failed: <error>`. An empty drop shows `nothing to upload`. Afterwards the cursor's directory becomes the target and the cursor lands on the top-level entry of the last upload. Collisions are renamed Finder-style by the host (`name (1).ext`). — `electron/ui/files-widget.js:335-359`, `host/internal/server/fs.go:337-398` — ✅ audited
- [~] **F-58** A file dropped anywhere else in the window (outside a browser drop zone) does nothing. In particular it never replaces the page. — `electron/ui/app.js:1670-1674` `[electron-artifact]`: the outcome is "stray drops are inert". — 👁 by reading only (real drag and drop not possible headlessly)

### Live listings, refresh, animation, lifecycle

- [x] **F-59** Live listings: keep one `/api/fs/watch` event stream open for the cursor's directory and one for the directory under the cursor, never for directories whose listing failed. On `change`, drop that directory from the cache and re-render 50 ms later (coalescing bursts). On `gone`, close that stream and re-render. When a stream reconnects after a drop (the tunnel blinked), treat it as a change. Streams for directories no longer shown are closed. — `electron/ui/files-widget.js:903-939` — ✅ audited
- [x] **F-60** Closing a file-browser pane closes all its watch streams, drops its state and runs the pane-removal animation. No server call. — `electron/ui/files-widget.js:1089-1094`, `electron/ui/app.js:1353-1383` — ✅ audited
- [x] **F-61** Focus refresh: when the pane gains focus from outside itself, or the window regains focus while the pane holds focus, drop cache entries older than 1 s and re-render every column shown (ancestors included). — `electron/ui/files-widget.js:941-960` — ✅ audited
- [x] **F-62** Column transitions: surviving columns are reused and keep their scroll. New columns grow in from zero width while fading in (180 ms ease-out). Removed columns collapse to zero width while fading out (180 ms ease-in). A column replaced in the same slot by a same-kind column (cursor moved to a sibling folder) swaps instantly with a 140 ms fade-in. Preview content fades in over 140 ms. The first render of a pane appears without motion. — `electron/ui/files-widget.js:808-854`, `electron/ui/index.html:416-432` — ✅ audited
- [x] **F-63** Horizontal follow: after each render, ease the browser's horizontal scroll (25% of the remaining distance per frame, settling exactly at 300 ms) so the rightmost column sits at the right edge, without pushing the cursor's column off the left edge, unless drilled, in which case the whole preview shows. The first render jumps there instantly. A wheel gesture cancels the easing. — `electron/ui/files-widget.js:856-888`, `electron/ui/files-widget.js:801-805` — ✅ audited
- [x] **F-64** The cursor row is kept vertically in view within its column (nearest-edge scroll, vertical only). — `electron/ui/files-widget.js:890-901` — ✅ audited
- [x] **F-65** Re-attaching after a layout change restores the scrolled-to-the-right view. — `electron/ui/files-widget.js:1097-1101` — ✅ audited

---

## 7. Connections: profiles, passwords, ssh, supervision

### Profiles

- [x] **X-01** Profiles are stored in `<config dir>/config.json` as `{profiles:[…], lastProfile, settings}`, pretty-printed with 2-space indent and a trailing newline. Each profile has `name, host, sshPort (0 = ssh default), identityFile, instance ('' = default), localPort (0 = auto), extraOptions, passwordEnc, downloadDir`. — `electron/main.js:54-125` — ✅ deviation 1, 3, 7, 48: confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **X-02** Migrations on load: drop `remotePort`, `autoDeploy`, `savedPort`. A non-absolute `remoteSocket` becomes `instance` (an absolute one becomes default). The legacy single-host shape `{host, localPort, sshOptions[]}` becomes one profile named after the host with `extraOptions` = the options joined by spaces, and is saved at once. An unreadable file (anything but "not found") is reported on stderr and treated as empty. — `electron/main.js:82-120`, `electron/test/harness.js:115-125` — ✅ ruling N-13, deviation 38
- [x] **X-03** Save validation, in this order: trim `name`, `host`, `instance`. `instance` must be blank or match `^[A-Za-z0-9._-]+$`, else the error `instance name must be blank (default) or letters, digits, . _ -`. `sshPort` and `localPort` are coerced with `Number(x) || 0`. Blank `name` or `host` gives `name and host are required`. A name that collides with another profile gives `a profile named "<name>" already exists`. — `electron/main.js:994-1021`, `electron/test/harness.js:164-178` — ✅ deviation 39: confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **X-04** The connection form also trims `identityFile` and `extraOptions` client-side. `extraOptions` is split on whitespace into separate ssh arguments (no quoting support). — `electron/connect.html:344-354`, `electron/main.js:189` — ✅ audited
- [x] **X-05** Rename (saving under a new name): the profile keeps its saved password and `downloadDir`. `lastProfile` follows the rename. A live connection is renamed in place and keeps its pill position, its Ctrl+N slot, its local port and its active state. — `electron/main.js:1029-1044`, `electron/test/harness.js:180-187,442-451` — ✅ audited
- [x] **X-06** Saving a profile that has a live connection does not touch the running tunnel. The new fields apply on the next connect or reconnect. — `electron/main.js:1025-1028` — ✅ audited
- [x] **X-07** Delete removes the profile, clears `lastProfile` if it was that profile, and disconnects it if connected. — `electron/main.js:1049-1055` — ✅ audited
- [x] **X-08** `lastProfile` is set to the profile on every connect. It is stored but nothing auto-connects at startup. — `electron/main.js:549-552`, `electron/main.js:1541-1542` — ✅ audited

### Passwords

- [x] **X-09** An optional saved password per profile is stored only encrypted by the OS keyring (libsecret: GNOME Keyring or KWallet on Linux; Keychain on macOS), as base64 ciphertext in `passwordEnc`. The plaintext and the ciphertext are never shown in the UI; the UI knows only `hasPassword`. — `electron/main.js:1008-1018`, `electron/main.js:986-992` — ✅ deviation 3, 22
- [x] **X-10** Editing rules: a blank password field keeps the stored one, a non-blank one replaces it, and the "clear saved" checkbox removes it. If encryption is unavailable, saving a password fails with `OS keychain encryption is unavailable — cannot store a password`. — `electron/main.js:1008-1018`, `electron/test/harness.js:189-218` — ✅ deviation 37
- [x] **X-11** At ssh spawn time the password is decrypted into the child's environment only (`WEBMUX_SSH_PASSWORD`) and supplied by an askpass helper (`<config dir>/askpass.sh`, mode 0700, `printf '%s' "$WEBMUX_SSH_PASSWORD"`) with `SSH_ASKPASS=<helper>` and `SSH_ASKPASS_REQUIRE=force`. The same helper answers passphrase prompts for encrypted keys. — `electron/main.js:154-163`, `electron/main.js:193-203` — ✅ deviation 9
- [x] **X-12** If decryption fails (keyring refused, or ciphertext from another machine), the connection goes to `failed` with the message `saved password could not be decrypted — edit the profile and re-enter it` and the error in the diagnostics, and does not retry. — `electron/main.js:575-587` — ✅ audited
- [~] **X-13** The startup log line records which keyring backend was selected (`passwordStore`), so a plaintext fallback such as `basic_text` is visible. — `electron/main.js:1515-1517` — 👁 by reading only (backend name not observable headlessly)

### ssh command lines

- [x] **X-14** Base ssh options for every ssh this client runs for a profile (tunnel, deploy steps, restart sessions), in this order: with a saved password `-o NumberOfPasswordPrompts=1`, otherwise `-o BatchMode=yes`; then `-o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectTimeout=10`; then `-p <sshPort>` if set, `-i <identityFile>` if set, then the extra options. The host is the profile's `host` string, passed verbatim (ssh config aliases work). — `electron/main.js:165-191` — ✅ audited
- [x] **X-15** Tunnel: `ssh -N -o ExitOnForwardFailure=yes <base options> -L 127.0.0.1:<localPort>:<remote socket path> <host>`, stdin and stdout discarded, stderr captured. The remote socket path comes from the deploy step's advert (D-07). — `electron/main.js:205-213`, `electron/main.js:759-765` — ✅ deviation 1
- [x] **X-16** Local port: a pinned `localPort` wins. Otherwise reuse the port this profile got earlier in this app run, else pick any free port by binding `127.0.0.1:0`. The pick is not persisted. It stays stable for the run so a tunnel that comes back on the same port heals the live page without a reload. — `electron/main.js:215-235`, `electron/test/harness.js:369-378` — ✅ deviation 1, 9

### Supervision state machine

- [x] **X-17** States: `connecting`, `connected`, `retry`, `failed`, plus the derived `degraded` (`connected` while the host page reports link down, S-12). Each state change is logged as `state <prev> → <next>` (error level for failed, warn for retry, info otherwise) with `{msg}`. Status carries `{state, msg, delay?, stderr}`, where `stderr` is the last 8 diagnostic lines joined by newlines. — `electron/main.js:380-413`, `electron/main.js:468` — ✅ audited
- [x] **X-18** Connect (from the UI): if the profile is already connected with a live tunnel, just show it. Otherwise create or reuse the connection, mark it to be revealed when the server first answers, kill whatever is in flight, reset "has connected" to false, set `lastProfile`, pick the port, reset the retry delay, log `connect requested` with `{host, instance, localPort, sshPort?, identityFile?, extraOptions?, auth: 'password'|'key'}` (never the password), and start. — `electron/main.js:1057-1071`, `electron/main.js:546-565` — ✅ deviation 8, 36
- [x] **X-19** Each attempt clears the diagnostics, goes to `connecting` with `ssh <host>`, runs the deploy flow (§8), then spawns the tunnel with the advertised socket, then probes (X-24). Cancel or Disconnect at any point kills whichever ssh child is in flight, and later steps of the dead attempt are ignored. — `electron/main.js:567-592`, `electron/main.js:698-757`, `electron/main.js:517-532` — ✅ audited
- [x] **X-20** Tunnel or deploy failure on an attempt that never reached `connected` in this connect cycle: go to `failed` with `ssh exited (<code or signal>)` (or `connection failed`) and stay there, with no background retry. If this host page is on screen and its page never loaded, switch to the connection page. — `electron/main.js:793-805`, `electron/main.js:446-452`, `electron/test/harness.js:220-236` — ✅ audited
- [x] **X-21** Failure after the cycle had reached `connected` at least once: go to `retry` with the failure message and `delay` in whole seconds, and try again after `min(max(prev × 2, 1000), 15000)` ms (1 s, 2 s, 4 s, 8 s, 15 s, 15 s …). Log `interrupted — retry in <s>s` (warn) and `retrying` when the retry fires. Every retry runs the full deploy flow again (D-01…). Retries continue until the user acts. A live host page stays on screen and heals itself. — `electron/main.js:807-822` — ✅ audited
- [x] **X-22** Restart Sessions (connection page ⋯ menu): run a one-off ssh with the base options and a 30 s timeout that shuts down the profile's remote pty host (kills every shell). It tries this client's shipped payload binaries, then any `~/.webmux/dist/payload/*/webmux-host` newest first, then a legacy node `ptyhost.js`. If every one reports not-running, it kills this user's pty-host processes for the instance with `pgrep`. Result messages: `sessions restarted — all shells were stopped, fresh ones start on demand`, `an old session host did not answer the shutdown and was killed — fresh sessions start on demand`, `no sessions were running — nothing to restart`, `webmux has never been deployed to this host`, or `ssh exited (<code>)[ — <last 2 stderr lines>]`. It works while disconnected. The instance is re-validated first (`invalid instance name in profile`). — `electron/main.js:899-973`, `electron/main.js:1073-1098` — ✅ audited
- [x] **X-23** Disconnect (pill ✕, card Disconnect/Cancel, profile deletion): kill everything in flight, drop the connection and its page, and switch to the connection page if it was showing. Remote sessions keep running. — `electron/main.js:534-544` — ✅ audited

### Liveness probing

- [x] **X-24** For as long as a tunnel child lives, probe `GET http://127.0.0.1:<localPort>/` with a 2000 ms timeout. Any HTTP response counts as an answer. Before the first answer, probe every 500 ms. If 20000 ms pass without one, give up with `server did not answer through the tunnel`. — `electron/main.js:824-882` — ✅ audited
- [x] **X-25** On an answer: reset the miss counter and the retry delay to 0, mark "has connected", go to `connected` (broadcast only on change), load the host page if it is not loaded, or reload it if its last load failed, and reveal it if this connect asked to (X-18). Then probe every 5000 ms. — `electron/main.js:850-864`, `electron/main.js:884-897` — ✅ audited
- [x] **X-26** While connected, three consecutive misses (timeout or error) give up with `server unreachable through the tunnel — reconnecting`, log each miss as `probe missed (<n>/3)` (warn), and log `probe: server answering again` when one gets through after misses. Giving up kills the tunnel, adds the reason to the diagnostics and sets the retry delay so the next attempt runs after 1 s (X-21). — `electron/main.js:844-849`, `electron/main.js:866-879` — ✅ audited
- [x] **X-27** Resume from system sleep: kill every live tunnel at once with the retry delay reset, so reconnection starts now instead of after the keepalive timeout. Log `system resumed from sleep` `{tunnelsKilled}` and `killing pre-sleep tunnel to reconnect now` per host. — `electron/main.js:1528-1539` — ✅ audited
- [x] **X-28** Reveal-on-connect is cancelled by any explicit navigation (pill click, Ctrl+N, Ctrl+PageUp/PageDown, Connections), so a host that finishes connecting later never yanks the view away. — `electron/main.js:330-336` — ✅ audited
- [x] **X-29** While a host page is loaded, tunnel blips are not view switches: the page's own socket retries heal it, and failures of a background host only recolour its pill. — `electron/main.js:446-452`, `docs/electron-client.md:183-185` — ✅ audited
- [x] **X-30** Reconnect (Ctrl+Shift+R, menu): re-read the visible host's profile from the store and run a fresh connect cycle (logged as `reconnect requested`). The cycle starts not-yet-connected, so a reconnect that fails parks in `failed`. With no host visible, show the connection page. — `electron/main.js:975-980` — ✅ audited
- [~] **X-31** If a host page fails to load (main frame, anything but an aborted load), log `app page failed to load` `{code, desc}`, mark it for reload on the next successful probe, and switch to the connection page if it was showing. — `electron/main.js:502-509` `[electron-artifact]` for the mechanism; the outcome is "a host whose UI cannot come up shows the connection page, not an error page". — 👁 by reading only
- [x] **X-32** Hidden host pages keep running at full speed: their sockets, retries and title updates continue in the background, so switching back is instant. — `electron/main.js:300-308` — ✅ deviation 4

### macOS Local Network privacy `[mac-only]`

- [-] **X-40** `[mac-only]` Before the first ssh of the app run to a LAN target (`.local` names; IPv4 10/8, 172.16/12, 192.168/16, 169.254/16; IPv6 fe80::/10 and fc00::/7, including IPv4-mapped), skipping ProxyJump/ProxyCommand/`-J` profiles: make one TCP connect to host:port (3000 ms timeout) from the client process, with the status `checking local network access…`. If it is denied (EHOSTUNREACH, or a failed lookup for `.local`), re-probe every 1000 ms for up to 20000 ms with the status `waiting for macOS Local Network permission — allow webmux in the prompt…`. — `electron/main.js:594-639`, `electron/lan.js:28-108` — n/a (macOS only, N-12)
- [-] **X-41** `[mac-only]` If ssh stderr contains `No route to host` or `Undefined error: 0`, the failure message is the Local Network hint (`electron/lan.js:30-32`). The parked connection re-probes every 2000 ms for up to 180000 ms and reconnects by itself on success. — `electron/main.js:643-677`, `electron/main.js:803` — n/a (macOS only, N-12)

---

## 8. Deploy (connecting is deploying)

- [x] **D-01** Every connect attempt, retries included, runs the deploy flow before the tunnel. Each step is one `ssh <base options> <host> '<command>'`. Composite commands are wrapped as `exec sh -c '<script>'` and stick to POSIX sh, double quotes and `$HOME`, so csh/fish login shells do not break them. Every child can be cancelled (X-19). — `electron/deploy.js:31-46`, `electron/main.js:698-727` — ✅ audited
- [x] **D-02** Probe (status `probing host…`): run `echo "@@os $(uname -s)"; echo "@@cpu $(uname -m)"; (ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo "@@musl yes" || echo "@@musl no"; for f in $HOME/.webmux/dist/payload/*/PAYLOAD_HASH; do [ -f "$f" ] && echo "@@payload $f"; done; true`. Parse only lines that start with `@@`, so login-shell noise is ignored. Payload hashes are the directory names. With no os or cpu, fail with `host probe failed — no uname output (unusual remote shell?)`. — `electron/deploy.js:95-117`, `electron/test/deploy-fake.js:146-160` — ✅ audited
- [x] **D-03** Platform: Linux with `x86_64`/`amd64` maps to `linux-x64`, Linux with `aarch64`/`arm64` to `linux-arm64`, on glibc and musl alike. Anything else fails with `unsupported host platform '<os> <cpu>[ (musl)]' — supported targets: Linux x86_64, Linux aarch64`. — `electron/platforms.js:19-37`, `electron/deploy.js:184-188` — ✅ audited
- [x] **D-04** Payload selection: the client ships `payload/payload.json` (`{platforms:{<key>:{hash, bytes}}, builtAt}`) and `payload/<key>/payload.tar.gz`. A missing manifest, or a missing or malformed (not 64 hex) hash for the platform, fails with `this client build has no <key> payload — run \`node deploy/build-payload.js\` (needs host/dist/webmux-host-<key>) and restart the app`, and only after the probe ran, so ssh failures surface as such. — `electron/deploy.js:189-194`, `electron/main.js:679-689`, `electron/main.js:731-741` — ✅ audited
- [x] **D-05** Push: only if the probe did not list the hash. Stream the tarball to `rm -rf $HOME/.webmux/dist/payload/.tmp-<hash> && mkdir -p … && tar xzf - -C <tmp> && rm -rf $HOME/.webmux/dist/payload/<hash> && mv <tmp> $HOME/.webmux/dist/payload/<hash>`, so it is atomic. The status is `pushing webmux… <pct>% of <MB with 1 decimal> MB`, updated on each whole-percent change. A missing local tarball fails with `payload tarball missing: <path>`. — `electron/deploy.js:124-131`, `electron/deploy.js:55-89`, `electron/deploy.js:197-202` — ✅ audited
- [x] **D-06** Start (status `starting server…`): `exec sh -c 'exec $HOME/.webmux/dist/payload/<hash>/webmux-host start --name <instance>'`, with `default` for a blank instance. The result is the last stdout line that parses as a JSON object: `{ok:true, action:'reuse'|'started', advert:{socket, payloadHash, protocol, pid, startedAt}}`, or `{ok:false, error, logTail}`. The starter waits up to 200 × 150 ms for the new server. — `electron/deploy.js:137-171`, `host/internal/start/start.go:13-19`, `host/internal/start/start.go:72-73` — ✅ audited
- [x] **D-07** Start failures: on `ok:false`, add each `logTail` line to the diagnostics and fail with `server start failed: <error>`. A non-zero exit with no parseable result fails with `server start failed: ssh exited (<code>)`. Exit 0 with no result fails with `webmux-host start produced no result — see diagnostics`. On success, tunnel to `advert.socket`. — `electron/deploy.js:147-171`, `electron/test/deploy-fake.js:205-211` — ✅ audited
- [x] **D-08** Every deploy step's stderr lines go to the diagnostics (last 8 kept) and to the log as `ssh: <line>` (warn). Each step's progress is logged once as `deploy: <msg>` (percentage updates collapse onto their step). The result is logged as `deploy done: server <action>` with `{ms, platform, payload: <first 12 hash chars>, socket, pid}`, and failures as `deploy failed` `{ms, error}`. Each ssh child is logged at debug level (`deploy step: ssh` `{pid, command: first 120 chars}`, `deploy step: ssh exited` `{pid, code, signal}`). — `electron/main.js:698-757` — ✅ audited
- [x] **D-09** The deploy flow never stops a running pty host, so sessions survive a deploy. Old payload directories are never deleted. — `docs/push-deploy.md:36-44,66-67` — ✅ audited

---

## 9. Window chrome

### Window and views

- [x] **W-01** One main window, initially 1400×900, titled `webmux`. Its background is `#16161e` in the dark theme and `#dfe1e8` in light, following theme changes, so resizing never flashes the wrong colour. — `electron/main.js:1360-1371`, `electron/main.js:1229-1232`, `electron/main.js:1246` — ✅ audited
- [x] **W-02** Layout: a 38px header strip across the top, with exactly one content view below it: the connection page or one host's page. — `electron/main.js:237-243`, `electron/main.js:318-328` — ✅ audited — native: the header is a standard header bar, about 47px (deviation 66)
- [x] **W-03** Window title: `webmux — <H> host(s) · <P> pane(s)` with singular/plural forms (`1 host`, `2 hosts`, `1 pane`), where P counts every pane, file browsers included, across all connected hosts. With no connections the title is `webmux`. It updates live. — `electron/main.js:367-378`, `electron/ui/app.js:194-203`, `electron/test/harness.js:387-388,524` — ✅ audited
- [x] **W-04** Startup always shows the connection page. Nothing connects automatically. — `electron/main.js:1541-1542`, `electron/test/harness.js:127-132` — ✅ audited — native: startup opens the Connections page of the dialog over the landing view (deviation 67)
- [~] **W-05** Keyboard focus always belongs to the visible content view. Switching views focuses the newly shown one. Clicking anywhere on the header (pills, buttons, empty space) hands keyboard focus straight back to the content view, while the click or drag itself still completes. — `electron/main.js:347-356`, `electron/main.js:1386-1390` — ⚠ partly: menu focus confirmed for terminals and the file browser by the final check (`gtk/audit/final-check.md`); the text-field case it found was fixed in round 3 and reproduced fixed by the lead with real input, not independently re-checked
- [x] **W-06** Closing the main window quits the app. On quit, every tunnel and deploy step is killed (remote sessions survive), with the log line `client quitting` `{connections}`. There is no quit confirmation. — `electron/main.js:1545-1551` — ✅ audited
- [x] **W-07** No accelerator closes the window by accident (no Ctrl+W/⌘W window close; that key is close-pane). — `electron/main.js:1482-1483` — ✅ audited

### Header strip

- [x] **W-10** Layout: three tracks, `1fr | auto | 1fr`, so the pills are centred in the window. Left: `+ New terminal` (filled accent `#7aa2f7`, dark text `#10101a`, bold, radius 6px, padding 5×11px) and `+ Files` (outlined `#34344a`, 80% opacity, hover accent). Right: `⚙` (round outline, 14px) and `Connections` (round outline pill). Background `#1f1f2b`, 1px bottom border `#34344a`, 12.5px system UI font, 10px side padding, 6px gaps, nothing selectable. — `electron/header.html:7-135`, `electron/header.html:138-146` — ✅ audited — native: superseded by deviation 66 (standard GNOME header bar; user's direction 2026-11-05)
- [x] **W-11** One pill per connected host, in connection order: a status dot (8px), the profile name and a ✕. Pills are rounded (999px), 1px border, padding 4/6/4/11px, at 70% opacity, 100% with a `rgba(255,255,255,0.05)` background on hover. The pill row scrolls horizontally with no visible scrollbar when it overflows. — `electron/header.html:73-92`, `electron/header.html:177-184` — ✅ audited: fixed in round 2, confirmed by the final check (`gtk/audit/final-check.md`)
- [x] **W-12** Dot colours: connecting `#e0af68` pulsing (opacity dips to 0.3 at mid-cycle, 1.2 s, ease-in-out, infinite); connected `#9ece6a`; degraded `#e0af68` steady; retry and failed `#f7768e`; unknown `#555`. Light theme: yellow `#8c6c3e`, danger `#c8283f`. — `electron/header.html:93-98`, `electron/header.html:18-21,35-38` — ✅ audited
- [x] **W-13** The active pill (the host on screen) has full opacity, border `rgba(224,175,104,0.6)`, background `rgba(224,175,104,0.12)` and text `#e0af68`. — `electron/header.html:87-92` — ✅ audited
- [x] **W-14** Pill tooltip: `<name> — <state text>` plus ` (Ctrl+<n>)` for the first nine. State texts: `connecting…`, `connected`, `server unreachable — page retrying` (degraded), `interrupted — retrying in <s>s` (or without the delay), `connection failed`. — `electron/header.html:169-184` — ✅ deviation 23
- [x] **W-15** Clicking a pill shows that host. The pill's ✕ (hidden, 55% opacity while the pill is hovered, red on hover, tooltip `Disconnect`) disconnects it. — `electron/header.html:99-114`, `electron/header.html:193-198` — ✅ audited (hover by reading)
- [x] **W-16** Pills can be dragged to reorder. The dragged pill fades to 30%. A 3px accent bar marks the insertion point, chosen by the pointer's x against the other pills' midpoints (gaps and the trailing edge count). On drop the order changes optimistically and becomes the new pill order, Ctrl+1…9 order and cycling order. Unknown or duplicate names in a reorder request are dropped, and connections missing from it keep their relative order at the end. — `electron/header.html:200-247`, `electron/main.js:1104-1117`, `electron/test/harness.js:396-406` — ✅ audited
- [x] **W-17** `Connections` is highlighted (accent border `rgba(122,162,247,0.7)`, tint `rgba(122,162,247,0.12)`, accent text) while the connection page is showing. `+ New terminal`, `+ Files` and `⚙` are disabled (30% opacity) while it is showing. — `electron/header.html:127-134`, `electron/header.html:185-190` — ✅ audited — native: highlight is a plain tint, buttons use the standard disabled look (deviation 66) — native: with no host in front (deviation 67)
- [x] **W-18** Header buttons act on the visible host page: `+ New terminal` runs new-terminal, `+ Files` runs new-files, `⚙` opens settings, and keyboard focus returns to the page. A command with no live host page on screen is a no-op. — `electron/header.html:249-252`, `electron/main.js:1134-1193`, `electron/test/harness.js:389-390` — ✅ audited
- [~] **W-19** The header shows nothing a remote server controls: the list of other hosts and the switching UI live in the client, never in host-supplied content. — `electron/main.js:4-8` `[electron-artifact]`: this is a privilege-separation rule; natively it means "nothing in the host protocol can enumerate or switch hosts". — 👁 by reading only

### Connection manager page

- [x] **W-20** Centred column, max width 620px, 48px/24px padding, 14px system font. Title `webmux` (18px, 600). Top-right buttons `Log` (opens the log window) and `New Profile` (primary). Background `#1e1e1e`; light `#dfe1e8`. — `electron/connect.html:6-69`, `electron/connect.html:154-160` — ✅ audited — native: the Connections page of the preferences dialog, libadwaita's look (deviation 67)
- [x] **W-21** One card per profile (background `#252525`, 1px border `#363636`, radius 8px). A card shows a status dot and a state label (`connecting…`, `connected`, `degraded`, `retrying…`, `failed`) when the profile has a connection, the name in bold, and a monospace detail line `<host>[ -p <port>][ → <instance>]` (ellipsised). A card with a tunnel up (connected or degraded) has the primary-colour border. — `electron/connect.html:90-103`, `electron/connect.html:215-286` — ✅ audited: fixed in round 2, confirmed by the final check (`gtk/audit/final-check.md`) — native: an `AdwActionRow` per profile, no border state (deviation 67)
- [x] **W-22** Connection-page dot colours (different from the header): connecting `#d9a334` pulsing, retry and failed `#c75450`, connected `#55a868`, degraded `#d9a334`, none `#555`. — `electron/connect.html:71-77` — ✅ audited — native: the dots use the header's colours, W-12 (deviation 67)
- [x] **W-23** Card buttons: `Edit`; then, by state, `Disconnect` + `Show` (primary) when connected or degraded, `Cancel` when connecting or retrying, otherwise `Connect` (primary); then `⋯`. `Show` and `Connect` both call connect (X-18). — `electron/connect.html:232-248` — ✅ audited — native: no `Edit` or `⋯`; a click on the row edits (deviation 67)
- [x] **W-24** The `⋯` menu (min width 190px, shadow) has `Restart Sessions…` and `Delete Profile…` (red). Each confirms in place: the first click relabels it `Sure? This kills every shell` / `Sure? Removes the profile`, and the second click acts. A click outside the menu or Escape closes it and clears pending confirmations. Status pushes rebuild the menu in place without closing it. — `electron/connect.html:105-117`, `electron/connect.html:250-263`, `electron/connect.html:404-437` — ✅ audited — native: Restart Sessions and Delete Profile are on the profile subpage and ask in an alert dialog (deviation 67)
- [x] **W-25** Restart Sessions shows the notice `<name>: restarting sessions…`, then `<name>: <result message or error>` (X-22). Notices clear after 8000 ms. — `electron/connect.html:208-213`, `electron/connect.html:410-418` — ✅ audited
- [x] **W-26** Empty list text: `No profiles yet — create one to connect.` — `electron/connect.html:267-270` — ✅ audited
- [x] **W-27** Profile form (replaces the list while open; the first field takes focus). Fields with labels and placeholders: `Profile name` (`devbox`); `Host (anything ssh accepts)` (`me@devbox.example.com`); `SSH port (opt.)` (`22`, 130px); `Identity file (opt.)` (`~/.ssh/id_ed25519`); `Password (opt. — stored encrypted in the …)`, a masked field without autocomplete, placeholder `saved — leave blank to keep` if a password is stored, else `blank = key auth (recommended)`; a `clear saved` checkbox only if one is stored. Under a collapsed `Advanced` section: `Instance name (blank = default — separate instances have separate sessions)` (`default`), `Local port (0 = auto)` (`0`), `Extra ssh options` (`-o ProxyJump=bastion`). Inputs use a 13px monospace font with an accent border on focus. Zero ports show as empty. — `electron/connect.html:288-340` — ✅ deviation 1, ruling A-05 — native: a subpage of `AdwEntryRow`s with no placeholders; the examples are in group descriptions, the password hint in its row title (deviation 67)
- [x] **W-28** Form actions: `Save & Connect` for a new profile (saves, then connects), `Save` when editing, and `Cancel`. Validation errors appear inline in red next to the buttons, and the form stays open. Escape cancels the form when no menu is open. — `electron/connect.html:331-361`, `electron/connect.html:433-437` — ✅ audited — native: `Save` in the subpage's header bar, errors above the fields (deviation 67)
- [x] **W-29** Live status pushes never rebuild an open form, so typing is never lost. While the form is open only the status area updates. — `electron/connect.html:439-442` — ✅ audited
- [x] **W-30** Status detail below the list, one block per connection that is `connecting`, `degraded`, `retry` or `failed`: dot + name heading, the status message, and then by state — degraded: `The tunnel is up but the page's session sockets are down and retrying — the server may be restarting. The client reconnects on its own if the server stops answering.`; retry: `Connection interrupted — retrying in <s>s… (sessions keep running on the server)`; failed: `Not retrying automatically — hit Connect to try again. The connection log (Log button above) has the full sequence.`; then the diagnostics tail in a monospace box (max height 140px, scrolls, wraps). Healthy connections show no block. — `electron/connect.html:363-385`, `electron/connect.html:140-148` — ✅ deviation 23
- [x] **W-31** Help paragraph at the bottom (Linux wording): the host needs only ssh; connecting pushes the server to `~/.webmux/dist` and starts it; updates are pushed the same way and sessions survive them; several hosts can be connected at once, each with a pill (`Ctrl+1…9 or Ctrl+PageUp/PageDown switch, Ctrl+Shift+O returns here`); key auth needs no prompt (use ssh-agent for passphrases) or save a password, stored encrypted via `the OS keyring (GNOME Keyring or KWallet via libsecret)` and fed to ssh through an askpass helper; `Ctrl+Shift+R` reconnects the current host. — `electron/connect.html:167-178` — ✅ ruling A-05 — native: wording says Ctrl+Shift+O opens this page (deviation 67)
- [x] **W-32** The connection page, header and log window follow the colour scheme live (W-20 palette and the light palette `electron/connect.html:32-55`). — `electron/connect.html:190-193`, `electron/header.html:254-257` — ✅ audited — native: libadwaita follows the scheme (deviation 67)

### Menus

- [x] **W-40** Application menu on Linux: hidden menu bar. A lone Alt tap (press and release with no other key) shows it, and Esc or another tap hides it again. Chords containing Alt do not toggle it. — `electron/main.js:1366-1371`, `README.md:110-111` `[implicit]` (Electron `autoHideMenuBar` behaviour) — ✅ ruling N-16
- [x] **W-41** `webmux` menu: About; `Connections…` (Ctrl+Shift+O); `Reconnect` (Ctrl+Shift+R); `Open Config File` (opens `config.json` in the default app); `Connection Log…` (Ctrl+Shift+G); `Settings…` (Ctrl+,); Quit. macOS adds `Hide webmux`, `Hide Others` and `Show All` without their ⌘H / ⌥⌘H accelerators, which are pane chords. — `electron/main.js:1433-1461` — ✅ audited
- [~] **W-42** Edit menu: Undo, Redo, Cut, Copy, Paste, Paste and Match Style (macOS), Delete, Select All, the standard roles (Linux accelerators Ctrl+Z … Ctrl+A). In a terminal, Copy copies the selection and Paste pastes (C-06). — `electron/main.js:1462` `[implicit]` — ⚠ partly: Edit items act on the focused terminal, confirmed by the final check (`gtk/audit/final-check.md`); Edit › Paste into a text field replaced the field, fixed in round 3, not independently re-checked
- [x] **W-43** View menu: Reload (host page reload, S-13), Toggle Developer Tools, Reset Zoom / Zoom In / Zoom Out (K-31), Toggle Full Screen. — `electron/main.js:1463-1475` (devtools is `[electron-artifact]`) — ✅ ruling A-15, N-11
- [x] **W-44** Pane menu: every pane command with its shortcut shown (Linux strings): New Terminal (Ctrl+Shift+Return), New Terminal Below (Alt+Ctrl+Shift+Return), New File Browser (Ctrl+Shift+B), Close Pane (Ctrl+Shift+W), Full Window (Ctrl+Shift+F), separator, Focus Left/Right/Up/Down (Ctrl+Shift+arrows), separator, Expel or Merge Left/Right (Ctrl+Shift+[ / ]), separator, Move Column Left/Right, Move Pane Up/Down (Alt+Ctrl+Shift+arrows). Clicking an item runs the command on the visible host page. The shortcut itself is handled by the page (K-01…K-15), never twice. — `electron/main.js:1140-1177`, `electron/main.js:1476-1481` — ✅ deviation 25
- [x] **W-45** Window menu: Minimize (Zoom on macOS only); separator; `Previous Host` (Ctrl+PageUp) and `Next Host` (Ctrl+PageDown); separator; `Host 1` … `Host 9` (Ctrl+1 … Ctrl+9). There is no window-close item. — `electron/main.js:1484-1505` — ✅ audited (Minimize by reading)

---

## 10. Settings

- [x] **E-01** `theme`: `dark` (label `Dark mode default`) or `light` (label `Light mode`). Default `dark`. An unknown id renders as dark. — `electron/ui/settings.js:12-50`, `electron/ui/settings.js:75` — ✅ audited
- [x] **E-02** `unfocusedFade`: integer 0–100, default 40, rounded and clamped. Drives L-24. — `electron/ui/settings.js:63-64` — ✅ audited
- [x] **E-03** `minCols` (minimum terminal width, in columns): integer 40–400, default 90. — `electron/ui/settings.js:65-66` — ✅ audited
- [x] **E-04** `maxCols` (maximum terminal width): integer 40–400, default 200, and never below `minCols`. Whichever one moved, a max below the min is raised to the min, so raising the min lifts the max with it. — `electron/ui/settings.js:67-69`, `electron/test/harness.js:150-153` — ✅ audited
- [x] **E-05** Storage: client-wide, in `config.json` under `settings`, shared by every host. Unknown keys are dropped. Malformed values keep the current value (on write) or the default (on load). — `electron/main.js:129-152`, `electron/main.js:1293-1304`, `electron/test/harness.js:134-162` — ✅ audited
- [x] **E-06** Propagation: a change made on any host page applies there at once, is saved, and is pushed to every other host page, the header, the connection page, the log window and the main window background. Re-applying is idempotent. A host page's own change is not echoed back as a new write. — `electron/main.js:1239-1254`, `electron/ui/settings.js:138-140` — ✅ audited
- [x] **E-07** Startup never waits on settings: if they cannot be read, defaults apply. The theme is applied before any pane paints. — `electron/ui/settings.js:119-126`, `electron/ui/app.js:1714-1726` — ✅ audited
- [x] **E-10** Settings panel: a modal (460px, `min(460px, 90vw)`) opened by `⚙`, Ctrl+, or the menu, only on a visible host page. Only one instance at a time. Heading `Settings`, lead `Apply to every host on this client.`, then rows separated by 1px borders. Esc, a backdrop click or `Done` (primary) closes it, and focus returns to the focused pane. The colour scheme select takes initial focus. — `electron/ui/app.js:603-717`, `electron/ui/index.html:642-688` — ✅ deviation 32 — native: the General page of the preferences dialog; no Done, the dialog's close button instead (deviation 67); no backdrop click (deviation 68)
- [x] **E-11** Row `Color scheme`: a select of the themes. Changing it applies and saves at once. — `electron/ui/app.js:615-618`, `electron/ui/app.js:691` — ✅ audited — native: `AdwComboRow` (deviation 67)
- [x] **E-12** Row `Unfocused pane fade`: a range slider 0–100 in steps of 5 (170px wide) with a live `N%` readout. Dragging previews live without saving; release saves. Description: `How much panes other than the focused one dim. 0% leaves them untouched.` — `electron/ui/app.js:619-626`, `electron/ui/app.js:692-696` — ✅ deviation 27
- [x] **E-13** Rows `Minimum terminal width` and `Maximum terminal width`: number inputs 40–400, step 1, 6 characters wide, with the unit `columns`. Changes are committed on change (enter or blur), and both fields then show the clamped values (one may move the other). A field being edited is not overwritten by pushes from other hosts. Descriptions: `No column is narrower than this. As many columns as fit at this width share the window exactly; open more and the layout scrolls sideways.` / `No column is wider than this. Fewer columns than fit the window grow to share it up to this width and sit centred.` — `electron/ui/app.js:627-642`, `electron/ui/app.js:663-669`, `electron/ui/app.js:697-708` — ✅ audited — native: `AdwSpinRow`, the unit is in the row title (deviation 67)
- [x] **E-14** Row `Connection log`: an `Open log…` button opens the log window (G-20). Description: `Tunnel setup, teardown, and reconnect events for every host on this client, live and copyable. Also written to a file on disk.` — `electron/ui/app.js:643-647`, `electron/ui/app.js:710-712` — ✅ audited
- [x] **E-15** The panel follows pushes from other host pages while open. — `electron/ui/app.js:671` — ✅ audited

---

## 11. Connection log

### Entries and sinks

- [x] **G-01** Entry shape: `{seq, t, level, src, conn, msg, data}`. `seq` is a monotonically increasing integer per app run. `t` is an ISO-8601 timestamp. `level` is one of `debug|info|warn|error`; anything else becomes `info`. `src` is `main` or `page`. `conn` is the profile name (clipped to 80 chars) or null for app-wide events. `msg` is clipped to 500 chars. — `electron/log.js:93-112` — ✅ audited
- [x] **G-02** `data` sanitising: at most the first 12 keys, and only keys matching `^[A-Za-z_]\w{0,31}$`. Strings longer than 300 chars are clipped with `…`. Numbers, booleans and null are kept. Anything else is JSON-encoded and clipped the same way. Empty data becomes absent. — `electron/log.js:75-91`, `electron/test/harness.js:311-328` — ✅ audited
- [x] **G-03** In-memory ring of the last 3000 entries. — `electron/log.js:15`, `electron/log.js:105-106` — ✅ audited
- [x] **G-04** File sink `<config dir>/logs/webmux.log`, append-only, one line per entry: `<iso> <LEVEL padded to 5> [<conn>] page: <msg> k=v …` (the `[conn] ` part only when conn is set; `page: ` only for page entries). Values: undefined is `-`; numbers, booleans and null are printed bare; strings matching `^[\w./:@~-]+$` are printed bare and all other strings JSON-quoted; objects as JSON. — `electron/log.js:42-57`, `electron/test/harness.js:294-296` — ✅ audited
- [x] **G-05** Rotation: before a write, if the file is already larger than 1 MiB, rename it to `webmux.log.1` (replacing any older one) and start a new file. Disk errors never affect the client. — `electron/log.js:59-73` — ✅ audited
- [x] **G-06** Secrets never appear in the log: no password, no ssh environment. Only the auth mode is logged. — `electron/log.js:8-10`, `electron/main.js:555-563`, `electron/test/harness.js:290-292` — ✅ audited
- [x] **G-07** Events logged by the supervisor, with the exact message strings: `client started` `{version, electron, platform, passwordStore, logFile}`; `<why> requested`; `state A → B`; `pending retry cancelled (<why>)`; `deploy step killed (<why>)`; `tunnel killed (<why>)`; `disconnecting (<why>)` (why ∈ disconnect, user, profile deleted, quit, connect, reconnect); `saved password could not be decrypted`; deploy events (D-08); `tunnel spawned` `{pid, localPort, remoteSock, cmd: full ssh command line}`; `tunnel spawn error`; `tunnel exited[ (superseded)]` `{pid, code, signal, uptimeMs}` (warn, or info when superseded or quitting); `interrupted — retry in <s>s`; `retrying`; probe events (X-24…X-26); `loading app page` / `reloading app page` `{url}`; `page reports its session sockets are down (degraded)` (warn) / `page reports its session sockets are back`; `app page failed to load`; `restart sessions requested` `{instance}`; `restart sessions: <msg>`; `reloading app page after session restart`; download events (F-55); sleep and resume events (X-27); `client quitting`; `log cleared (file untouched)`. — `electron/main.js` (lines cited per item above) — ✅ deviation 34
- [x] **G-08** Events logged from the host pages (src `page`, tagged with the host): `session socket connecting` / `session socket reconnecting` (debug, `{session, attempt}`); `session socket open` / `session socket reopened` (info, `{session, attempt, ms}`); `snapshot received` (debug, `{session, bytes}`); `session exited` (info, `{session, exitCode}`); `session gone on the host — closing its tab` (warn); `session socket closed (tab closed or session exited)` (debug, `{session, code}`); `session socket dropped — retrying` / `session socket connect failed — retrying` (warn, `{session, code, reason, clean, upMs, retryInMs}`); link down/up (S-12); `session list fetch failed` (error); `page attached` (info). — `electron/ui/app.js:908-982`, `electron/ui/app.js:200-210`, `electron/ui/app.js:1620-1628` — ✅ audited
- [x] **G-09** Page events are batched (flushed 100 ms after the first queued one, at most 50 per batch) and survive a page reload that happens right after them. Batches are capped at 50 entries on receipt. — `electron/ui/log.js:12-39`, `electron/main.js:1256-1282` `[electron-artifact]`: `POST /log` on the `webmux://` origin is how a sandboxed page reaches main. Natively the events are direct calls; only the event set and the tagging matter. — ✅ audited

### Log window

- [x] **G-20** One log window (900×560, titled `webmux — connection log`, themed), opened by Ctrl+Shift+G, the menu, the connection page's `Log` button or the settings panel. Opening it again focuses the existing one. After it is closed, a new one can be opened. — `electron/main.js:1399-1431`, `electron/test/harness.js:336-363` — ✅ audited
- [x] **G-21** On open, load every entry in the ring, then append new entries live as they are logged. Entries whose `seq` is not newer than the last one seen are ignored (dedupe the initial-load race). — `electron/logs.html:263-269`, `electron/logs.html:316-323`, `electron/main.js:1123-1125` — ✅ audited
- [x] **G-22** Toolbar: `Host` select (`all`, then one option per host seen, in order of first appearance, and `client (no host)` for app-wide entries); `Level` select (`debug+`, `info+` (the default), `warn+`, `error`); text filter (placeholder `filter text…`, 200px wide, case-insensitive substring of the file-format line, applied 80 ms after typing stops); `follow` checkbox (on by default, tooltip `Keep the newest entry in view`); `Copy visible` (primary, tooltip `Copy the lines currently shown (Ctrl+Shift+C)`); `Copy all` (tooltip `Copy every entry in memory, ignoring the filters`); `Reveal file`; `Clear` (tooltip `Empty the in-memory log (the file is kept)`). — `electron/logs.html:141-158`, `electron/logs.html:181-189`, `electron/logs.html:302-307` — ✅ audited
- [x] **G-23** Line rendering (12px monospace, line height 1.45, wrapped): local time `HH:MM:SS.mmm` (24 h) muted; level in bold, 5 characters wide; `[conn]` in the accent colour, or `[conn] page` in green `#9ece6a` for page entries; message; data as `k=v` muted. Debug lines are dimmed `#6a6f87`, warn level and message `#e0af68`, error `#f7768e`, info level muted. A tooltip shows the full ISO timestamp. While a text filter is active, matching lines are highlighted with `rgba(224,175,104,0.18)`. Hovering a line gives it a background. The text is selectable. — `electron/logs.html:89-117`, `electron/logs.html:191-208` — ✅ audited
- [x] **G-24** Follow semantics: scrolling more than 4px away from the bottom unticks follow; scrolling back to the bottom reticks it. While follow is on, every new entry scrolls to the end. — `electron/logs.html:244-251` — ✅ audited
- [x] **G-25** Copy visible / Copy all put the file-format lines on the clipboard, newline-joined with a trailing newline, and flash `copied <N> visible line(s)` / `copied <N> line(s)` in the status bar for 2000 ms. Ctrl+Shift+C (⌘⇧C) runs Copy visible. — `electron/logs.html:271-294`, `electron/logs.html:309-314` — ✅ audited
- [x] **G-26** Reveal file shows the log file in the system file manager. Clear empties the ring (not the file), leaving one marker entry `log cleared (file untouched)`, and empties the window. — `electron/logs.html:295-300`, `electron/main.js:1126-1130`, `electron/log.js:126-129` — ✅ audited
- [x] **G-27** Status bar: `<N> entries`, or `<shown> of <N> entries` while filtered; the copy flash; and the log file path (monospace, ellipsised, full path in the tooltip). Empty states: `No log entries yet.` / `Nothing matches the current filters.` — `electron/logs.html:125-137`, `electron/logs.html:159-165`, `electron/logs.html:210-237` — ✅ audited
- [x] **G-28** Keys in the log window: Escape closes it, Ctrl+F focuses and selects the text filter, Ctrl+Shift+C copies the visible lines. The app shortcuts (K-20…K-26) work there too. — `electron/logs.html:309-314`, `electron/main.js:1429` — ✅ audited
- [~] **G-29** No host page can read the log (it names other hosts). Host content may only ask for the window to open. — `electron/main.js:1256-1291` `[electron-artifact]`: privilege separation again; natively, no host-protocol path reads the log. — 👁 by reading only

---

## 12. Status messages and modals

- [x] **M-01** Toast: one at a time, bottom-right, 18px from both edges, max width `min(640px, 100vw − 36px)`. Accent background `#7aa2f7`, text `#10101a`, radius 10px, padding 13px 20px, 15px semibold, line height 1.3, a large soft shadow plus a 1px ring. It rises 10px and fades in over 0.18 s, does not take the pointer, and hides 3000 ms after the last message (a new message replaces the text and restarts the timer). Toasts are per host page. — `electron/ui/index.html:154-177`, `electron/ui/app.js:465-474` — ✅ audited
- [x] **M-02** Every toast string in the client: `clipboard set from terminal`, `clipboard write blocked by the browser`, `link copied`, `clipboard image synced to sessions`, `uploading pasted image…`, `image paste failed: <e>`, `image in clipboard — Ctrl+V forwarded to Claude`, `pasted image → <path>`, `no clipboard API on http origin — pastes rely on native paste events here` (electron-artifact), `clipboard access blocked — allow it in the browser, or right-click → paste` (reword natively), `uploading <N> file(s)…`, `uploaded <N> file(s) → <dir>`, `upload failed: <e>`, `nothing to upload`, `deleted <name>`, `delete failed: <e>`, `renamed <a> → <b>`, `rename failed: <e>`, `downloading <name>`, `select a file to download`, `can't open <href>`, `the log window is part of the Electron client — see the browser console here` (electron-artifact). — `electron/ui/app.js`, `electron/ui/files-widget.js` (sites cited in the items above) — ✅ audited
- [x] **M-03** Modal look: a full-window dim of `rgba(0,0,0,0.55)` (light `rgba(40,44,70,0.35)`), centred panel (`#1f1f2b`, 1px border, radius 10px, padding 16px 18px, max width `min(560px, 90vw)`, shadow). Buttons are outlined (radius 6px, 13px, hover accent). The primary button is accent-filled and bold. The danger button is `#c34f5e`. Actions are right-aligned with 8px gaps. While a modal is open the pane chords are disabled (K-18). — `electron/ui/index.html:579-631` — ✅ audited — native: libadwaita's dialogs, no Electron palette (deviation 68)
- [x] **M-04** Link chooser (open-url, `mailto:` in markdown): the URL in 12.5px monospace, accent-coloured, breaking anywhere, max height 30% of the viewport with scrolling. Buttons `Cancel`, `Copy` (copies and shows the toast `link copied`) and `Open in browser` (primary, initial focus, opens in the system browser). Escape or a backdrop click cancels. Closing returns keyboard focus to the pane it came from. — `electron/ui/app.js:555-601`, `electron/ui/index.html:632-641` — ✅ audited — native: `AdwAlertDialog`, no backdrop click (deviation 68)
- [x] **M-05** Delete confirmation modal: F-52. Settings modal: E-10. — `electron/ui/files-widget.js:242-278`, `electron/ui/app.js:603-717` — ✅ audited
- [x] **M-06** The in-terminal status lines are part of this surface too: `[disconnected — reconnecting…]` in yellow (T-35) and `[session exited: N]` in red (T-37). — `electron/ui/app.js:940`, `electron/ui/app.js:967` — ✅ audited

---

## 13. Wire protocol (client ↔ `webmux-host serve`)

All traffic goes over the ssh forward to `http://127.0.0.1:<localPort>`, as
plain HTTP/1.1 and WebSocket. The server listens only on a unix socket on
the host. There is no auth and no TLS: ssh and the socket's 0600
permissions are the access control.

### HTTP

- [x] **P-01** `GET /` returns 200 `{"ok":true,"server":"webmux","payloadHash":<hash|"dev">,"ptyhost":<instance>}`. This is the liveness probe (X-24). — `host/internal/server/http.go:274-279` — ✅ audited
- [x] **P-02** `GET /api/sessions` returns 200 `[{id, cols, rows, title, createdAt (epoch ms), clients (attached count), pid}…]` in creation order, or 502 `{"error"}` if the pty host is unreachable. — `host/internal/server/http.go:281-294`, `host/internal/ptyhost/session.go:358-370` — ✅ audited
- [x] **P-03** `POST /api/sessions` with body `{cols, rows}` (falsy values default to 80×24; clamped to 2–500 × 2–300) returns 201 `{"id":<uuid>}`, or 502 `{"error"}`. A JSON `null` body gives 500. — `host/internal/server/http.go:296-322`, `host/internal/ptyhost/ptyhost.go:440-457` — ✅ audited
- [x] **P-04** `DELETE /api/sessions/<id>` (URI-decoded) sends SIGHUP to the session's shell and returns 200 `{"ok":true}`. 404 `{"error":"not found"}` for an unknown id, 502 `{"error":…}` if the host is unreachable or the id is malformed (`URI malformed`). The session's attached sockets then get `exit`. — `host/internal/server/http.go:324-345`, `host/internal/ptyhost/ptyhost.go:458-470` — ✅ audited
- [x] **P-05** File-system paths in every fs route: empty, missing or `~` means `$HOME`; `~/x` means `$HOME/x`; an absolute path is cleaned; anything else is relative to the server's cwd (the payload dir). There is no sandboxing. — `host/internal/server/fs.go:40-67` — ✅ audited
- [x] **P-06** `GET /api/fs/list?path=` returns 200 `{"path":<absolute>,"entries":[{"name","type":"dir"|"file","symlink"?:true}],"truncated":bool}` (at most 2000 entries, directories first, then base-collation order), or 400 `{"error":<errno code, e.g. "ENOENT","EACCES","ENOTDIR">}`. — `host/internal/server/fs.go:81-127` — ✅ audited
- [x] **P-07** `GET /api/fs/preview?path=` returns 200 `{size, mtime (fractional epoch ms), kind, …}` where kind is `other` (not a regular file), `image` (by extension), `zip` (plus `entries:[{name,size,dir}]` capped at 2000, `count`, `truncated`), `binary` (a NUL in the first 64 KiB) or `text` (plus `content` (the first 64 KiB, invalid UTF-8 as U+FFFD) and `truncated`). Errors: 400 `{"error":<code>}`. — `host/internal/server/fs.go:269-335` — ✅ audited
- [x] **P-08** `GET /api/fs/raw?path=[&download=1]` returns 200 with the full file (no Range support), `Content-Type` set to the image MIME by extension or `application/octet-stream`, and `Content-Length`. With `download=1` it adds `Content-Disposition: attachment; filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded name>`. 400 `{"error":"not a file"}` for directories and other non-regular files, or 400 `{"error":<code>}`. — `host/internal/server/fs.go:452-502` — ✅ audited
- [x] **P-09** `POST /api/fs/upload?dir=&name=` takes the raw body (≤ 200 MiB, else 413 `{"error":"payload too large"}` and the connection closes). `name` may contain `/`; empty and `.` segments are dropped, and a `..` segment gives 400 `{"error":"invalid name"}`. Intermediate directories are created. Only the basename is deduped (`stem (n).ext`). Returns 200 `{"name":<relative path as written>}`. — `host/internal/server/fs.go:357-398`, `host/internal/server/http.go:21-24,70-84` — ✅ audited
- [x] **P-10** `POST /api/fs/delete` with `{path}` deletes recursively and returns 200 `{"ok":true}`. 400 `{"error":"refusing to delete that"}` for `/` or `$HOME`; 400 `{"error":<code>}` otherwise (e.g. `ENOENT`). — `host/internal/server/fs.go:402-423` — ✅ audited
- [x] **P-11** `POST /api/fs/rename` with `{path, name}` returns 200 `{"ok":true,"name":<name>}`. 400 `{"error":"invalid name"}` (empty, `.`, `..` or containing `/`); 400 `{"error":"name already taken"}`; 400 `{"error":<code>}`. The rename stays within the entry's directory. — `host/internal/server/fs.go:425-450` — ✅ audited
- [x] **P-12** `GET /api/fs/watch?path=` is a `text/event-stream`. Events are `ready` on start, `change` on any create/remove/rename/write of a direct child (coalesced over 100 ms), and `gone` (then the stream ends) if the directory cannot be watched or vanishes. Each event's data is `{"path":<dir>[,"error":<code>]}`. A `: ping` comment every 25 s keeps the tunnel from idling. The client must reconnect on its own after a network drop (EventSource semantics) and handle `gone` as F-59 describes. — `host/internal/server/watch.go:12-102` — ✅ audited
- [x] **P-13** `POST /api/paste` with `{mime, data:base64}` returns 200 `{"path"}` (writes a paste file). The client does not currently call it. — `host/internal/server/paste.go:108-130` — ✅ audited
- [x] **P-14** Common rules: JSON bodies are capped at 30 MiB (413). Invalid JSON gives 400 `{"error":"invalid JSON body"}`. An unknown route gives 404 `{"error":"not found"}`. A handler panic gives 500 `{"error"}`. Every response carries `Access-Control-Allow-Origin: *`; `OPTIONS` returns 204 with allowed methods `GET, POST, DELETE, OPTIONS`, allowed header `Content-Type` and max age 600 `[electron-artifact]` (a native client needs no CORS). Keep-alive idle timeout 5 s. — `host/internal/server/http.go:21-29`, `host/internal/server/http.go:107-120`, `host/internal/server/http.go:190-257`, `host/internal/server/server.go:169-173` — ✅ audited

### WebSocket `/ws?session=<id>`

- [x] **P-20** Upgrade on `/ws` only; any other path gets 400. No origin check, no compression. Max message 100 MiB. One text frame per JSON message. — `host/internal/server/ws.go:154-165`, `host/internal/server/http.go:209-218` — ✅ audited
- [x] **P-21** Server → client, the first frame after attach: `{"type":"snapshot","data":<VT byte string>,"cols":N,"rows":N,"title":<string>,"pid":<shell pid>}`. `data` reproduces the screen, the scrollback (5000 lines), the modes, cursor, pen, hyperlink, scrolling region and kitty keyboard flags. On the alternate screen it is the primary screen plus scrollback, then `ESC[?1049h ESC[H ESC[0m ESC]8;; ESC\`, then the alternate screen. The client must apply it to a fully reset terminal. — `host/internal/ptyhost/session.go:291-313`, `host/internal/ptyhost/snapshot.go:10-98` — ✅ audited
- [x] **P-22** Server → client streaming frames: `{"type":"output","data":<string>}`, raw pty output decoded as UTF-8 with split sequences held back until complete. `{"type":"title","title"}` when this session's title changes (OSC 0/2). `{"type":"session-title","session","title"}` for any session's title change, sent on every open socket. `{"type":"exit","exitCode":N}`, after which the server closes the socket with code 1000. — `host/internal/ptyhost/session.go:260-289`, `host/internal/ptyhost/session.go:372-394`, `host/internal/server/server.go:273-322` — ✅ audited
- [x] **P-23** Server → client on an unknown session: `{"type":"error","message":"no such session"}`, then the socket closes. If the server cannot reach the pty host, the socket closes with no frames (the client just retries, T-35). — `host/internal/ptyhost/ptyhost.go:483-491`, `host/internal/server/ws.go:173-207` — ✅ audited
- [x] **P-24** Server → client: `{"type":"paste-result","mode":"claude"}` or `{"type":"paste-result","mode":"path","path":<file>}` after a `paste-image`. `{"type":"open-url","url":<http(s) url>,"id":"open-<ms>-<seq>"}` when a shim in a session asks for a browser: sent to that session's sockets, or broadcast to every socket if the session is unknown or not attached. — `host/internal/server/ws.go:284-305`, `host/internal/server/paste.go:132-186` — ✅ audited
- [x] **P-25** Client → server: `{"type":"input","data":<string>}`; `{"type":"resize","cols":int,"rows":int}` (non-integers ignored; clamped 2–500 × 2–300; resizes the host mirror and the pty); `{"type":"paste-image","mime","data":base64}`; `{"type":"clipboard-sync","mime","data":base64}`. Malformed or unknown messages are ignored. — `host/internal/server/ws.go:229-282`, `host/internal/ptyhost/ptyhost.go:345-360`, `host/internal/ptyhost/session.go:328-341` — ✅ audited
- [x] **P-26** Host side of `paste-image`: write the image to the clipboard slot (`<pasteDir>/clipboard` and `clipboard.mime`). If the session's foreground process looks like Claude Code (argv[0] or argv[1] basename starts with `claude`, via `/proc/<pid>/stat` tpgid), type `\x16` into the session. Otherwise write `<pasteDir>/paste-<ms>-<seq>.<ext>` and type `'<path>' ` (single-quoted, trailing space). `clipboard-sync` only writes the slot. — `host/internal/server/ws.go:284-305`, `host/internal/server/paste.go:47-106` — ✅ audited
- [~] **P-27** A client that falls 4096 frames behind is disconnected by the pty host. The client recovers through the normal reconnect and snapshot path (T-35, T-33). — `host/internal/ptyhost/client.go:10-14` — 👁 by reading only (slow-consumer disconnect could not be provoked)

---

## 14. Host shims: what they expect from a client

- [x] **H-01** Sessions run with `TERM=xterm-256color`. `TMUX`, `TMUX_PANE` and a tmux `TERM_PROGRAM` are removed. `DISPLAY` is faked as `:0`. `PATH` is prefixed with the shims dir. `WEBMUX_SESSION`, `WEBMUX_CLIPBOARD_DIR` and `BROWSER` are set. The client terminal must therefore behave like an xterm-256color terminal, including OSC 52 and the `Ms` capability tmux relies on (C-01). — `host/internal/ptyhost/session.go:54-108`, `README.md:376-412` — ✅ audited
- [x] **H-02** `xdg-open`, `sensible-browser`, `x-www-browser` and `$BROWSER` with an http(s) URL spool it to the server, which sends `open-url`. The client must show the chooser (C-11, M-04). Non-http URLs exit with status 4 and never reach the client. — `shims/xdg-open:1-21`, `shims/sensible-browser`, `shims/x-www-browser` — ✅ audited
- [x] **H-03** `xclip -o` / `xsel -o` inside a session serve the clipboard slot that only the client fills (C-07, C-09), so Claude Code's image paste depends on the client syncing clipboard images. Clipboard writes through the shims are swallowed. They do not reach the client; OSC 52 is the only copy-out path. — `shims/xclip:1-37`, `shims/xsel:1-10` — ✅ audited

---

## Ambiguities

Places where the intent is unclear, or the docs and the code disagree. The
lead needs to rule on each.

- **A-01** The app.js header comment says the shift variants and ⌥ do different things ("⇧⌘ to move a pane within its stack, out of it into a column of its own, or its whole column, ⌥⌘ to merge it…; on Linux the chord key is Alt and Ctrl stands in for ⌥"). The code does what README and §5 say (Ctrl+Shift chord, Alt secondary). The comment is stale; the checklist follows the code. — `electron/ui/app.js:9-14` vs `electron/ui/app.js:1550-1590` → ruled: follow the code (the comment is stale).
- **A-02** The log shortcut in the docs is `⌘⇧L` (`README.md:295`, `docs/electron-client.md:217`, and "⌘⇧L … now ⌃⌘L" at `README.md:274-276`). The code is ⌃⌘L on macOS and Ctrl+Shift+G on Linux. The checklist follows the code. — `electron/main.js:1446` → ruled: follow the code (the docs are stale).
- **A-03** Linux has no keyboard shortcut for copying a terminal selection to CLIPBOARD. Ctrl+C is the pty's ^C, Edit › Copy's accelerator is Ctrl+C (which xterm consumes), and Ctrl+Shift+C is unbound. Copy works only via the menu bar (Alt tap → Edit → Copy) and PRIMARY selection [inferred]. Decide whether the native client adds Ctrl+Shift+C (the usual Linux terminal binding; it is not a pane chord) — I recommend yes. → ruled: add Ctrl+Shift+C to copy the terminal selection (not a pane chord).
- **A-04** `README.md:108` says Ctrl+Shift+V pastes. In the code that works only because xterm leaves Ctrl+Shift+V alone and Chromium's native "paste as plain text" fires [inferred]. Please confirm it is a requirement (C-05). → ruled: Ctrl+Shift+V paste is a requirement, alongside Ctrl+V.
- **A-05** The connection form's password label says `stored encrypted in the macOS Keychain` on Linux too, and the log window's `Reveal file` tooltip says `Show the log file in Finder`. The other strings on those pages are localised per platform. I assume both are bugs and the native client should say "OS keyring" / "file manager". — `electron/connect.html:308`, `electron/logs.html:156` → ruled: native wording ("system keyring", "file manager").
- **A-06** `docs/native-host.md:164` lists a `GET /api/health` route. The server has `GET /` (the probe target) and no `/api/health`. The checklist follows the code. — `host/internal/server/http.go:175` → ruled: follow the code (the doc is stale).
- **A-07** If `GET /api/sessions` fails at page start, the page logs the failure and stays blank, with no retry. main only loads the page after a successful probe, so this is rare, but a tunnel drop between probe and fetch leaves an empty page until a manual reload. `docs/electron-client.md:266-268` lists this as a known gap. Should the native client retry, or keep parity? — `electron/ui/app.js:1620-1627`, `electron/ui/app.js:1741` → ruled: fix, do not copy: retry the session-list fetch with backoff while connected, and show the state meanwhile.
- **A-08** `newSession()` has no error handling: if `POST /api/sessions` fails, nothing happens and no error is shown (an unhandled rejection). Should the native client show a toast? — `electron/ui/app.js:1389-1415` → ruled: fix: a failed session create shows a status message.
- **A-09** `.tile.exited { opacity: 0.5 }` exists in the stylesheet but nothing sets the class, so an exited terminal is not dimmed during its 1200 ms before closing. Dead style, or an intended fade? — `electron/ui/index.html:338` → ruled: dead style; an exited terminal is not dimmed.
- **A-10** The status message `clipboard access blocked — allow it in the browser, or right-click → paste` refers to a right-click paste that does not exist: there is no context menu. Natively there is no permission prompt either. Suggest a native wording. — `electron/ui/app.js:1017` → ruled: native wording, no mention of browsers or right-click paste.
- **A-11** A `paste-image` or `clipboard-sync` with a MIME the host does not support (e.g. `image/tiff`, `image/svg+xml`) is ignored silently on the host. The client still shows `uploading pasted image…` and then nothing. Should the native client convert to PNG (GDK can), or show an error? — `host/internal/server/paste.go:87-93` → ruled: convert an unsupported image to PNG before sending.
- **A-12** main accepts any theme id matching `[a-z0-9-]{1,32}` into config.json, while pages render unknown ids as dark. The theme list lives only in the page. Natively the list and its validation should live in one place. — `electron/main.js:142`, `electron/ui/settings.js:62` → ruled: theme list and validation live in the settings model; unknown ids fall back to dark.
- **A-13** The fleet pane count in the window title includes file-browser panes ("N panes"), and it is harvested from the page's title. Confirm that file browsers should count. — `electron/ui/app.js:202`, `electron/main.js:481` → ruled: file-browser panes count in the pane total.
- **A-14** `clipboard-sync` goes out on only one host's page: the visible one, whose window-focus event fires. Hidden hosts' panes depend on their own next focus. In Electron every host page gets the window focus event; whether background views fire it is unverified [inferred]. Decide: sync to every connected host, or only the visible one? → ruled: sync to the visible host on window focus and whenever the visible host changes.
- **A-15** README's "Using the layout" says Ctrl+R / ⌘R reloads the page (`README.md:287`). On Linux, Ctrl+R in a focused terminal is the shell's reverse search (xterm consumes it), so reload is reachable only from the menu [inferred]. The same goes for F11 full screen and Ctrl+Q quit. Do any of these need a native shortcut? → ruled: no reload command, Reconnect covers it; full screen and Quit live in the menu and take no terminal keys.
- **A-16** The log window's Clear pushes its marker entry during the IPC call, and the window then empties its list after the call returns. The marker may or may not survive in the window, depending on ordering [inferred]. Minor; native can just show the marker. → ruled: show the "cleared" marker.
- **A-17** README says the file browser deletes on `d`/`Delete`. The code also deletes on Backspace (F-24). Confirm Backspace is wanted; it is easy to hit while a rename field has just closed. — `electron/ui/files-widget.js:1059` → ruled: keep Backspace as a delete key.

## Not carried over

Proposed exclusions. Each needs the lead's ruling.

- **N-01** `webmux://` scheme, per-origin localStorage, the `/settings.json` and `/log` and `/log/open` scheme endpoints, the `?port=` page URL: browser plumbing. Natively, persistence is keyed by the L-41 slug and settings/log are direct calls. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-02** CORS headers and preflight handling on the client side: a native HTTP client is not subject to origin checks. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-03** Preload bridge and the "file: pages only" isolation: no untrusted page content is loaded into a privileged context natively. The privilege rule it served (no host can enumerate or switch hosts, or read the log) is kept as W-19 and G-29. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-04** WebGL addon, the 16-context cap and DOM-renderer fallback, the fit addon and web-links addon: xterm.js implementation details, replaced by Ghostty's renderer, grid fitting and link detection. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-05** The page-title channel (`webmux — N panes · offline` harvested by main) for pane count and degraded state: natively the chrome reads the counts and socket states directly. The outcomes (W-03, X-17 degraded) stay. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-06** `executeJavaScript` event injection (`webmux-new-terminal`, `webmux-pane`, `webmux-settings`…) and `registerAccelerator:false` trickery: direct calls natively. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-07** The in-page header (`index.html` `<header>`, hidden under Electron) and the non-Electron localStorage fallbacks in `settings.js`, `log.js` and `env.js`: only for loading the page outside the client, which the native client never does. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-08** Font-load race handling (3 s wait, re-measure on `fonts.ready`): the font is embedded natively. Keep only the outcome in T-02. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-09** execCommand clipboard fallbacks and "insecure origin" messages: browser-only. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-10** Download-as-navigation (`will-navigate` allow-listing of `/api/fs/raw?download=1`, `will-download` hooks): natively, fetch and write the file behind a GTK file chooser (F-55 keeps the folder memory and log lines). → ruled: accepted as not carried over; the outcomes it served stay.
- **N-11** View › Toggle Developer Tools. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-12** macOS-only items: Local Network probe and hint (X-40, X-41), Keychain wording, ⌘ chords, Hide/Hide Others/Show All, the Zoom window role, `NSLocalNetworkUsageDescription`, code signing and `pack-mac.js`. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-13** Legacy migrations: the pre-columns split-tree layout format (`electron/ui/app.js:104-130`) and the pre-profiles config shape (X-02). Electron's localStorage cannot be read by the native client, so old layouts start fresh anyway. Keep the config.json migration only if the native client shares `config.json` with Electron. Decide whether it does: same path or a new one, and whether the two clients may run side by side. → ruled: own config path, no legacy migrations; on first run without config.json, import profiles from the Electron client's config (no passwords, no localPort); the clients can run side by side.
- **N-14** The `<userData>/node-cache` leftovers mentioned in `electron/main.js:735-736`: nothing to do. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-15** `backgroundThrottling:false` and the other per-view Chromium settings: the outcome (X-32) stays; the mechanism does not exist natively. → ruled: accepted as not carried over; the outcomes it served stay.
- **N-16** Electron's `autoHideMenuBar` Alt-tap menu (W-40): a GTK4 app conventionally uses a header-bar hamburger or a popover menu instead. Propose replacing it with a menu button holding the same items (W-41…W-45), unless the lead wants the hidden menu bar kept. → ruled: a header-bar menu button with the same items replaces the Alt-tap menu bar.
