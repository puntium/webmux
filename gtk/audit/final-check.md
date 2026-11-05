# Final check: second fix round, release binary, a day of use

Verifier: independent; I built and fixed none of it. Date: 2026-11-05. Binary: `gtk/ghostty/zig-out-release/bin/webmux-gtk`
(ReleaseFast, `info: ghostty build optimize=fast` in every `app.log`), used as built. Nothing under `gtk/ghostty` was edited or
rebuilt (`git status` there is unchanged and no file in it is newer than my start). Helper scripts and data: `/tmp/fincheck-1868007`.

## How this was exercised

Twelve headless runs through `webmux-dev/headless`, all stopped (`app.exit` = 0 each). At the end no app, sway, keyring, socat
relay, host or pty host of mine was running (ps and a `/proc/*/cwd` scan).

| Run | Start | Used for |
| --- | --- | --- |
| `/tmp/wm-E3eEhi` | full app, fake ssh, hosts alpha and beta | blocker 1 (terminal, three panes, file browser, rename field, form fields), blocker 2 (downloads while running) |
| `/tmp/wm-3JzQIU`, `/tmp/wm-VUYzcd` | full app, fake ssh, persistent `XDG_CONFIG/DATA/STATE_HOME` and `FAKE_REMOTE_ROOT` in my scratch dir | blocker 2 across quit and restart; restore after restart; Part 3 day of use |
| `/tmp/wm-06Jt93`, `wm-KemrTn`, `wm-OzBn7Q`, `wm-ws2Cox` (+ an accidental `wm-mEHMQq`, stopped at once) | full app, my ssh wrapper `fssh` (logs a sha256 prefix of whatever askpass gives each host), real GNOME Keyring, keyring data carried between runs | blocker 3 |
| `/tmp/wm-qsXqBz` | full app, hand-written config with long names, hosts and instance | blocker 4 |
| `/tmp/wm-GKAxEB` | `--host` | scrolling distances, selection, divider drag, latency, preview scroll, big directories, downloads N5/N6, replay and throughput |
| `/tmp/wm-rYrw6m` | `--host --scale 2 --size 2560x1600` | HiDPI scrolling and rendering |

Input was real throughout: `realkeys-xkb` (also as a persistent stdin keyboard for latency), `realkeys`, `realpointer`,
`with-mods`, `chrome-click`, screen positions read off `grim` captures. The control socket was used to read state, to set up data
(`files-open`, `url-sink clear`) and in a few places where noted. Before every `xdg-open` in a session I checked there that
`command -v xdg-open` resolved into the payload's `shims/` and that `DISPLAY` was `no-such-display.invalid:0`. No launcher ran in
tmux or a login shell. Every download went into a run or scratch directory; the save dialog opens in the process's working
directory (the fork root here), so I always typed an absolute path into `/tmp`.

## Part 1: the four blockers

### 1. The header menu and the keyboard: **PARTLY**

**Fixed for terminals and the file browser.**

- **Closing the menu.** I closed the ☰ menu by Escape, by its button, by a click on empty header space, by choosing an item
  (View › Reset Zoom), from inside a submenu by Escape, and from a submenu by clicking elsewhere. Each time, real typing
  (`realkeys` and `realkeys-xkb`) landed in the pane that had focus, including at 20 ms after closing.
  - One pane: 3 rounds of every method.
  - Three panes (two stacked): each of the three panes focused in turn, typed text checked in that pane by session id.
- **Edit items on a terminal.** Clicked with the real pointer:
  - Copy put the real-drag selection on CLIPBOARD, with no toast (D-04).
  - Paste typed the clipboard text.
  - Paste with a PNG on the clipboard ran the image flow (`uploading pasted image…`, then `pasted image → …/paste-…png`).
    This fixes C-06.
  - Select All selected the scrollback.
- **File browser.** It gets focus back in all four ways, and a real `j` moves its cursor.
- **Connection page.** With a form field focused, every close method leaves focus in the field (`conns focus` = `text`).
- **First use.** The first menu use in a fresh run is fine.
- **Other dialogs and controls.** The settings dialog (⚙ then Escape), the log window (Ctrl+Shift+G then Escape) and the
  Connections button all return focus.
- **Caveats.**
  - The card ⋯ menu was only exercised by the smoke, not by me.
  - In my very first two attempts of the first run, the typed text was lost after Escape and after a button close. I could not
    reproduce this in about 40 later attempts. It is an observation, not a verdict.
  - Two Escapes after opening a submenu send the second Escape to the shell. That is GTK's behaviour (one Escape closes the whole
    menu), not a defect.

