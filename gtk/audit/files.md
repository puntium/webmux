# Audit: PARITY section 6, file browser (F-01 … F-65)

Auditor: independent. Binary: `gtk/ghostty/zig-out/bin/webmux-gtk` as built 2026-11-04 19:09 (not rebuilt).
Runs: `/tmp/wm-1Spbxk` (main, state in `/tmp/wm-aud6st-sVjs`) and `/tmp/wm-IeqNgW` (restore/prune test, state in
`/tmp/wm-aud6s2-BdHw`). Both were started with `webmux-dev/headless start --host -- XDG_STATE_HOME=<dir> GSETTINGS_SCHEMA_DIR=<gtk4 schemas>`,
both stopped cleanly (`app.exit` = 0), and nothing of either was left running (`pgrep`).

How I tested: the file browser pane sat in the real dev workspace next to a terminal pane (`pane-command name=new-files`).
Keyboard input went in as real keystrokes (`webmux-dev/realkeys`), and focus moved between panes with real
Ctrl+Shift chords. I used the real clipboard (`in-session wl-copy`) and the real GtkFileDialog (driven with real keys and captured with `grim`).
Disk effects were checked with `ls`, `find` and `cmp`. Screenshots were taken in both schemes at 1400, 750, 520, 480 and 330 px wide.
The fixture was `webmux-dev/files-fixture` plus my own hostile set: names with leading dashes, quotes, a backslash,
a tab, a newline, a leading or trailing space, emoji and invalid UTF‑8; a 250‑byte name; symlink loops, dangling and
self links; a FIFO and a socket; unreadable files and directories; a 60‑level deep path; directories of 5000 entries and of exactly 2000;
an empty file; a file of exactly 64 KiB, one of 64 KiB + 1, a NUL after 64 KiB, a split UTF‑8 sequence at the cut, Latin‑1, ANSI escapes, CRLF;
a 200 KB single line; corrupt, 20‑byte, 2500‑entry and path‑traversal zips, and `.DOCX`; a 6000×4000 PNG, a 3000 px tall PNG,
a zero‑byte PNG, a scripted SVG and text named `.jpg`; and markdown with raw HTML/JS, 30‑deep quotes, 40‑deep lists,
malformed constructs, every link kind, tables, task lists, code, and a 1.7 MB document.

Shorthand used below: `W` = `webmux-dev/wmctl -s $D/ctl.sock`, `RK` = `webmux-dev/realkeys $D`, `H` = `$D/host/home`.
Common setup for every repro:

```sh
cd gtk/ghostty
S=$(mktemp -d /tmp/wm-st-XXXX)
schemas=$(ls -d "$(nix develop . --accept-flake-config -c pkg-config --variable=libdir gtk4 | tail -n1 | sed 's,/lib$,,')"/share/gsettings-schemas/*/glib-2.0/schemas | head -n1)
D=$(webmux-dev/headless start --host -- XDG_STATE_HOME=$S GSETTINGS_SCHEMA_DIR=$schemas | tail -n1)
webmux-dev/files-fixture $D/host/home $D/local
W="webmux-dev/wmctl -s $D/ctl.sock"; $W pane-command name=new-files; $W workspace-wait panes:=2; $W files-wait
```

## Verdicts

