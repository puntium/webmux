# Recheck after the fix round: file browser, connections/chrome, panels

Verifier: independent; I built none of it and fixed none of it. Nothing under `gtk/ghostty` was edited or rebuilt.
Binary: `gtk/ghostty/zig-out/bin/webmux-gtk` (Debug, built 2026-11-04 22:19). Scratch: `/tmp/rv3-fcp`.

## How this was tested

- **Ten headless runs**, all stopped afterwards (`app.exit` = 0 each time). `pgrep` at the end found nothing of mine: no app, sway, host, pty host, socat relay, fake ssh or keyring daemon.
  - Dev runs with the file fixture: `/tmp/wm-8hglzg`, `/tmp/wm-KyL2cQ`, `/tmp/wm-T3jrFH`.
  - Chrome runs with fake ssh: `/tmp/wm-vTAMuG`, `/tmp/wm-AVgkXn`, `/tmp/wm-epJKr1` (long runtime dir), `/tmp/wm-3RsItt` (two hosts), `/tmp/wm-MmuxmE`.
  - A dev run behind a recording WebSocket proxy: `/tmp/wm-rYRKvJ` (a copy of the panels auditor's `proxy.py` in my scratch dir).
  - 17 one-shot runs over corrupt `config.json` variants, driven by `/tmp/rv3-fcp/cfgtest.sh`.
- **Real input everywhere a person acts.**
  - `realkeys-xkb`: every chord, Tab/Escape/Return, and Shift+D.
  - `realkeys`: typing text.
  - `realpointer`: clicks, hover, wheel and finger scroll, slider drag.
  - `chrome-click`: real clicks on the page, form, cards, ⋯ menu, pills and header.
  - `files-locate` + `realpointer`: rows, links, confirm buttons, backdrop.
  - The GTK save dialog, the replace prompt and the header menu were driven with real keys and clicks and captured with `grim`.
- **ssh wrapper.** ssh was my wrapper `/tmp/rv3-fcp/fssh` around `fake-ssh`. It logs every argv element, logs whether `SSH_ASKPASS` is set and the password's length (never its value), and adds `tunnel-fail` / `hang` / `delay` knobs.
- **Keyring.** A real GNOME Keyring (`webmux-dev/keyring`), started, stopped and locked between steps. Its items were checked independently with `secret-tool` on the run's private bus.
- **Control-socket commands** were used only to set up data (`files-open`, `log-push`, `status`, `settings-set` to restore a value), to read state, and where no real path exists. The cases without a real path are drops (no drag source may be launched) and protocol frames, which were injected through the proxy.

Shorthand in the repro steps: `W`=`wmctl -s $D/ctl.sock`, `RK`=`realkeys $D`, `XK`=`realkeys-xkb $D`, `RP`=`realpointer $D`, `H`=`$D/host/home`.

## Verdicts: file browser (`files.md`)

| Id | Verdict | How verified / what remains |
| --- | --- | --- |
| F-33 | DEVIATION 33, matches | `sample.webp` shows the header and `preview failed` (`image_failed: true`), as the deviation's text says. |
| F-39 | FIXED (inline code: DEVIATION 43, matches) | Links are not underlined at rest (`files.css:218`). A real pointer hovered over `relative link` and it was underlined, with `md_hover: true` (screenshot `lk1c.png`). Real clicks: the relative link navigated to `~/notes/todo.md` and the web link was recorded by the sink. Inline code has square corners, as deviation 43 says. |
| F-42 | **PARTLY** | **Kept:** the preview's scroll position survives an unrelated change in the directory (3 `touch` events), a focus refresh, and real Ctrl+Shift+←/→ away and back (drilled 3903 px, wheel 872 px). **Still lost:** when the previewed file itself changes, the preview jumps to the top. Electron keeps `scrollTop` for any same-path re-render (`files-widget.js:717-737`). This is the common case of editing a README or tailing a log in the pane next door. Repro: `seq 400 > $H/med.txt`; open it; `RP abs X Y, scroll 0 5` over the preview (`scroll_y` 436); `echo 401 >> $H/med.txt`; 2 s later `W files-state entries:=false --get columns.-1.preview.scroll_y` → **0**. Markdown does the same (`README.md` 112 → 0). |
| F-63 | FIXED | 0 bad settles in 120+ real navigations, checked against the Electron target min(extent−page, cursor column x): <br>• 15× h/l at 1 s pauses; <br>• 40 random j/k/h/l with random pauses; <br>• 12× l/h with 4.3 s pauses on a 5000-entry directory (TTL re-lists of every ancestor); <br>• 25 real pointer clicks on random rows; <br>• Ctrl+Shift+F, move-column and window resizes. |
| F-65 | FIXED | The view was scrolled away with a real wheel / finger scroll, then the layout changed. It went back to the target after: Ctrl+Shift+F on and off, a window resize, and a min_cols settings change. A cursor move also returns it. (WEBMUX.md "Known gaps" still describes F-65 as open; that text is stale.) |
| F-54 | CANNOT VERIFY (real DnD) | No drag source may be launched. `files-drop` (drop handler) works, including D12. By reading: `browser.zig:2761-2767` `DropTarget(GdkFileList)` on each column frame; `onDrop` at 2798. |
| F-58 | CANNOT VERIFY (real DnD) | grep: the only `DropTarget` in the shell is in `files/`. Unchanged from the audit. |
| D1 | FIXED | `nest.md` (40 levels), `quote.md` (30 levels), and `wide.md` (14-column table, 400-char code line, 300-char word): the header, Rendered/Source and ⤓ stay in place. The body scrolls horizontally under a real wheel (`md-nest2.png`). The code block scrolls on its own. |
| D2 | FIXED | Tried hard to make a download destroy something; nothing local was destroyed. <br>• `out.txt.part` and `.out.txt.part` survive. <br>• Target is a directory → fails, contents intact. <br>• Read-only folder → fails, nothing created. <br>• Symlink target → only the link is replaced; `victim.txt` is untouched. <br>• Host SIGSTOPped then killed mid-stream (300 MB) → temp removed, the existing `huge.bin` ("precious") intact. <br>• 3 concurrent downloads to one name → one complete file (cmp), no temp left. <br>• Real dialog: the existing name gets GTK's replace prompt. Escape there leaves the file intact (cmp); Replace replaces it. <br>• Quit while the download was stalled → quit in 0.6 s, dest intact, the temp `.q.bin.<hex>.webmux-part` left (DEVIATION 44 matches). <br>• Quit with the stream flowing → the download completed first. <br>Not tested for real: a full disk (no tmpfs without root); by reading, a write error discards the temp file (`browser.zig:3138-3141`). See new defects N1, N5 and N6. |
| D3 | NOT FIXED | Real `r`, Return on ` lead.txt` renamed it to `lead.txt`, and `trail.txt ` to `trail.txt` (toast `renamed  lead.txt → lead.txt`). Electron does the same; no ruling recorded. |
| D4 | NOT FIXED (host side, shared with Electron) | Real `j` sticks on `twin�.txt` (two rows); `zlast.txt` is unreachable by keyboard. Deleting `bad\xffname.txt` gives `delete failed: ENOENT`. |
| D5 | FIXED | In the delete confirmation, real Tab ×4 and Shift+Tab stay on the buttons; real Escape closes it and focus is `filesbrowser`. Real clicks on the backdrop, Cancel and Delete all close it, and focus is `filesbrowser`. A click on another pane cancels it. |
| D6 | NOT FIXED | Still `Gtk: Trying to measure GtkGrid … for height of 95, but it needs at least 410` from `README.md`'s tables, 16+ per run (FOLLOWUPS acknowledges it). |
| D7 | **NOT FIXED (now worse)** | The "no application name" warning is gone. Instead, each dialog download logs `GLib: g_markup_escape_text: assertion 'text != NULL' failed` and writes a malformed `~/.local/share/recently-used.xbel`. See **N1**. |
| D8 | PARTLY | TTL re-lists of `/tmp` (2000 rows) now render in 2–14 ms (render patch times in `app.log`). Control-socket RTT stayed at p95 5.5 ms / max 73 ms while a 2000-row directory was re-listed every 0.5 s. A first visit to a 2000-entry directory still blocks about 250 ms in Debug (`fillListing … width 197446 us`). Release not measured. |
| D9 | FIXED | Host SIGSTOPped for 17 s (every column `Timeout`), then SIGCONT and one real `j` → everything re-listed and the cursor came back. |
| D10 | FIXED | `![missing alt text](nope.png)` shows `⚠ missing alt text`. Cosmetic leftover: a paragraph with text around an inline image is split into three lines (Electron flows it inline). |
| D11 | FIXED | Image-only paragraphs flow in a row and wrap only for a wide image (`imgs-c.png`). |
| D12 | FIXED (drop handler) | Dropped a folder holding a mode-000 file and a FIFO: `uploaded 2 file(s)`, the unreadable file and the FIFO were skipped. |
| D13 | FIXED | With GTK animations off, a real `l` gives the final widths and scroll in the first sample. |

## Verdicts: connections and chrome (`connections.md`)

| Id | Verdict | How verified / what remains |
| --- | --- | --- |
| X-02 / C-3 | FIXED (DEVIATION 38, matches) | 17 variants were run through a real Save (`cfgtest.sh`). <br>**Moved aside and reported:** truncated, empty, invalid UTF‑8, BOM, top-level array, a directory, mode 000. Each is renamed `config.json.broken-<UTC>`, the page shows a banner, and the connection log has `config.json unreadable … keptAs=`. The first save then writes a new file; the broken copy is kept. <br>**Read-only config dir:** the file cannot be moved, so saves are refused (`config.json is unreadable and was not overwritten…`) and the file is untouched. <br>**Instance with `$(touch …)`:** no file created. <br>**Valid JSON with wrong types:** silently normalised; see N9. <br>**Duplicate ids:** see **N2**. |
| X-10 / C-2 / C-4 | FIXED (DEVIATION 37, matches) | **Clear while the keyring is down:** keyring stopped, real Edit → `clear saved` → Save. `keyring.json` then had `cleared:[id]`. After the keyring came back, Connect logged `auth=key`, ssh got no askpass, `cleared` emptied, and `secret-tool` shows no item. <br>**Delete while the keyring is down:** ⋯ → Delete ×2 (real clicks). The item was gone once the keyring answered (`secret-tool`: 0 items). <br>**Save with a password and no keyring:** form error `the system keyring is unavailable — cannot store a password`, `config.json` byte-identical, and the typed password stays in the field. <br>**Locked keyring:** `failed`, `saved password could not be decrypted…`. <br>**Keyring vanishing during a retry:** reconnects with the cached secret. |
| X-18 / C-1 | FIXED (DEVIATION 36, matches) | **Edit then add:** a connected to hostB, a's host edited to hostC (real form), then b created on hostB → refused (`"a" is already connected…`). <br>**Retry:** a's tunnel killed while hostB's tunnel refuses; the retries stay on hostB and b's Connect is refused during the retry. <br>**Reconnect moves the edit:** real Ctrl+Shift+R on a → a moves to hostC, and b connects to hostB. <br>**Reconnect into a taken target:** b edited to hostC, then real Ctrl+Shift+R → refused with a toast; b stays on hostB. <br>**One socket per connection:** every socket listed in the run dir belongs to one connection. See N8 for the card text. |
| X-13 | CANNOT VERIFY | The keyring can only start after the app headlessly, so the backend name in `client started` is never seen. Unchanged. |
| X-31 | CANNOT VERIFY | Not triggerable headlessly. Unchanged. |
| W-05 | CANNOT VERIFY fully | Real clicks on the header ⚙, `+ New terminal`, pills, card buttons and the menu all work. Focus after each click was not measured. |
| W-19 | CANNOT VERIFY | Reading only. Unchanged. |
| W-42 | CANNOT VERIFY | The Edit menu was not exercised. Unchanged. |
| C-5 | FIXED | Live rename b → b2 through the real form, then a real Ctrl+Shift+Return and `exit 3`: `session socket open` / `closed` / `session exited` are tagged `[b2]`. |
| C-6 | FIXED | `XDG_RUNTIME_DIR` of 93 chars: `failed`, message `the runtime directory is too long for a socket path`, and diagnostics explain the 107-byte limit. |
| C-7 | FIXED | Locked keyring: `connect requested … auth=password`. |
| C-8 | FIXED (port: DEVIATION 39 by reading) | SIGSTOPped server: `probe missed (1/3) error=Timeout`. A hand-edited `sshPort` of 99999 is kept and shown as `-p 99999`; I did not press Connect on it (`profile.zig:21` says connect refuses with `PORT_ERROR`). Out-of-range forms (`1e400`, `-1`, `22.5`) become 0 silently. |
| C-9 | FIXED | Menu → webmux → Open Config File, clicked with the real pointer: the sink recorded `file:///…/config.json` and nothing launched (`menu.zig:317-328`). The `page action=menu`-while-hidden part is control-only; not rechecked. |

Secrets: the test passwords appeared 0 times in `config.json`, `keyring.json`, `webmux.log`, `app.log` and the ssh argv log. They were also absent from the app's `/proc/*/environ`. Only the ssh children had them (the fake's local "remote" processes inherit them, a test artifact).