**Not fixed for form fields.** When focus comes back to a text field, GTK selects the field's whole content. The next keystroke
then replaces what the user had typed.

- Repro:
  1. Ctrl+Shift+O, New Profile, type `hello` in the name field.
  2. ☰, then Escape.
  3. Type `X`. The field now holds `X` (captures `f3.png`, all selected, and `f4.png`).
- It is the same after the settings dialog (⚙, Escape) and after a click on Connections. It does not happen with the log window,
  which is a separate window.
- In the **password field** this is silent: type `abc`, ☰, Escape, type `def`. Three dots are shown, and the field holds `def`
  (`f5.png`).
- Edit › Paste from the menu therefore replaces the whole field instead of inserting at the cursor. Edit › Copy then copies the
  whole field.
- The Electron client never selects an input when focus returns to it.

Also seen: opening the menu while the file browser's rename field is open cancels the rename. Electron cancels on `blur` too
(`files-widget.js:425`), so this is not a defect. It does mean Edit › Copy/Paste cannot act on the rename field; its own
Ctrl+A/C/V keys work.

### 2. Downloads and `recently-used.xbel`: **FIXED**

Downloads went through the real dialog: Shift+D, then a typed path, then Return.

- **Run `wm-E3eEhi`.** Seven downloads.
  - Foreign LibreOffice and Image Viewer entries were added while the app ran, with an atomic replace as GLib writes. They were
    kept.
  - The file stayed valid XML (`xml.dom.minidom`).
  - Each new entry has `exec="'webmux-gtk %u'"`.
  - 0 `g_markup_escape_text` or other GLib assertions.
  - Cancel and the replace prompt (Escape) behaved.
- **Persistent run.** I seeded the foreign entries, downloaded twice, quit from ☰ › webmux › Quit (exit 0 in 1.1 s), restarted
  with the same data dir and downloaded twice more. Result: valid XML, both foreign entries kept, four correct new entries,
  0 assertions. The per-profile download folder survived the restart (`downloadDir` in `config.json`; the dialog opened there).
- **Test pitfall.** My first seed was dated 2026-10-01 and was dropped. That is GTK's own 30-day `gtk-recent-files-max-age`,
  which every GTK app applies on write. With current dates the entries survive.

### 3. Two profiles and one secret: **FIXED** (no cross-host leak found), with small leftovers

Real keyring on the run's bus. Items were read with `secret-tool` (printed as hashes). Every password ssh received was logged per
host by `fssh`. Hosts were `hostO` (password pwO, `3e6c94f9`) and `hostT` (pwT, `23f6f4fe`).

- **Copied block.**
  - Run 1: `one` (hostO) got pwO through the real form; hostO received `3e6c94f9`.
  - Between runs I pasted `one`'s block as `two` on hostT with the same id.
  - Run 2: the banner and the log show `"one", "two" had the same id: each was given a new one, and a password saved under it was
    cleared`. The original was kept as `config.json.before-repair-*`, and the id was recorded in `keyring.json` `cleared`.
  - Connect `two` → `auth=key`, `askpass=none`. Connect `one` → `auth=key`, `askpass=none`.
  - The keyring item was purged and `cleared` emptied.