| Id | Verdict | Evidence / notes |
| --- | --- | --- |
| F-01 | PASS | New pane id `files-mw2z5pjl8806`: base36 epoch ms plus a 4‑digit random number. Moved with real Ctrl+Shift+Alt+←/→ (`pane.move-column-*`). |
| F-02 | PASS | `widgets.<id>` in `layout/dev.json` was rewritten within 0.5 s of each real `j` (no explicit save needed). The entry was removed when the pane closed (5 open/close cycles). In run 2 a `files-stale` entry not in the columns was pruned at startup. |
| F-03 | DEVIATION 28, matches | Run 2 layout: `dir:"/nonexistent/gone",cursor:"x"` became `~` with cursor null. `dir:"relative/path"` became `~` (deviation 28). `dir:42` became `~`. `/etc` + `hostname` were kept. The title `~` shows the home was learned. |
| F-04 | PASS | Chain from `/` plus a listing column (dir cursor), a preview (file cursor) or nothing (no cursor), checked with `files-state` on dozens of paths. |
| F-05 | PASS | Measured pixels, dark: cursor row (59,71,104), expected (58,70,104); on‑path (53,53,64), expected (53,53,64). Light: drilled header (189,212,245), expected (189,211,244); on‑path (227,228,231), expected (227,228,232). Hover not exercised (no pointer); `files.css:57` has it. |
| F-06 | PASS | Dot files carry `hidden-file`, symlinks are italic, directories end in `›`. `selfdir` and `up-link` (links to dirs) list as directories; `dangling`, `loop1` and `loop2` list as files. Checked in screenshots. |
| F-07 | PASS | Server order shown unchanged (`Eagle.txt` before `éclair.txt` before `emoji…`, dirs first). |
| F-08 | PASS | Widths: 200 (short names); 335 for a 36‑character name (≈263 px of text + 72); 420 cap (250‑byte name); 1 px borders; columns scroll on their own. Not compared pixel‑for‑pixel with Chromium, because launching a browser is forbidden. |
| F-09 | PASS | `(empty)` (emptydir), `(list truncated)` (5000 entries), no message at exactly 2000, `EACCES` (`locked`), `ENOENT` (dir deleted under the cursor), `Timeout` (host SIGSTOPped; deviation 28). |
| F-10 | PASS | ✎ ✕ only on the cursor row. `files-click target=rename/delete` open the field and the confirmation. 55%/100% opacity per `files.css:80-91`; hover not exercisable. |
| F-11 | PASS | With the preview drilled and focus moved to the terminal by a real Ctrl+Shift+←, `files-click column=… row=1` moved the cursor, cleared drilled mode and gave focus back to the browser. The GTK gesture path (`browser.zig:1031-1043`) was judged by reading. |
| F-12 | PASS | A file added to an unwatched ancestor (`$H`) did not appear on a real `j` within 4 s, and did appear on a `k` 4.2 s later. |
| F-13 | PASS | Real keys: `l j j h l` came back to `c`. After `c` was deleted outside, entering again picked the first entry (`a`). |
| F-14 | PASS | `~/README.md`, `~/h/with⏎newline.txt`, `/etc/hostname` (outside home). |
| F-15 | PASS | `files-fit-title` gave `~/src/…` → `~/…/electron/ui/app.js` → `~/…/ui/app.js` → `…/app.js` → `app.js`. In the real bar at a 330 px window it showed `~/…/level1/…/level6` and refitted on resize. Tooltip by reading (`title.zig:45`). |
| F-20 | PASS | Real keys: ↑ with no cursor selected the last entry and ↓/`j` the first; ↓×3 clamped at the end; ↑ clamped at the top. |
| F-21 | PASS | Real `l`/Return enter directories; on a text file they drill in; on a binary or FIFO (narrow preview) nothing happens. |
| F-22 | PASS | Real `h`/← go to the parent with the cursor on the directory just left; at `/` they do nothing. |
| F-23 | PASS | Real `r` and F2 open the inline field. |
| F-24 | RULED A-17, matches | Real `d`, Delete and BackSpace all open the confirmation. |
| F-25 | PASS | Real Shift+D opened the save dialog. On a directory it showed `select a file to download`. |
| F-26 | PASS | Real Alt+j and Ctrl+j left the cursor where it was. Real Ctrl+Shift+F / ←/→ / Alt chords worked from the browser (`last_shortcut`). |
| F-30 | PASS | Wide previews are 600 px; binary, FIFO and stat errors are 280 px. A text file turned binary behind the browser's back narrowed the column and left drilled mode. Easing by reading (`clip.zig`, 180 ms ease‑out). |
| F-31 | DEVIATION 28, matches | `195 KB`, `64 KB`, `1.4 MB`, `0 B`, `2500 entries`, `1 entry`. Date in en‑US form `11/4/2026, 7:17:05 PM`. The name wraps anywhere. |
| F-32 | PASS | `files-click target=download` opened the real dialog; after cancelling, focus was on `filesbrowser`. No ⤓ for the FIFO or socket (`has_download:false`). |
| F-33 | **FAIL** | PNG, JPEG, GIF, BMP, ICO and SVG (including a scripted SVG) decode and scale down; 6000×4000 and 50×3000 PNGs are fine. **WebP fails**: `preview failed`, and app.log says `image …/sample.webp: Unrecognized image file format`. AVIF goes through the same gdk‑pixbuf path (no sample available, judged by reading). This is only a WEBMUX.md "Known gap", not a recorded deviation. Repro: `$W files-open dir=$D/host/home/img cursor=sample.webp; $W files-wait; $W files-state entries:=false --get columns.-1.preview.image_failed` gives `true`. |
| F-34 | PASS | 64 KiB cut with `(preview truncated)`; exactly 64 KiB not truncated; a NUL in the first 64 KiB gives binary, a NUL after it does not; `(empty file)`; 200 KB line unwrapped with a horizontal scroll; mono 11.5/1.45 by CSS. |
| F-35 | PASS | `.md .MD .markdown .mdown .mkd` render. The Source choice stuck when stepping to the next `.md` with real `j`. A new pane started Rendered. `empty.md` shows the source view. |
| F-36 | PASS | `<script>`, `<style>`, `<iframe>`, `<img onerror>`, `<details>` and inline `<b onclick>` all shown as literal text; task boxes insensitive (`md_view.zig:175`). `javascript:`, `data:` and `file:` links give `can't open …`. (DEVIATION 29: own parser.) |
| F-37 | DEVIATION 29, matches | Relative `../img/logo.png` and an absolute path load through raw; a remote image shows `[remote]`. |
| F-38 | PASS | Via `files-link`: relative, `../`, absolute, `%20` and `?q#frag` navigate; `#anchor` does nothing; `HTTPS://` caps goes to the URL service; `mailto:` opens the chooser; ftp/tel/js/data/file give `can't open <href>`; an empty href does nothing. A real pointer click on a GTK label link was judged by reading (`md_view.zig:61-77`; Shift is captured on press). |
| F-39 | **FAIL** (minor) | Headings 19.5/16.9/14.95/13 px, h1/h2 rule, code block background and radius, quote border and opacity, bordered tables: OK. **Links are always underlined** (GTK `<a>` default; `files.css:221` only sets the colour), where Electron underlines only on hover. **Inline code has no 3 px radius** (Pango `bgcolor` span, `md_view.zig:370`). Repro: open `README.md` and look at the links. |
| F-40 | PASS | Tree connectors, folders first, case‑insensitive order; `/` at 70%; sizes right‑aligned; `(empty archive)` (empty.zip); 2000 of 2500 with `(list truncated)`; corrupt and 20‑byte zips fall back to the binary sniff; `fake.zip` falls back to text; `.DOCX`; a `../../` member is shown as directories. |
| F-41 | PASS | `binary file`, `no preview` (FIFO, socket), `ENOENT`, `ELOOP`, `EACCES`; `preview failed` for a broken PNG and on a transport failure; `…` while pending (by reading, `browser.zig:1102`). |
| F-42 | **FAIL** | The same‑file refresh keeps the content on screen (deviation 28 part matches), **but the scroll position is lost every time** (3/3 watch events and 2/2 focus refreshes). Repro: `$W files-open dir=$H cursor=big.txt; $W files-wait; RK l j j j j j; sleep .5; $W files-state entries:=false --get columns.-1.preview.scroll_y` gives 240; `touch $H/x-$RANDOM; sleep 1.5; $W files-wait;` the same query now gives **0**. The same happens with `$W files-focus` in place of the `touch`. |
| F-43 | PASS | Real `l` / `files-click target=preview`: the header takes the selection colour and the row drops to the on‑path look (pixels in light). At a 750 px window the whole preview is scrolled into view. |
| F-44 | PASS | Real keys: `j`/↓ +48, `k` −48, PgDn/Space +0.9×page (732.6), PgUp, End (to upper−page), Home 0; `l`/Return do nothing; Esc, `h` and ← leave; `r` and `d` act on the cursor file and Esc in them keeps drilled mode. |
| F-45 | PASS | A row click or navigation leaves drilled mode; a preview turning narrow (file made binary behind the browser's back) leaves it. |
| F-50 | PASS | Stem preselected: `.dotfile` [0,8], `multi.tar.gz` [0,9], `source.txt` [0,6]. Typing `jkdlh` did not navigate. Enter commits and the cursor follows the new name with `renamed alink → jkdlh` (the link was renamed, its target left alone). A name that exists gives `rename failed: name already taken`; `x/y` gives `rename failed: invalid name`; whitespace only does nothing; Esc cancels and focus returns to `filesbrowser`. |
| F-51 | PASS | With the field open, an outside `touch` and a simulated window refocus gave no render (render count unchanged) and the field survived; after Esc the new file was listed. |
| F-52 | PASS (see D5) | Text for files and folders is right, the Delete button is red, and it has initial focus (real Return deletes). Real Escape cancels; `files-confirm answer=backdrop` cancels; it is centred over the pane only. Defect D5: Tab escapes the modal. |
| F-53 | PASS | `deleted <name>`; the cursor moves to the entry that took the index, or to the new last entry; a non‑empty directory goes recursively; deleting a symlink to a directory removes only the link (target contents intact); a file deleted outside while the dialog is open gives `delete failed: ENOENT`; `$HOME` gives `delete failed: refusing to delete that`. |
| F-54 | READ (looks right) | No pointer or file manager on the headless seat. Drops went through `files-drop` (entering at `dropFiles`): column target, preview column (previewed file's directory), browser (rightmost directory); folders recursive, empty subfolders skipped, FIFO skipped, symlink followed. The ring and wash were seen with `files-drag`. The GTK side (`browser.zig:2461-2518`, `DropTarget(GdkFileList)`, so text drags are not accepted) was judged by reading. |
| F-55 | PASS (see D2) | Real Shift+D, real typed path and Return: `cmp` identical; log `download started file=big.txt bytes=246890` then `download saved …`; the next dialog opened in that folder with the name prefilled (grim screenshot); real Escape gives `WARN download cancelled`. The `interrupted` path was judged by reading (`browser.zig:2855-2871`). |
| F-56 | PASS | Real clipboard: `text/uri-list` (a file and a folder) plus real Ctrl+V uploaded 3 files; plain text did nothing; `image/png` plus real Ctrl+Shift+V uploaded `image.png`. |
| F-57 | PASS | Toast `uploading 9 file(s)…` then `uploaded 9 file(s) → …`; collisions `f (1).txt`, `noext (1)`, `.env (1)`; contents checked with `cmp`; names with `? # + % \ ⏎` and emoji arrive exact; 5 MB and 150 MB uploads stream (RSS flat, UI responsive); a 201 MiB file gives `upload failed: payload too large` and stops after the earlier files; an empty drop gives `nothing to upload`; the cursor lands on the top‑level entry of the last upload. |
| F-58 | READ (looks right) | No `DropTarget` anywhere in the shell outside `files/` (grep), so a stray drop is refused by GTK and nothing happens. |
| F-59 | PASS | Change in the cursor directory and in the directory under the cursor show up live. `gone` on `rm -rf` closes the stream (watchers `[]`). `host-restart` with a file created during the outage: `reopened` re-lists it. Directories whose listing failed are not watched. No fd or thread growth over 60 navigations. |
| F-60 | PASS | Closing the pane: the app's socket fds went 7→5 (×5 cycles), threads stayed at 20, and the state entry was dropped. |
| F-61 | PASS | Focus coming back by a real Ctrl+Shift+→ re-listed a changed ancestor column. The window‑regain path was only simulated (`files-focus window:=true`; `browser.zig:1960-1981` read). |
| F-62 | PASS (see D8) | With a warm cache a new column grew 0→200 over ≈180 ms ease‑out (sampled every 16 ms). The first render has no motion and the same‑slot swap/fade are by reading (`browser.zig:737-799`). Listing columns keep their scroll across a re‑list. |
| F-63 | **FAIL** | Flaky: after a navigation that adds columns, the follow often settles on the *old* scroll extent and the new preview or listing column is left **entirely off‑screen** on the right. Real keys `h`,`l` with 1 s pauses: 2 of 6, 1 of 8 and 1 of 3 in three loops; also seen after `files-open` (relative markdown link path) and after a window resize. Repro: `$W files-open dir=$H cursor=notes; for i in $(seq 8); do RK h; sleep 1; $W -q files-wait; RK l; sleep 1; $W -q files-wait; $W files-state entries:=false --get hscroll; done`. A bad iteration shows `value` < `upper−page` with the cursor column's right edge at the viewport's right edge and the preview starting beyond it (screenshot `/tmp/wm-1Spbxk/s4.png`). Likely cause (hypothesis): `stepFollow` settles once 300 ms have passed using the adjustment from the previous layout, and a main‑thread stall (D8) makes that first post‑stall frame land past the deadline. |
| F-64 | PASS | Cursor on entry 1500 of 2000: the column scrolled so the row is visible; the scroll was kept across a watch re‑list. |
| F-65 | **FAIL** (low) | After a layout change (real Ctrl+Shift+F toggle‑full, Ctrl+Shift+Alt+← move‑column, workspace min/max column change) the browser keeps whatever horizontal offset it had (e.g. 0, with the cursor's preview off‑screen; `/tmp/wm-1Spbxk/full.png`). Electron re‑attaches and jumps to the right edge. It returns right only on a re‑map (`onMap`). Listed under WEBMUX.md "Known gaps" but not a recorded deviation. Repro: `$W files-open dir=$H cursor=README.md; $W files-scroll dx:=-600; RK -M ctrl -M shift f -m shift -m ctrl; $W files-state entries:=false --get hscroll` stays at the scrolled value. |

## Defects outside the checklist

- **D1 Deeply nested markdown pushes the preview header off-screen.** With content whose minimum width is more than 600 px
  (40‑level list or 30‑level quote), the whole preview box gets wider than its column. The Rendered/Source toggle
  and ⤓ are clipped away and can't be clicked, and the text is clipped instead of scrolling. Electron keeps the header and scrolls the body.
  Repro: `python3 -c "print('\n'.join('  '*i+'- item %d'%i for i in range(40)))" > $H/nest.md; $W files-open dir=$H cursor=nest.md`,
  then screenshot (`/tmp/wm-1Spbxk/w-nest.md.png`): no toggle, no ⤓.
- **D2 Download silently destroys an existing `<dest>.part`.** `downloadStream` writes `<dest>.part` and renames it, with no
  check (`browser.zig:2829-2849`). Repro: `echo precious > $D/dl/out.txt.part; $W files-open dir=$H cursor=lower.txt;
  $W files-download dest=$D/dl/out.txt`. Afterwards `out.txt.part` is gone. The same applies through the real dialog.
- **D3 Pressing r, Enter on an unchanged name renames it if the name has leading or trailing whitespace** (trim): ` leading space.txt` became
  `leading space.txt` with toast `renamed  leading space.txt → leading space.txt`. Electron does the same; it is still a silent
  mutation.
- **D4 Invalid UTF‑8 names (host‑side, also affects Electron).** The host's JSON replaces bad bytes with U+FFFD, so
  `bad\xffname.txt` can't be deleted or renamed (`delete failed: ENOENT`). `twin\xff.txt` and `twin�.txt` list as two
  identical rows: real `j` gets **stuck** on the first (both rows resolve to index 51), the entries below can't be reached by
  keyboard, and delete/preview on either row act on the valid‑UTF‑8 file.
- **D5 Delete confirmation does not hold focus.** Real Tab from Delete moves focus out of the pane to `workspace-strip`. Real Escape then
  does nothing and the dialog stays open until the pane is refocused (Electron's Escape handler is document‑wide).
  Repro: `RK d; RK -k Tab; RK -k Escape; $W files-state entries:=false --get confirm` (still open).
- **D6 GTK layout warnings from markdown tables:** 16× `Gtk: Trying to measure GtkGrid … for height of 95, but it needs at
  least 410` (README.md, a 6‑column table, a long cell). GTK's height‑for‑width measurement is inconsistent for the grid, so the table can be laid out clipped at some widths.
- **D7 `Gtk: Attempting to add 'file:///…/got.txt' to the list of recently used resources, but no name of the application …`**
  after every dialog download. No application name is set, and GTK writes `recently-used.xbel` into the user's data dir.
- **D8 Main‑thread stalls of 115–317 ms per render (debug build)** whenever the 4 s TTL has expired and ancestor columns are re‑listed:
  every column whose Listing object changed is rebuilt (`/tmp` with 1376 rows). Measured as gaps in a 1 kHz `files-state`
  poll. This swallows the 180 ms enter animation and is the likely trigger of F-63. Needs checking on a release build.
- **D9 After a host timeout the browser does not recover by keyboard.** `SIGSTOP` the host for 16 s: every column shows `Timeout` and the cursor is
  cleared. After `SIGCONT`, real `j`/`k` do nothing (`handleKey` returns on empty entries without re‑rendering) until
  `h` or a pane refocus. The JS behaves similarly; noted because the 15 s client timeout (Electron has none) makes the trip easy.
  The UI itself never froze (control socket RTT ~35 ms throughout).
- **D10 A missing local markdown image renders as nothing.** There is no alt text or broken‑image mark (`![missing](nope.png)`); Electron shows the alt with a broken icon.
- **D11 Images‑only paragraphs stack one per line** when one image is wide (GtkFlowBox column alignment). Electron flows them inline. Cosmetic.
- **D12 (by reading)** `uploads.collect` keeps files it can `stat` but not `open`, so an unreadable file inside a dropped folder aborts the
  whole upload (`upload failed: AccessDenied`), although the module comment says unreadable entries are skipped (Electron skips them).
- **D13 (by reading)** Nothing under `files/` honours reduced motion (`gtk-enable-animations` / `gtk-interface-reduced-motion`);
  Electron's `prefers-reduced-motion` rules shorten the column and preview animations to 1 ms.

Nothing worse turned up. No crash, panic, assertion, leak (fds and threads stable, watch sockets closed on pane close), stuck
process or wrong‑path mutation in the native code. Every rename, delete and upload acted on exactly the captured path (the confirm and rename
capture dir and name at open time; a cursor change underneath them cannot redirect the mutation).

## Not audited, or only by reading

- Real pointer: hover colours, real clicks on rows, links, ✎/✕/⤓, the toggle and the backdrop (the headless seat has no pointer). The control‑socket
  equivalents call the same handlers.
- Real drag and drop from a file manager (F-54, F-58).
- Real window deactivation and reactivation (F-61 second half), interrupted downloads, AVIF samples.
- Column‑width parity with Chromium's text measurement (launching a browser is forbidden).
- Release‑build performance (D8).

## Summary

| Verdict | Count |
| --- | --- |
| PASS | 43 |
| FAIL | 5 (F-33, F-39, F-42, F-63, F-65) |
| DEVIATION / RULED (all match the recorded text) | 4 (F-03 dev 28, F-24 A-17, F-31 dev 28, F-37 dev 29) |
| READ | 2 (F-54, F-58) |
| MISSING / N/A | 0 |

Failures and defects, most user‑visible first:

1. **F-63**: after a navigation, the preview or new column is often left completely off‑screen (≈1 in 3–8 real h/l steps).
2. **F-42**: any change in the directory, or any refocus, throws the reader back to the top of the preview.
3. **D1**: deeply nested markdown hides the Rendered/Source toggle and ⤓.
4. **F-33**: WebP (and AVIF) images don't preview.
5. **D2**: a download silently deletes an existing `<name>.part` in the target folder.
6. **F-65**: after a layout change the horizontal view can stay scrolled away from the cursor.
7. **D4 / D3**: invalid‑UTF‑8 names (stuck cursor; can't act on them) and the whitespace‑trimming rename (both shared with Electron).
8. **D5, D8, D9**: confirmation focus escape; render stalls (debug); no keyboard recovery after a timeout.
9. **F-39** (always‑underlined links, square inline code), **D6/D7** (log warnings), **D10–D13**.