## Verdicts: settings, log, status, modals (`panels-protocol.md`)

| Id | Verdict | How verified / what remains |
| --- | --- | --- |
| E-10 | DEVIATION 32, matches | The header ⚙ is enabled on the connection page; a real click and a real Ctrl+, open the settings. Real backdrop click, Done and Escape all close it, and focus is back on the focused pane. |
| E-13 | FIXED | Real typing `12.7`+Tab in the max field → 90 (Electron's result). `150` then real Escape in the min field → dropped, min stays 90. |
| G-04 / D2 | FIXED | `log-push data={"x":1e20,"y":-9.3e18,"z":1.5e300,"w":2^63-1}`: no crash. Trivial: 1.5e300 is printed as 301 digits (JS: `1.5e+300`). |
| G-07 | DEVIATION 34, matches | `workspace reports its session sockets are back`; no `loading app page` lines. |
| G-08 | FIXED | Seen live in `webmux.log`: <br>• `session socket connecting`, `open`, `reconnecting`, `reopened` with `attempt` and `ms`; <br>• `snapshot received bytes=`; <br>• `session socket dropped — retrying code=1006 clean=false upMs= retryInMs=`; <br>• `connect failed — retrying`; <br>• `closed (tab closed or session exited)`. |
| G-22 | FIXED | Host `production-cluster-eu-west-1-bastion` selected: the toolbar wraps to two rows at 900 px and to four rows at 400×300. Follow and filter are visible in both schemes (`log-light.png`, `log-dark.png`, `log-small.png`). Real Escape closes the window, and typing goes back to the focused pane. |
| M-01 | FIXED | 200 × "long ": the toast is 624 px wide, under the 640 px limit. See N4 for long words. |
| M-03 | FIXED | The settings dialog and the link chooser dim the window; panes stay visible in dark and light (`set1.png`, `set-light.png`). The fade slider dragged with the real pointer previews live behind the dialog. |
| M-04 | FIXED | A 1200-char URL is shown with no inserted hyphens (`insert_hyphens=false`). An `open-url` injected on the unfocused pane, then real Escape → focus goes to the source pane, and typed text lands there. Real clicks on Cancel and on the backdrop give the same result. Copy puts the URL on the clipboard (`wl-paste`). |
| G-29 | CANNOT VERIFY | Reading only. Unchanged. |
| P-27 | CANNOT VERIFY | The slow-consumer path cannot be provoked. Unchanged. |
| D1 | FIXED (freeze); see N10 | A 20 MB snapshot injected through the proxy: control-socket polls every 20 ms for 20 s, max 1 ms. The audit saw a 210 s freeze. |
| D3 | FIXED | 0 `AdwDialog` / measure warnings when opening settings. At 700×420 the content scrolls (upper 509, page 378). |
| D4 | FIXED | Same as C-3 above. |
| D5 | FIXED | 0 `invalid C0 character` warnings in any run. |
| D6 | NOT FIXED | After `exit 3` the server sends close 1000; the client resets the socket without echoing it (proxy log: `c2s error: Connection reset by peer`). |
| D7 | NOT FIXED | An injected title `T\x07itle\x1b]0;evil\x07 end` is stored raw, and the pane bar draws boxes for the control characters (`titlec.png`). |
| D8 | DEVIATION 46, matches | With alpha in front, a status from beta is not shown; Ctrl+2 within 3 s shows it. |
| D9 | FIXED (not reproducible) | Real pill click on beta then a real header `+ New terminal` 0.3 s later → the pane lands on beta. Ctrl+1, pill click, then a real Ctrl+Shift+Return → also beta. |
| D10 | NOT FIXED (informational) | `output` with `\ud800` is still dropped whole; the host never sends one. |

## New defects (not in the audit), most important first

1. **N1: Every download through the save dialog corrupts the user's desktop-wide recent-files list. The next one erases every other application's entries.**
   - What happens: GTK adds the saved file to `~/.local/share/recently-used.xbel` with `exec="` left unterminated. `app.log` has `GLib: g_markup_escape_text: assertion 'text != NULL' failed`. Probable cause: the D7 fix set an application name (`application.zig:460`) but no program name, so GTK's exec string is NULL.
   - Why it matters: the file becomes invalid XML. On the next save, GTK fails to load it and rewrites it with only its own entry. This is a shared file that every GTK application on the desktop reads and writes.
   - Repro:
     1. Start a dev run and put a valid `recently-used.xbel` with one LibreOffice entry into `$D/home/.local/share/`.
     2. In the browser, real Shift+D; type `$D/dl/got1.txt`; Return. The file no longer parses (`ExpatError … line 21`).
     3. Download a second file the same way. `grep -c important-report` → 0: the LibreOffice entry is gone.
2. **N2: Duplicate profile ids are kept, and one profile's saved password is sent to another host.** Copying a profile block in `config.json` to make a similar profile duplicates its `id`. The keyring is keyed by id, so the two profiles share one secret.
   - Repro:
     1. Config `{"profiles":[{"name":"one","host":"hostO","id":"0123456789abcdef"},{"name":"two","host":"hostT","id":"0123456789abcdef"}]}`, with the keyring running.
     2. Set a password on `one` (real form).
     3. Connect `two` → `connect requested host=hostT … auth=password`, and ssh to hostT gets askpass with the 7-char password of `one`.
   - Clearing or deleting either profile also removes the other's password. Deviation 7 promises stable unique ids; duplicates should be re-issued at load.
3. **N3: A long profile name or host makes the main window wider than the screen.**
   - What happens: on the connection page the card name and the `detail` line (host, port, instance) are neither ellipsized nor wrapped, and neither are the header pills. The page grows past its 620 px column and sets the window's minimum width.
   - Measured: a 76-char name and a 70-char host forced a 1013 px minimum (a resize to 560 was refused). A 250-char name made the window **2817 px wide on a 1920 px output**, with Log, New Profile, the card buttons, ⚙ and the menu off-screen (`wide-small.png`). A 1366 px laptop or a half-screen tiled window hits this with ordinary long ssh hosts.
   - Electron ellipsizes `.card .detail` and caps the column at 620 px (`connect.html:66,96-101`).
4. **N4: Wrapped text gets hyphens that are not in it.**
   - Markdown paragraphs: a 300-char word breaks as `aaaa-`.
   - Table cells: `column-header-0` is drawn as `col-u-mn-he-ad-er-0` (`md-wide.md.png`).
   - Toasts: a long unbroken word breaks as `…dave-`, `averyv-` (`toast2.png`); toasts show file names and paths.
   - Same Pango default as the M-04 bug, fixed only in the link chooser (`panels/url.zig:224-229`).
5. **N5: Files whose name is longer than about 225 bytes can never be downloaded.** The temporary name `.<name>.<16 hex>.webmux-part` (`savefile.zig:51`) exceeds the 255-byte name limit, so creation fails. A 226-byte name → `download failed: NNN…`; 200 bytes works.
6. **N6: Download failures give no reason.** Read-only folder, target is a directory, name too long and host died all show the same `download failed: <name>`; the log says only `download interrupted`.
7. **N7: The port check is looser than deviation 39's text.** `0` is accepted and stored as blank, and JavaScript number forms are accepted: `0x16` saves as 22 (`page.zig:743-747` uses `jsNumber`). `22.5`, `70000`, `abc` and `-5` are refused correctly.
8. **N8: After editing a live profile's host, its card shows the new host while the connection still runs on the old one** (deviation 36), with no hint that the change waits for Reconnect. Seen: card `a | hostC` while a's socket was `hostb-….sock`.
9. **N9: Valid JSON with wrong types in `config.json` is silently normalised and written back.** `"host": 42` became `""`, `"profiles": "oops"` became `[]`, and `sshPort` values `1e400`, `-1`, `22.5` became 0. There is no banner or log line, unlike unparseable files (deviation 38), and the original is overwritten on the next save. Low: only hand edits produce it.
10. **N10: Snapshot replay is very slow in Debug.** A 20 MB injected snapshot replayed about 18 000 of its 250 000 lines in 4 minutes, so the pane would be busy for about an hour. A later `title` frame on that socket waited behind it. The UI stays responsive (D1 fixed). Real host snapshots are small; needs a release measurement.
11. **N11 (cosmetic):**
    - A paragraph with an inline image is split into separate lines.
    - In a 480×360 window the cursor row and the rename field sit under the two horizontal scrollbar indicators.
    - The link chooser for a short URL has empty space above the URL.
12. **N12 (docs):** `WEBMUX.md` "Known gaps" still says the browser keeps its horizontal offset after a column-width change (F-65); it no longer does.

`app.log` otherwise held no criticals, panics or assertion failures in any run. The only GLib error was N1's. The only Gtk warnings were D6's.

## Summary

58 findings rechecked (20 file browser, 17 connections/chrome, 21 panels):

| Verdict | Count | Items |
| --- | --- | --- |
| FIXED | 36 | |
| PARTLY | 2 | F-42, D8 |
| NOT FIXED | 7 | file browser: D3, D4, D6, D7; panels: D6, D7, D10 |
| DEVIATION (matches) | 4 | F-33, E-10, G-07, panels D8 |
| CANNOT VERIFY | 9 | F-54, F-58, X-13, X-31, W-05, W-19, W-42, G-29, P-27 |

All the big audit items are really fixed under real input:
- the off-screen preview (F-63);
- the download that destroyed `.part` (D2);
- the shared tunnel socket (C-1);
- cleared passwords returning (C-2);
- the lost corrupt config (C-3);
- the opaque modals (M-03);
- the missing per-session log lines (G-08);
- the log toolbar (G-22);
- the chooser's focus (M-04);
- the snapshot freeze (D1).

What stands in the way of daily use:
- **N1** (any dialog download damages the user's desktop recent-files list);
- **N2** (duplicated ids send a password to the wrong host);
- **N3** (a long profile name or host pushes the window off-screen);
- F-42's remaining case (the preview jumps to the top whenever the open file changes).
