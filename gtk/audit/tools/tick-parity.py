import re, sys
from collections import Counter, OrderedDict

import os
PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'PARITY.md')
R2 = 'fixed in round 2, not independently re-checked'

# category codes: A audited, D deviation/ruling, P partly, R reading, O open, Q no record, N n/a
OV = {
  # 1. Terminal
  'T-02': ('R', ''),
  'T-14': ('A', ' (simple IM; IBus/fcitx not verifiable headlessly)'),
  'T-18': ('P', f'selection edge cases (D-06) not fixed at re-check; changed in round 2 (deviation 58), {R2}'),
  'T-22': ('P', f'real ☰ Edit › Copy did nothing at re-check (D-04, N1); {R2}'),
  'T-25': ('D', 'deviation 17, 26'),
  'T-27': ('P', f're-check found HiDPI wheel and touchpad distances wrong (N2); deviation 57 {R2}'),
  'T-31': ('D', 'deviation 1'),
  'T-40': ('D', 'deviation 19'),
  # 2. Clipboard
  'C-03': ('R', ''),
  'C-06': ('P', f're-check NOT FIXED via the real ☰ menu (N1); {R2}'),
  'C-08': ('A', ' (`claude` mode by reading)'),
  'C-10': ('D', 'ruling A-11'),
  # 3. Sessions
  'S-01': ('D', 'ruling A-07'),
  'S-04': ('A', ' (title seeding by reading)'),
  'S-09': ('D', 'deviation 45'),
  'S-12': ('R', ' (transitions exercised; link-down aggregation judged by reading)'),
  'S-13': ('D', 'ruling A-15'),
  'S-14': ('D', 'deviation 12'),
  # 4. Layout
  'L-04': ('A', ' (non-focused active pane by reading)'),
  'L-07': ('D', 'deviation 6'),
  'L-16': ('D', 'deviation 20'),
  'L-24': ('D', 'deviation 21'),
  'L-29': ('A', ' (cursor shape by reading)'),
  'L-35': ('R', ''),
  'L-36': ('R', ''),
  'L-40': ('D', 'deviation 2, 35'),
  'L-42': ('D', 'deviation 5'),
  # 5. Keys
  'K-20…K-26': ('D', 'deviation 31, 32'),
  'K-31': ('D', 'deviation 24, ruling A-15'),
  'K-32': ('A', ' (header tooltips by reading)'),
  # 6. Files
  'F-03': ('D', 'deviation 28'),
  'F-24': ('D', 'ruling A-17'),
  'F-31': ('D', 'deviation 28'),
  'F-33': ('D', 'deviation 33'),
  'F-37': ('D', 'deviation 29'),
  'F-39': ('D', 'deviation 43'),
  'F-42': ('P', f're-check PARTLY (scroll lost when the open file changes); deviation 54 {R2}'),
  'F-54': ('R', ' (real drag and drop not possible headlessly)'),
  'F-58': ('R', ' (real drag and drop not possible headlessly)'),
  # 7. Connections
  'X-01': ('P', f'deviation 1, 3, 7 matched at audit; re-check found duplicate ids (N2); deviation 48 {R2}'),
  'X-02': ('D', 'ruling N-13, deviation 38'),
  'X-03': ('P', f'port check looser than deviation 39 at re-check (N7); {R2}'),
  'X-09': ('D', 'deviation 3, 22'),
  'X-10': ('D', 'deviation 37'),
  'X-11': ('D', 'deviation 9'),
  'X-13': ('R', ' (backend name not observable headlessly)'),
  'X-15': ('D', 'deviation 1'),
  'X-16': ('D', 'deviation 1, 9'),
  'X-18': ('D', 'deviation 8, 36'),
  'X-31': ('R', ''),
  'X-32': ('D', 'deviation 4'),
  'X-40': ('N', 'macOS only, N-12'),
  'X-41': ('N', 'macOS only, N-12'),
  # 9. Chrome
  'W-05': ('P', f'judged by reading; re-check found the ☰ menu leaves no keyboard focus (N1); {R2}'),
  'W-11': ('P', f'overflow judged from CSS; re-check found long names widen the window (N3); {R2}'),
  'W-14': ('D', 'deviation 23'),
  'W-15': ('A', ' (hover by reading)'),
  'W-19': ('R', ''),
  'W-21': ('P', f're-check found the detail line not ellipsised (N3); {R2}'),
  'W-27': ('D', 'deviation 1, ruling A-05'),
  'W-30': ('D', 'deviation 23'),
  'W-31': ('D', 'ruling A-05'),
  'W-40': ('D', 'ruling N-16'),
  'W-42': ('P', f'judged by reading; re-check found Edit items act on nothing from the real ☰ menu (N1); {R2}'),
  'W-43': ('D', 'ruling A-15, N-11'),
  'W-44': ('D', 'deviation 25'),
  'W-45': ('A', ' (Minimize by reading)'),
  # 10. Settings
  'E-10': ('D', 'deviation 32'),
  'E-12': ('D', 'deviation 27'),
  # 11. Log
  'G-07': ('D', 'deviation 34'),
  'G-29': ('R', ''),
  # 13. Protocol
  'P-27': ('R', ' (slow-consumer disconnect could not be provoked)'),
}

SECTIONS = OrderedDict([
  ('T', '1. Terminal pane'), ('C', '2. Clipboard, paste, links'), ('S', '3. Session lifecycle'),
  ('L', '4. Layout'), ('K', '5. Keyboard shortcuts'), ('F', '6. File browser'),
  ('X', '7. Connections'), ('D', '8. Deploy'), ('W', '9. Window chrome'), ('E', '10. Settings'),
  ('G', '11. Connection log'), ('M', '12. Status messages, modals'), ('P', '13. Wire protocol'),
  ('H', '14. Host shims'),
])