- **Fresh passwords afterwards.** Both saved through the form, each host got its own.
- **Keyring absent, then present.** I started a run with no keyring and connected seven hostT profiles:
  - `dupname (2)` (a duplicate name, renamed on load);
  - `noid` and `nullid`;
  - `badid` (`"xyz"`) and `numid` (`12345`);
  - `spaceid` (hostO's id plus a trailing space);
  - `longid` (32 hex).
  
  Then I started the keyring and connected all of them again, plus `dupname` (hostO).
  - hostT never got anything.
  - Only hostO got pwO, under its own unchanged id.
- **Rename, delete, re-create.** All through the real UI:
  - The rename kept hostO's password.
  - The delete cleared it.
  - A re-created profile of the same name on hostT got `askpass=none`.

Leftovers (low):

- **a. Case-variant duplicate.**
  - Setup: the copy carries the id in UPPERCASE and is listed first.
  - Both profiles are re-issued and neither gets a password, but `cleared` records the uppercase id. The Secret Service match is
    exact, so hostO's lowercase item is never deleted. `cleared` is emptied anyway, and `keyring.json` `ids` still lists it.
  - Restoring the kept original minus the copy gives `one` its password back. That is hostO's own password, so there is no
    cross-host leak, but deviation 48 says neither copy keeps it.
- **b. Missing or `null` ids are not reported.** They are re-issued silently (no banner, no log line); malformed, non-text and
  shared ids are reported. The task asked for missing ids to be reported. No secret can attach to them.
- **c. Orphaned items stay.** Items whose id disappeared from a hand-edited file stay in the keyring and in `keyring.json` `ids`
  forever. They are not reachable by any profile.

Moving an id by hand from one profile to another hands the secret over. This is inherent (the item is keyed by id only,
deviation 22), the same as editing a profile's host.

### 4. Long strings and the window size: **FIXED**, one cosmetic leftover

Tested on a 1920x1200 output, at 1400x900, 800x600, 700x500, 560x420 and 420x320. The window never grew; the smallest width is
446 px, set by the header's own buttons. Every control stayed reachable.

Strings tried:

- **Profile names.** 253 characters with spaces, 300 `x`, and a typed 160-character name.
- **Other connection fields.** A 196-character host that fails with a long ssh error; a 24-character instance; an 80-digit port
  (refused with the form error).
- **Terminal and files.** A 400-character OSC title, file names of 224 and 244 bytes, a 1500-character URL in the link chooser,
  and a 240-character unbroken name in a rename toast.
- **Log window.** The log window with these names.

Cards, pills, pane bar, preview header, toast and chooser all ellipsize, wrap or scroll.

Leftover: a profile name of **256 bytes or more shows its pill as `?`**. `chrome/header.zig:257` formats the name into a 256-byte
buffer and falls back to `"?"`. About 128 Cyrillic characters reach that. Cosmetic.

## Part 2: the rest of the second fix round

| Item | Verdict | What happens now (release, real input) |
| --- | --- | --- |
| C-06 Edit › Paste image | FIXED | See blocker 1. |
| D-04 Edit › Copy toast | FIXED | The real menu copies the selection, and no status line is written. I did not check for `text/html`. |
| D-06 selection edges | FIXED (DEVIATION 58 matches) | Real double-clicks: a space in `bar (  ) baz` gives ` `; `(` gives `(`; a two-space run gives `  `; `x "q w" y` gives `q` and `w`; `path/to/file.txt:12` is selected whole. A click, then Shift+click, selects `bar ( `. |
| D-11 shims in tmux | left as ruled | Not retested. |
| re-check N2 / DEVIATION 57 scrolling | **PARTLY** | See the scrolling numbers below the table. |
| re-check N3 / DEVIATION 50 chooser | DEVIATION 50 matches | `xdg-open` on beta, then Ctrl+1: chooser closed, typing lands on alpha. Ctrl+2: same URL raised again. Escape: focus back on beta's pane. |
| re-check N4 / DEVIATION 51 zoom | DEVIATION 51 matches | Real `de` Ctrl+plus, Ctrl+KP_Add, Ctrl+KP_Subtract and Ctrl+slash (the de `-`), and `fr` Ctrl+=, all run zoom-in or zoom-out (`last_shortcut`). Cell width changed 7→8→9→8. Zoom does nothing in dev mode (no host view, deviation 24). |
| O1 divider lag | FIXED in release | A real 30-step drag, sampled every 10 ms: the divider follows each pointer step within one sample and ends under the pointer. |
| O2 paste ordering | CANNOT VERIFY | Not exercised. |
| F-42 preview scroll | FIXED (DEVIATION 54 matches) | Text scrolled to 427: an append, and a rewrite of the same size, both keep 427. A shrink to 30 lines goes to 0 (fits). Markdown at 136: an append keeps 136. At the end (7010), growth keeps 7010 and does not follow. |
| D8 first big directory | FIXED (DEVIATION 55) | Real `l` into a 2130-entry and a 5000-entry directory: the main loop's longest stall is 15.7 ms and 17.3 ms (ping every 5 ms). |
| D3 rename trimming, D4 non-UTF-8 names | left as ruled | Not retested. |
| files D6 GtkGrid warnings | FIXED | README.md with tables previewed: 0 warnings. |
| files D7, re-check N1 (xbel) | FIXED | Blocker 2. |
| panels D6 close echo | CANNOT VERIFY | Needs the recording proxy; not run. |
| panels D7 / DEVIATION 59 titles | PARTLY verified | OSC 0 title `  A\x01B   \tC\x7fD\xc2\x85E\xffF ` shows as `AB C␡D�E�F`: whitespace collapsed and trimmed, DEL as ␡, C1 and invalid UTF-8 as U+FFFD. The C0 byte is dropped by the terminal's OSC parser (as xterm.js's parser ignores C0 in OSC). Host `title` frames with raw controls were not injected. |
| panels D10 / DEVIATION 61 | CANNOT VERIFY | No frame injection. |
| re-check N2, N3 (ids, long names) | FIXED | Blockers 3 and 4. |
| re-check N4 inserted hyphens | **PARTLY** | Toasts no longer hyphenate (240-character word). The connection page's ssh error block still inserts hyphens that are not in the text: `…verylongho-stname…`, `…verylo-nghostname…` (`l4.png`). `-` is a valid hostname character, so this is misleading. Markdown tables not rechecked. |
| N5 names over 225 bytes | FIXED | A 244-byte name downloads through the dialog. |
| N6 failure reasons | FIXED | Read-only target folder: `download failed: lower.txt: permission denied`. |
| N7 port | FIXED | Real typing: `0`, `0x16`, `22.0`, `65536` and `-1` are refused with the form's message. ` 22` is accepted as 22, blank as default. |
| N8 / DEVIATION 52 | matches | Live beta edited to me@gamma. The card shows `me@gamma` and `on me@beta until Reconnect (Ctrl+Shift+R) applies the edit` (ellipsized at 1400 px). The socket stays on beta. Undoing the edit clears the line. |
| N9 / DEVIATION 49 | matches | Wrong types are reported in the banner and the log, the original is kept, and nothing is written before a save. Missing ids are not reported (blocker 3 b). |
| N10 replay speed | FIXED for real snapshots | Server restart replayed a 70 KB snapshot in under 1 ms. Output throughput: `seq 1 300000` (about 2 MB) on screen in 0.29 s, 4 MB of base64 in 0.14 s, with the UI's longest stall 3.6 ms. The 20 MB injected snapshot was not re-run. |
| N11 cosmetics | PARTLY | Rename field at 480x360: visible and clear of the scrollbar. Inline image on its own line: DEVIATION 56. The link chooser for a short URL (`https://a.io`) still has an empty band above the URL (`n11b.png`). |
| N12 docs | FIXED | `WEBMUX.md` "Known gaps" no longer describes F-65. |

