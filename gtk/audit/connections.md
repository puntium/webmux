# Audit: connections, deploy, window chrome (PARITY §7, §8, §9)

Auditor: independent; nothing under `gtk/ghostty` was edited or rebuilt.
Binary audited: `gtk/ghostty/zig-out/bin/webmux-gtk` (`1.3.2-webmux-shell+f54340a`), 2026-11-04.

## How this was tested

- Eight headless runs (`webmux-dev/headless start`). All were stopped afterwards, and `pgrep` found nothing left: no ssh stand-ins, socat relays, remote servers, pty hosts or keyring daemons.
- ssh was my own wrapper around `webmux-dev/fake-ssh`, selected with `WEBMUX_GTK_SSH`. It is a copy in my scratch dir, not in the tree. It does three things:
  - logs every argv element bracketed, plus whether `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE` and `WEBMUX_SSH_PASSWORD` were set (the password's length only, never its value);
  - adds failure knobs per host: `fail-probe`, `probe-out`, `fail-push`, `start-out`/`start-exit`, `tunnel-fail`, `tunnel-hang`, `hang`, `delay`;
  - then `exec`s the stock `fake-ssh`.
- Most actions went through the real UI path:
  - form typing, Return/Escape, Ctrl+Shift+R/O and Ctrl+1…3 used `webmux-dev/realkeys`;
  - the ⋯ menu items were activated with real Down/Return keys.
- Pointer-only actions used the chrome's control commands, which enter at the same functions as the signal handlers: pill click/✕/drag, the card buttons, and opening the ⋯ menu.
- A real GNOME Keyring (`webmux-dev/keyring`) was used for the password tests.
- Sleep/resume used a real `org.freedesktop.login1.Manager.PrepareForSleep(false)` signal, emitted with `gdbus emit` on the run's private bus.
- Screenshots of every page and header state were taken in both colour schemes. Popovers were captured with `grim`.
- `app.log` and `webmux.log` were read after every run, and grepped for the test passwords (no hits anywhere).

Reproductions below assume `cd gtk/ghostty` and:

```sh
D=$(webmux-dev/headless start -- WEBMUX_GTK_SSH=$PWD/webmux-dev/fake-ssh)
W="webmux-dev/wmctl -s $D/ctl.sock"
mk() { $W page action=new; $W page action=set field=name value=$1; $W page action=set field=host value=$2; $W page action=submit; }
L=$D/home/.local/state/webmux-gtk/logs/webmux.log
```

## Verdicts

### §7 Connections

| ID | Verdict | Notes |
| --- | --- | --- |
| X-01 | DEVIATION 1, 3, 7 — matches | Path is `$XDG_CONFIG_HOME/webmux-gtk/config.json`, mode 0600 in a 0700 dir. Written as 2-space JSON with a trailing newline. Profiles have `name, host, sshPort, identityFile, instance, extraOptions, downloadDir, id`; `passwordEnc` and `localPort` are absent, as the deviations say. |
| X-02 | RULED N-13 — **FAIL** in part | No legacy migrations, as ruled. The first-run import of `webmux/config.json` works: it drops passwords and `localPort`, logs `imported profiles…`, and skips (and logs) a profile whose instance is invalid. **However, an unparseable `config.json` is ignored silently and then overwritten by the next save** (defect C-3). Electron at least prints `config.json unreadable: …`. |
| X-03 | PASS | Validation order checked through the form: an invalid instance with a blank name reports the instance error first, then `name and host are required`, then `a profile named "opts" already exists`. Fields are trimmed. Minor: the port is parsed as an integer, not with `Number(x)\|\|0`. `22.0` and `0x16` become 0 where JS gives 22, and `70000` becomes 0 where JS keeps 70000. |
| X-04 | PASS | `identityFile` and `extraOptions` are trimmed. `extraOptions` `"  -o ProxyJump=bastion   -v<TAB>-4 "` reached ssh as `[-o] [ProxyJump=bastion] [-v] [-4]`, and an identity path with a space stayed one argument. |
| X-05 | PASS (see defect C-5) | Renamed `box3` to `box3r` while connected. The pill kept its position and its Ctrl+2 slot (pressed for real), and the state stayed connected. `lastProfile` followed a rename. The password is keyed by id, so it survives (renamed `pw1` to `pw1r` and reconnected with the password). **But** the workspace keeps logging under the old name (C-5). |
| X-06 | PASS | Editing the host of a live profile left its tunnel alone; the new host was used on the next attempt. See C-1 for what this does to deviation 8. |
| X-07 | PASS | Deleted a connected profile via ⋯ → Delete → `Sure? Removes the profile` (real keys). The profile is gone from `config.json`, the log shows `disconnecting (profile deleted)` and `tunnel killed`, the relay is gone, and the keyring item is removed (`keyring lookup` → none). |
| X-08 | PASS | `lastProfile` is set on connect. Runs that started with a `lastProfile` set did not connect anything. |
| X-09 | DEVIATION 3, 22 — matches | Secret Service item keyed by profile id. `keyring.json` (0600) holds ids only. The form shows only a placeholder and the `clear saved` box. The password does not appear in `config.json`, either log, argv, or the app's `/proc/<pid>/environ`. |
| X-10 | **FAIL** | (a) With no keyring, Save with a password still saves every other field, clears the password field, and shows `profile saved, but the system keyring is unavailable — cannot store a password`. Electron rejects the whole save (C-4). (b) `clear saved`, or deleting the profile, while the keyring is down reports success but leaves the secret in the keyring. The "cleared" password is used again once the keyring is back (C-2). Blank-keeps and non-blank-replaces work. |
| X-11 | DEVIATION 9 — matches | The helper is `$XDG_RUNTIME_DIR/webmux-gtk/askpass.sh`, mode 0700, with the exact Electron script. A planted 0755 `askpass.sh` in a 0755 dir was replaced and both were forced to 0700. A symlinked runtime dir was refused (the engine does not start and the page says so). With a password, every ssh (deploy steps and tunnel) got `-o NumberOfPasswordPrompts=1`, `SSH_ASKPASS=<helper>`, `SSH_ASKPASS_REQUIRE=force` and the password in its environment only. Without one, none of these were set. |
| X-12 | PASS | A locked keyring (`keyring lock`, prompt fails) and an absent keyring each parked the connection in `failed`. The message is `saved password could not be decrypted — edit the profile and re-enter it`, the reason goes to diagnostics and the log, and there is no retry. Minor: `connect requested` then logs `auth=key` although a password is saved (C-7). |
| X-13 | READ (partly observed) | Observed `passwordStore="none (no Secret Service on the session bus)"`. The keyring can only be started after the app in a headless run, so the GNOME Keyring name could not be observed. `keyring.zig:181-209` (owner pid → `/proc/<pid>/comm`) looks right. |
| X-14 | PASS | argv logged option by option. With and without password, port, identity file and extra options, it matches `main.js:167-191` exactly, in order, with the host passed verbatim. |
| X-15 | DEVIATION 1 — matches | `ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes <base> -L <runtime>/webmux-gtk/<slug>.sock:<advert.socket> <host>`. stdin and stdout are ignored, stderr is captured into the log and diagnostics. |
| X-16 | DEVIATION 1, 9 — matches | No port; one socket per host+instance. A 128-character host gave a 107-byte path with the hash kept. Defect C-6: a runtime dir too long for any socket path fails every connect with a bare `connection failed`. |
| X-17 | PASS | All states plus derived `degraded` were seen. Log levels match (`state connected → retry` warn, `→ failed` error). Diagnostics keep the last 8 lines (12-line `logTail` → `tail06…tail12` plus the error). |
| X-18 | PASS / DEVIATION 8 — **FAIL** in one case | Connect on a connected profile only shows it (no `connect requested`). Reveal, `lastProfile`, and the logged fields (`socket` instead of `localPort`, deviation 11) are right. A plain second profile for the same host+instance is refused with `box4: "box1" is already connected to this host and instance`. **But the refusal compares the profiles' current host/instance, not the live tunnel's socket.** After editing a live profile's host, another profile can bind the same tunnel socket (C-1). |
| X-19 | PASS | Cancel during a hung deploy step killed that ssh at once (`deploy step killed (user)`) and nothing followed. 80-step random bursts of connect/disconnect/reconnect/resume left exactly one tunnel, or none, and no orphan processes. |
| X-20 | PASS | Never-connected failures park in `failed`: ssh refused, bad host, wrong password, every deploy failure, and 20 s with no answer. With the empty host view in front (Ctrl+1 during the connect), a failure switched to the page. With a loaded view, the view stays. |
| X-21 | PASS | Timed with a tunnel that always exits 255: `retry in 1s, 2s, 4s, 8s, 15s, 15s, 15s`, with matching gaps between `retrying` lines. Every retry re-ran the deploy, and a live view stayed on screen and healed. |
| X-22 | PASS | `sessions restarted — …` (connected, workspace reloaded), `webmux has never been deployed to this host`, `ssh exited (255) — ssh: connect to host hostB port 22: Connection refused`, and on a host that never answers `ssh exited (SIGTERM)` after 30.0 s. It works while disconnected. A hand-edited instance `a$(touch /tmp/PWNED-audit)b` is refused (`invalid instance name in profile`) and no file was created. The `stale-killed` and `not-running` branches cannot be reached with the fake's `pgrep` stub; the script is byte-identical to `main.js` (`deploy.zig:373-406`). |
| X-23 | PASS | Pill ✕ (control), card Disconnect/Cancel and delete all kill whatever is in flight and drop the entry. The page is shown if that host was in front. Remote pty hosts kept running. |
| X-24 | PASS | First probe at once, then every 500 ms (`afterMs=502` on a healthy tunnel). A tunnel that never forwards gives up at `afterMs=20020` with `server did not answer through the tunnel`. |
| X-25 | PASS | On the first answer: connected, content created, reveal honoured. Then a probe every 5 s. After a retry the workspace re-lists its sessions. |
| X-26 | PASS | Remote server frozen with SIGSTOP. Misses at +7 s, +14 s and +21 s (5 s interval plus 2 s timeout, as in Electron), then `probe: server unreachable through the tunnel — reconnecting`, `retry in 1s`, and a redeploy. Server killed: same path, and the sessions survived (snapshot repainted). Minor: `probe missed` has no `{error}` field. |
| X-27 | PASS | A real PrepareForSleep(false) on the bus gave `system resumed from sleep tunnelsKilled=1`, then `killing pre-sleep tunnel to reconnect now`, then a retry 1 s later, then connected. |
| X-28 | PASS | Connect from the page, then a real Ctrl+Shift+O during a 2 s deploy: the view did not switch when it connected. Without the key press it did. |
| X-29 | PASS | Killed the server of a hidden host: its pill recoloured, the view in front did not change, and the hidden panes reconnected (`snapshots` 2→3). |
| X-30 | PASS | Real Ctrl+Shift+R on a host view logs `tunnel killed (reconnect)`, `reconnect requested`, then a fresh cycle. Against a down host it parks in `failed`. On the page it just shows the page. |
| X-31 | READ — looks right | `hostview.zig:134-144`: a workspace that fails to start logs `workspace failed to start`, shows a placeholder, and sends the window to the page if it was in front. Cannot be triggered headlessly. |
| X-32 | DEVIATION 4 — matches | Hidden hosts' panes stay attached and heal in the background (see X-29). |
| X-40 | N/A | macOS only (N-12). |
| X-41 | N/A | macOS only (N-12). |

### §8 Deploy

| ID | Verdict | Notes |
| --- | --- | --- |
| D-01 | PASS | Probe, push and start are each one `ssh <base> <host> 'exec sh -c '…''` step, byte-identical to `deploy.js`. Every retry re-ran them. Every step could be cancelled (X-19). |
| D-02 | PASS | `probing host…`. A motd before the tags is ignored. Output with no `@@` lines → `host probe failed — no uname output (unusual remote shell?)`. |
| D-03 | PASS | `unsupported host platform 'Darwin arm64' — supported targets: Linux x86_64, Linux aarch64`. `'Linux armv7l (musl)'` gives the same form. aarch64 maps to linux-arm64. |
| D-04 | PASS | With `WEBMUX_PAYLOAD_DIR` pointing at a manifest without arm64, an aarch64 host fails with Electron's exact text, after the probe. |
| D-05 | PASS | The script is identical. Status reads `pushing webmux… 0% of 3.8 MB`. Updates fire per whole-percent change (`proc.zig:382`); the first status shows 0% where Electron starts at the first chunk's percentage. A missing tarball gives `payload tarball missing: <path>`. A failing push gives `ssh exited (1)` with `tar:` stderr in diagnostics. |
| D-06 | PASS | `starting server…`, `start --name default` (and `inst.1`). `reuse` and `started` were both seen. |
| D-07 | PASS | `{ok:false,error:"boom",logTail}` → `l1`, `l2`, `server start failed: boom`. `garbage` with exit 3 → `server start failed: ssh exited (3)`. Empty output with exit 0 → `webmux-host start produced no result — see diagnostics`. On success the tunnel uses `advert.socket`. |
| D-08 | PASS | `ssh: <line>` (warn), `deploy: <msg>` once per step, `deploy done: server started ms= platform= payload=<12> socket= pid=`, `deploy failed ms= error=`, and the debug `deploy step: ssh` / `ssh exited` lines with the command clipped to 120. |
| D-09 | PASS | Changed the manifest hash under a live connection and reconnected. The new payload was pushed next to the old one, both dirs remained, the same pty-host pid survived, and the session text survived. |

### §9 Window chrome

| ID | Verdict | Notes |
| --- | --- | --- |
| W-01 | PASS | 1400×900, title `webmux`, background `#16161e`, and `#dfe1e8` in light. The scheme follows live. |
| W-02 | PASS | 37 px plus a 1 px border header, with a stack holding exactly one visible view. |
| W-03 | PASS | `webmux`, `webmux — 1 host · 0 panes`, `1 host · 1 pane`, `2 hosts · 3 panes`. File browsers count (A-13). Updates live. |
| W-04 | PASS | Every run started on the page with nothing connected. |
| W-05 | READ / partly exercised | A view switch focuses the new view; after a header `+ New terminal` the new pane had focus. Clicks cannot be made headlessly; the header widgets are non-focusable (`header.zig:114-122`, 224-228) and handlers call `focusContent`. Looks right. |
| W-06 | PASS | Closing the window via sway `kill` and Quit from the menu both exit 0 with `client quitting connections=3` and `tunnel killed (quit)` / `deploy step killed (quit)`. No leftovers. No confirmation. |
| W-07 | PASS | Real Ctrl+Q, Ctrl+Shift+Q, Ctrl+W and Ctrl+Shift+W on the page and on a host: the window stays. |
| W-10 | PASS | Checked the CSS against `header.html` value by value, plus screenshots. Minor: pill and button vertical padding is 3/4 px instead of 4/5 to fit GTK line metrics. The menu button is added (N-16). |
| W-11 | PASS (hover READ) | Pills follow connection order: dot, name, ✕. Hover and the hidden-scrollbar overflow judged from CSS and `header.zig:66-74`. |
| W-12 | PASS | Dot colours, pulse and light values match the CSS. Seen: connecting, connected, retry, failed. |
| W-13 | PASS | Active pill: yellow border, tint and text (screenshot). |
| W-14 | PASS / DEVIATION 23 | `box1 — interrupted — retrying in 8s (Ctrl+1)`. The countdown ticks live. |
| W-15 | PASS (control path) / READ (hover) | Pill click shows the host; ✕ disconnects. The ✕ hover styling is from CSS. |
| W-16 | PASS (control path) | drag-begin fades the pill; drag-over gives slot 1 and shows the accent bar (screenshot); the drop reorders. Pill order and a real Ctrl+2 follow the new order. Engine reorder is the Electron algorithm (`engine.zig:390-404`). |
| W-17 | PASS | Connections highlighted on the page; `+ New terminal`, `+ Files` and `⚙` insensitive (screenshots, `conns`). |
| W-18 | PASS | `+ New terminal` added a pane to the host in front; on the page the buttons are disabled and do nothing. |
| W-19 | READ — looks right | The header is built only from the hub's entries; nothing from the host protocol reaches it. |
| W-20 | PASS | Screenshots: 620 px column, title, `Log` (opens the log window) and `New Profile`, dark and light. |
| W-21 | PASS | Dot, state label, bold name, monospace `hostE -p 2222 → inst.1`. Live cards have the primary border. |
| W-22 | PASS | CSS `#d9a334` / `#c75450` / `#55a868` and pulse, as Electron. |
| W-23 | PASS | Edit / Disconnect / Show, Edit / Cancel, Edit / Connect, then ⋯. Show on a connected profile only shows. |
| W-24 | PASS | Real keys: Return on `Restart Sessions…` relabels it to `Sure? This kills every shell`, a second Return acts. Delete likewise. Escape and closing the menu clear the confirmation. A status push (another host retrying) left the menu open with the confirmation pending. Popover look matches. |
| W-25 | PASS | `box5: restarting sessions…` then `box5: <result>`. Clears after 8 s. |
| W-26 | PASS | `No profiles yet — create one to connect.` |
| W-27 | DEVIATION 1 / RULED A-05 — matches | All fields, labels, placeholders and the `saved — leave blank to keep` / `clear saved` logic are present. The first field takes focus (typed into it with real keys). Port 0 shows empty. There is no Local port field (deviation 1). The label reads "system keyring" (A-05). |
| W-28 | PASS | `Save & Connect` / `Save` / `Cancel`. Errors are inline and the form stays open. Real Escape cancels; Return in a field submits. |
| W-29 | PASS | Typed into a new form while a tunnel was killed and reconnected: the typed text survived (screenshot). |
| W-30 | PASS / DEVIATION 23 | Retry, failed and degraded blocks have the right texts ("workspace's" instead of "page's"), and the diagnostics box scrolls with a 140 px maximum. The countdown is live. |
| W-31 | RULED A-05 — matches | Linux wording with "system keyring (GNOME Keyring or KWallet, via the Secret Service)". |
| W-32 | PASS | `settings-set theme=light` restyled header, page, cards, form and status live (screenshots). |
| W-40 | RULED N-16 — matches | A header menu button replaces the Alt-tap menu bar. |
| W-41 | PASS (Open Config File READ) | Exercised About (an Adw dialog), Connections…, Reconnect, Connection Log…, Settings… and Quit, with their accelerator hints. `Open Config File` was not activated: it calls `GtkFileLauncher` directly (`menu.zig:317-328`) and bypasses the run's URL sink, so it would launch a real app. Judged by reading: correct. |
| W-42 | READ | Undo…Select All are present. Copy shows Ctrl+Shift+C (A-03). In a terminal, Cut copies (Electron: no-op), Copy copies and Paste pastes (`menu.zig:383-403`). Terminal activation not exercised (other auditors own C-xx). |
| W-43 | RULED A-15 / N-11 — matches | No Reload and no devtools. Zoom items present; Toggle Full Screen exercised (1920×1200 and back). |
| W-44 | PASS / DEVIATION 25 | Pane › New Terminal and Close Pane acted on the visible host (pane count 2→3→2). On the page they do nothing (deviation 25). The hints are display-only, so a shortcut is handled once (`shortcuts.zig`). |
| W-45 | PASS (Minimize READ) | Previous/Next Host and Host 1–9 work (Next Host from the page → first host). There is no close item. |

## Defects outside the checklist (or beyond one item's line)

**C-1 — Two connections can share one tunnel socket (hole in deviation 8). Disconnecting one kills the other.** Severity: high.

The duplicate check in `engine.zig:308-319` compares the new profile's host+instance slug with `c.slug()`, which is computed from each connection's *current profile* (`supervisor.zig:155-159`). It should use the socket its live tunnel is bound to. After a live profile's host is edited (X-06 keeps the tunnel), a second profile for the old host is allowed and binds the same path. With real ssh, `StreamLocalBindUnlink` steals the socket. When either tunnel ends, `supervisor.zig:965` unlinks the path. The other connection then misses three probes, drops, and reconnects to the edited host, which the user never asked for.

```sh
mk a hostB; sleep 3; $W key key=ctrl+shift+o
$W page action=edit name=a; $W page action=set field=host value=hostC; $W page action=submit
mk b hostB; sleep 3
$W conns            # a and b: connected, identical socket_path …/run/webmux-gtk/hostb-1740acff.sock
$W disconnect name=b; sleep 22
grep '\[a\]' $L | tail   # probe missed (1/3)…(3/3), retry, "ssh hostC", connected to hostC
```

**C-2 — A cleared or deleted saved password survives in the keyring when the keyring is unavailable, and comes back.** Severity: high (security and correctness).

When there is no Secret Service, `keyring.zig:411-417` (`clear`) only drops the id from the hint and returns success. The item stays in the keyring. When the keyring is available again, `lookup` finds it and ssh is given the password the user cleared (`auth=password`, askpass used). Profile deletion goes through the same `clearAsync` (`page.zig:470`), so deleting a profile while the keyring is down leaves an orphaned secret forever. Electron's secret lived in `config.json` and went with the profile.

```sh
webmux-dev/keyring start $D; mkdir -p $D/remote/hostP; printf s3cret > $D/remote/hostP/password
$W page action=new; $W page action=set field=name value=p; $W page action=set field=host value=hostP
$W page action=set field=password value=s3cret; $W page action=submit; sleep 3   # connected
webmux-dev/keyring stop $D
$W key key=ctrl+shift+o; $W page action=edit name=p; $W page action=set field=clear value=true; $W page action=submit
cat $D/home/.local/state/webmux-gtk/keyring.json   # "ids": []  — looks cleared
webmux-dev/keyring start $D
$W page action=disconnect name=p; $W page action=connect name=p; sleep 2
grep 'connect requested' $L | tail -1   # auth=password ; $D/remote/ssh.log: "password ok"
```

**C-3 — A corrupt `config.json` is ignored silently, then overwritten (profiles lost).** Severity: medium-high.

`profile.zig:272-276` swallows the parse error, and `engine.zig:103-110` logs only read errors. Nothing appears in `app.log` or the connection log. The page shows an empty list, and the first save rewrites the file. Electron at least reports `config.json unreadable: …`.

```sh
mkdir -p /tmp/wm-cfg/webmux-gtk; printf '{"profiles":[{"name":"keepme","host":"h"}],,,\n' > /tmp/wm-cfg/webmux-gtk/config.json
D=$(webmux-dev/headless start -- XDG_CONFIG_HOME=/tmp/wm-cfg WEBMUX_GTK_SSH=$PWD/webmux-dev/fake-ssh)
$W conns   # page.cards == [] ; grep -i config $D/app.log $L → nothing
mk n1 badhost; cat /tmp/wm-cfg/webmux-gtk/config.json   # keepme is gone
```

**C-4 — Saving a password without a keyring half-saves the profile.** Severity: medium. See X-10a.

`page.zig:732-757` commits the profile first and stores the password afterwards. Electron validates first, so nothing is saved. The typed password is also wiped from the field.

```sh
mk x hostB; sleep 2; $W key key=ctrl+shift+o
$W page action=edit name=x; $W page action=set field=host value=hostZ; $W page action=set field=password value=pw; $W page action=submit
$W conns   # form error "profile saved, but the system keyring is unavailable…"; config.json already has host hostZ
```

**C-5 — After a live rename, workspace and page log entries keep the old name.** Severity: low-medium.

`workspace.zig:230` copies `c.name` once, so `hostview.renamed` (`hostview.zig:201-209`) does not reach it. The log window's host filter then splits one host into two.

```sh
mk box3 hostA; sleep 3; $W key key=ctrl+shift+o
$W page action=edit name=box3; $W page action=set field=name value=box3r; $W page action=submit
$W page action=restart name=box3r; $W page action=restart name=box3r; sleep 2
grep 'page: session exited' $L    # tagged [box3], not [box3r]
```

**C-6 — A runtime dir too long for any socket path fails every connect with no explanation.** Severity: low; it needs an unusually long `XDG_RUNTIME_DIR`. `paths.zig:103` returns `RuntimeDirTooLong`. Both `connectConn` and `runTunnel` (`supervisor.zig:488`, `802`) swallow the error. The log shows `connect requested … socket=""`, then `deploy done`, then `state connecting → failed msg="connection failed"`, with empty diagnostics. Repro: start with `XDG_RUNTIME_DIR=` set to a dir whose path is about 95 characters, then `mk ok hostO`.

**C-7 — The `connect requested` log line says `auth=key` when a password is saved but the keyring is locked or absent.** Severity: low. `supervisor.zig:496` uses the lookup result; Electron uses whether a password is stored. Repro: the X-12 steps, then `grep 'requested' $L`.

**C-8 — Minor log and value differences.**
- `probe missed (n/3)` has no `{error}` field (`supervisor.zig:950`).
- A hand-edited out-of-range `sshPort` (99999) silently becomes 0, i.e. ssh's default port (`profile.zig:408-413`). Electron would pass it through and fail visibly.
- The Electron import aborts entirely if any field has an unexpected JSON type (`import.zig`, typed `parseFromSlice`). It is logged.

**C-9 — Test-safety, not user-facing.**
- `Open Config File` bypasses the URL sink, so activating it in a headless run would launch a real app.
- `page action=menu` can pop up a card's ⋯ popover while the page is hidden; it then floats over the host view. Only the control path can do this, so it is harmless to users but misleading in tests.

**Checked and not found:**
- crashes, hangs, or GTK criticals in any `app.log`;
- orphaned ssh, socat, deploy or keyring processes after Cancel, Delete, Quit, window close or the random bursts;
- stale sockets: the tunnel socket was unlinked on every teardown;
- secrets in `config.json`, `keyring.json`, either log, the app's argv or its environ.

Socket permissions with real ssh (bind mask 0177) cannot be observed: the fake uses socat, which binds 0755. The directory is 0700 either way.

## Summary

Counts, one verdict per item (79 items: 34 in §7, 9 in §8, 36 in §9). Mixed verdicts are counted as follows: FAIL wins over anything else; "PASS / DEVIATION" counts as DEVIATION; "PASS (… READ)" counts as PASS.

| Verdict | Count |
| --- | --- |
| PASS | 57 (21 in §7, 9 in §8, 27 in §9) |
| FAIL | 3 (X-02 in part, X-10, X-18's deviation-8 case) |
| MISSING | 0 |
| DEVIATION n (matches) | 9 (X-01, X-09, X-11, X-15, X-16, X-32, W-14\*, W-27, W-30\*) |
| RULED (matches) | 3 (W-31, W-40, W-43) |
| N/A | 2 (X-40, X-41) |
| READ | 5 (X-13, X-31, W-05, W-19, W-42) |

(\* also exercised.) W-11, W-15, W-41 and W-45 count as PASS but have parts judged by reading (hover, Open Config File, Minimize).

**Failures by how much a user would care:**
1. **C-1:** after editing a live profile's host, two connections can share a tunnel socket. Disconnecting one silently kills the other and moves it to the edited host (X-18 / deviation 8).
2. **C-2:** clearing a saved password, or deleting its profile, while the keyring is down leaves the secret in the keyring. It is used again later (X-10, X-07).
3. **C-3:** a corrupt `config.json` is silently treated as empty and overwritten on the next save, so profiles are lost with no message (X-02).
4. **C-4:** saving a password without a keyring commits the rest of the edit and wipes the typed password (X-10).
5. **C-5:** a renamed live connection's workspace events stay tagged with the old name.
6. **C-6, C-7, C-8:** silent failure with a very long runtime dir; `auth=key` logged when the keyring is locked; missing probe error field and port normalisation.

**Not auditable headlessly:**
- real pointer hover, drag and click (exercised through the handlers' entry points instead);
- real ssh, so `StreamLocalBindUnlink`, ssh's bind mask, and real ssh exit codes and signals;
- the keyring backend name in `client started` while a keyring is running;
- the `not-running` / `stale-killed` Restart Sessions branches (the fake's `pgrep` is a stub);
- real suspend (only the D-Bus signal);
- Open Config File (it would launch an app).