BOX = {'A': 'x', 'D': 'x', 'P': '~', 'R': '~', 'O': ' ', 'Q': ' ', 'N': '-'}

def tag(cat, text):
    if cat == 'A': return '✅ audited' + text
    if cat == 'D': return '✅ ' + text
    if cat == 'P': return '⚠ partly: ' + text
    if cat == 'R': return '👁 by reading only' + text
    if cat == 'O': return '❌ open: ' + text
    if cat == 'Q': return '❓ no audit record'
    if cat == 'N': return f'n/a ({text})'

src = open(PATH, encoding='utf-8').read()
lines = src.split('\n')
assert not any(l.startswith('- [x]') or l.startswith('- [~]') or l.startswith('- [-]') for l in lines), 'already ticked'
counts = {s: Counter() for s in SECTIONS}
lists = {c: [] for c in 'POQRN'}
used = set()
out = []
item_re = re.compile(r'^- \[ \] \*\*([A-Z]-\d+(?:…[A-Z]-\d+)?)\*\*')
for l in lines:
    m = item_re.match(l)
    if m:
        i = m.group(1)
        cat, text = OV.get(i, ('A', ''))
        used.add(i)
        l = f'- [{BOX[cat]}]' + l[5:] + ' — ' + tag(cat, text)
        counts[i[0]][cat] += 1
        if cat in lists: lists[cat].append(i)
    out.append(l)
assert set(OV) <= used, set(OV) - used
total = sum(sum(c.values()) for c in counts.values())
assert total == 317, total

# Rulings on Ambiguities / Not carried over
RUL = {
 'A-01': 'follow the code (the comment is stale)',
 'A-02': 'follow the code (the docs are stale)',
 'A-03': 'add Ctrl+Shift+C to copy the terminal selection (not a pane chord)',
 'A-04': 'Ctrl+Shift+V paste is a requirement, alongside Ctrl+V',
 'A-05': 'native wording ("system keyring", "file manager")',
 'A-06': 'follow the code (the doc is stale)',
 'A-07': 'fix, do not copy: retry the session-list fetch with backoff while connected, and show the state meanwhile',
 'A-08': 'fix: a failed session create shows a status message',
 'A-09': 'dead style; an exited terminal is not dimmed',
 'A-10': 'native wording, no mention of browsers or right-click paste',
 'A-11': 'convert an unsupported image to PNG before sending',
 'A-12': 'theme list and validation live in the settings model; unknown ids fall back to dark',
 'A-13': 'file-browser panes count in the pane total',
 'A-14': 'sync to the visible host on window focus and whenever the visible host changes',
 'A-15': 'no reload command, Reconnect covers it; full screen and Quit live in the menu and take no terminal keys',
 'A-16': 'show the "cleared" marker',
 'A-17': 'keep Backspace as a delete key',
 'N-13': 'own config path, no legacy migrations; on first run without config.json, import profiles from the Electron client\'s config (no passwords, no localPort); the clients can run side by side',
 'N-16': 'a header-bar menu button with the same items replaces the Alt-tap menu bar',
}
for n in [1,2,3,4,5,6,7,8,9,10,11,12,14,15]:
    RUL[f'N-{n:02d}'] = 'accepted as not carried over; the outcomes it served stay'
seen = set()
res = []
in_tail = False
for l in out:
    if l.startswith('## Ambiguities'): in_tail = True
    m = re.match(r'^- \*\*([AN]-\d+)\*\*', l)
    if in_tail and m:
        k = m.group(1); seen.add(k)
        l = l + ' → ruled: ' + RUL[k] + '.'
    res.append(l)
assert seen == set(RUL), set(RUL) ^ seen

# Status section
cols = [('A', '✅ audited'), ('D', '✅ deviation / ruling'), ('P', '⚠ partly'), ('R', '👁 reading only'),
        ('O', '❌ open'), ('Q', '❓ no record'), ('N', 'n/a')]
tbl = ['| Section | ' + ' | '.join(c[1] for c in cols) + ' | Items |',
       '| --- | ' + ' | '.join('---:' for _ in cols) + ' | ---: |']
tot = Counter()
for s, name in SECTIONS.items():
    c = counts[s]; tot.update(c)
    tbl.append(f'| {name} | ' + ' | '.join(str(c[k]) for k, _ in cols) + f' | {sum(c.values())} |')
tbl.append('| **Total** | ' + ' | '.join(f'**{tot[k]}**' for k, _ in cols) + f' | **{sum(tot.values())}** |')

def fmt(lst): return ', '.join(lst) if lst else 'none'
status = f'''## Status

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

{chr(10).join(tbl)}

- **Open:** {fmt(lists['O'])}.
- **Partly:** {fmt(lists['P'])}. Every one of these was fixed in the second
  fix round and waits for the final check.
- **Judged by reading only:** {fmt(lists['R'])}.
- **No audit record:** {fmt(lists['Q'])}.
- **Not applicable:** {fmt(lists['N'])} (macOS only).

K-01…K-15 and K-20…K-26 are one checklist item each; the audit gave each
binding its own row, all of which passed.
'''
text = '\n'.join(res)
anchor = '# webmux native client: feature-parity checklist\n'
assert text.startswith(anchor)
text = anchor + '\n' + status + text[len(anchor):]
open(PATH, 'w', encoding='utf-8').write(text)
print('\n'.join(tbl))
for k in lists: print(k, lists[k])