**Scrolling numbers (N2 / deviation 57).** At scale 1 and 2:

- One wheel notch = 3 lines; Alt+notch = 15 lines.
- An 80 px swipe sent as 4 × 20 px = 56 lines; 2 × 10 px = 14 lines. These match the deviation's numbers exactly.

The touchpad delta is rounded **per event** with no remainder, so the same 80 px swipe moves a different distance depending on
how the touchpad slices it. Electron would move 56 lines every time; real touchpads send 1–5 px deltas.

| Swipe | Normal screen | Alternate-screen arrows |
| --- | --- | --- |
| 40 × 2 px | 40 lines | 40 |
| 16 × 5 px | 64 lines | 48 |
| 8 × 10 px | 56 lines | 56 |
| 10 × 1 px | 10 lines (Electron 7) | 5 (Electron 7) |

Counts (26 rows, the blockers' own items excluded):

| Verdict | Count |
| --- | --- |
| FIXED | 12 |
| Deviation matches | 4 |
| PARTLY | 4 (scrolling, hyphens, titles, N11) |
| Left as ruled | 3 |
| CANNOT VERIFY | 3 |

## Part 3: a day of use

### Defects, most important first

1. **Text fields lose what was typed after any popover or dialog.** This is blocker 1's remaining part; repro under blocker 1.
   Anyone who opens ☰ or ⚙ while filling the profile form replaces their input with the next key. In the password field they
   cannot see it happen. The connection then fails with a wrong password, or worse, a wrong password is stored in the keyring.
2. **An unfocused file browser scrolls away from its own listing.**
   - Repro:
     1. Open a browser beside a terminal, with its cursor on a file.
     2. Ctrl+Shift+H, or click the terminal.
   - Its horizontal scroll jumps at once from its target (1220) to 523, or to 0, and becomes un-pinned. The pane then shows
     ancestor directories (in my run, my scratch directories) instead of the cursor's column and preview (`light.png`,
     `n11b.png`). It snaps back when the browser is focused again.
   - Cause: GTK's scroll-to-focus moves the viewport on focus-out, and `onHadjValue` (`files/browser.zig:2031`) takes that as a
     user scroll.
   - The Electron client does nothing on blur. Anyone who keeps a README or log preview next to a terminal sees it vanish.
3. **Touchpad scrolling distance depends on event size.** See Part 2: from 30 % less to 40 % more than the Electron client for
   ordinary slow swipes, in normal and full-screen programs.
4. **The first download dialog opens in the app's working directory** (`files/browser.zig:3345`: no fallback when the profile
   has no `downloadDir`). Chromium uses `~/Downloads`. Launched from a terminal, that is the user's current project directory.
5. **A pill shows `?` for names of 256 bytes or more.**
6. **Inserted hyphens in the connection page's ssh error text.**
7. **Keyring leftovers.** Case-variant duplicate not purged; missing ids not reported; orphan items kept. See blocker 3.
8. **Link chooser cosmetic:** the empty band above a short URL.

### Used without trouble

Release build, real input:

- **Connections.** Two hosts through the fake ssh, created with the real form. Profile edit, rename and delete; the port check.
  Settings changed mid-work (light scheme from the real dropdown, applied to every pane and persisted). The connection log
  window.
- **Panes.** New pane by chord and by the header button; new pane below; consume and expel (Ctrl+Shift+[ ]); move column; full
  window; title-bar click to focus; ✕ close and Ctrl+Shift+W; divider drag.
- **Hosts.** Ctrl+1/2, Ctrl+Shift+O, Ctrl+, and Ctrl+Shift+G, also on `us,ru` group 1.
- **Programs.** vim (`-u NONE`, insert, save, mouse click to place the cursor); less (wheel 3 lines per notch, `/` search, `G`);
  htop (open, F10).
- **Output and selection.** 6000 coloured lines, `seq 300000`, scrollback by wheel. Selection by drag, Ctrl+Shift+C, Ctrl+V into
  another pane. Image paste from the menu. A click on a URL (recorded by the sink).
- **Files.**
  - Browse, preview of text, markdown, png, bmp, gif, ico and jpg; `broken.png` correctly fails.
  - Rename; delete with the confirmation, by Return and by Escape.
  - Upload by pasting copied files and a folder. The empty subfolder is not recreated, as in the Electron client.
  - Download, replace and cancel.
- **Resilience.**
  - Tunnel killed → retry, healed in 3.2 s with the same session and scrollback.
  - Host server SIGKILLed → probe misses, redeploy, healed in 15 s with the same session.
- **Restart.** Quit from the menu (exit 0, tunnels killed). After a restart and Connect, the layouts, sessions, scrollback,
  browser directory and cursor, focus, download folder and settings all came back.
- **Scale 2.** Cell 15×34 device px, 8 px padding, crisp rendering.
- **Layouts.** Cyrillic typing and chords under `ru`; zoom keys under `de` and `fr`.
- **app.log.** No criticals, assertions or panics in any run, and nothing logged repeatedly. The only warnings were vim's two
  CSI sequences, `unknown CSI m with intermediate` and the fake ssh notice.

### Measurements (release)

| What | Result |
| --- | --- |
| Key to echo in the terminal state, dev host, local socket (40 real keys) | median 1.5 ms, p90 1.9, max 2.4 |
| Key to echo through the ssh tunnel (fake ssh, socat) | median 2.4 ms, p90 4.5, max 6.2 |
| New terminal pane, chord to attached and settled (session created on the host, open animation) | about 300–450 ms (430–590 ms minus about 130 ms of the key tool's own start) |
| Host switch Ctrl+1/2 | 160–175 ms including about 130 ms tool start and a 45 ms poll, so under about 40 ms |
| Output | about 2 MB in 0.29 s, 4 MB in 0.14 s; longest UI stall 3.6 ms |
| Snapshot replay (70 KB) | under 1 ms |
| First display of a 5000-entry directory | longest stall 17 ms |
| Divider drag | follows within one 10–20 ms sample |
| Tunnel heal / server heal | 3.2 s / 15 s |
| Quit | 1.1 s |

The latency figures are terminal state, not pixels; drawing adds at most one frame.

## Is the release build ready for daily use?

Almost; one thing must be fixed first.

The terminal, the panes, the hosts, the file browser, downloads, the keyring and resilience are solid and fast in the release
build. The recent-files, shared-secret and long-name blockers are really fixed.

What stands in the way:

1. **Must fix.** Focus returning to a text field selects all of it, so the next keystroke wipes what was typed. This hits the
   profile form, including the password, after ☰, ⚙ or Connections, and makes Edit › Paste replace the field. A small change:
   restore focus without selecting, or restore the cursor and selection.
2. **Should fix soon.**
   - An unfocused file browser jumping away from its listing.
   - Touchpad scroll distance depending on event size.
3. **The rest is minor:** the download dialog's first folder, the `?` pill, hyphens in the error text, the keyring leftovers and
   the short-URL band.
