/* webmux client — scrolling column layout (niri / PaperWM style).
   The workspace is a horizontal strip of columns; each column is a vertical
   stack of panes, each pane one tile. Columns are at least a configurable
   number of terminal cells wide (settings: minCols) and at least half the
   window: while every column fits they share the viewport equally, past
   that each stays at the minimum and the strip scrolls sideways, following
   the focused pane. Heights
   within a column are drag-resizable; widths follow the rule. Everything is
   keyboard-driven (⌘↩ new terminal, ⌥⌘↩ terminal below, ⌘⇧↩ new file browser, ⌘W close, ⌘F
   full-window toggle, ⌘+arrows/hjkl to focus, ⇧⌘ to move a column or a
   pane within its stack, ⌥⌘ to merge a lone pane into the neighbouring
   column or split a stacked one out — see paneCommandForKey). Sessions live on the server; the layout is saved to
   localStorage — per origin, so per host and per client — and a reload
   restores both the sessions (from headless snapshots) and the arrangement.

   Panes hold either a terminal session (id from the server) or a
   client-side widget (id `files-<random>`, the Miller-columns file browser
   implemented in files-widget.js). Both kinds are represented by a "tile"
   with the same interface: { root, openIfNeeded(), fitAndReport(), focus(),
   term?, ws?, label?() }. */

import {
  isFilesId, createFilesWidget, makeFilesTile, discardWidgetState, pruneWidgetStates,
} from './files-widget.js';
import { API, WS_BASE } from './env.js';
import {
  THEMES, getSettings, themeOf, loadSettings, updateSettings, onSettingsChange,
} from './settings.js';
import { logDebug, logInfo, logWarn, logError, openLogWindow } from './log.js';

const layoutEl = document.getElementById('layout');
const tiles = new Map(); // sessionId -> tile
const MIN_PANE_PX = 110;
const TERM_FONT = '"JetBrainsMono Nerd Font", monospace';

// layout: columns[] of { panes:[id], sizes:[weight], active:id, full? }.
// sizes are flex weights for the stack (parallel to panes); active is the
// pane that takes focus when the column is entered from the side; full
// marks a column that spans the whole window (⌘F) instead of the width rule.
let columns = [];
let focusedId = null; // pane (tile id) that last had user interaction

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

const newColumn = (id) => ({ panes: [id], sizes: [1], active: id });

const allIds = () => columns.flatMap((c) => c.panes);
const columnIndexOf = (id) => columns.findIndex((c) => c.panes.includes(id));
const columnOf = (id) => columns[columnIndexOf(id)] || null;

// The new pane gets the column's average weight, i.e. an equal share of a
// column that was evenly split and a middling one of a resized one.
function insertIntoColumn(col, id, index = col.panes.length) {
  const avg = col.sizes.length ? col.sizes.reduce((s, w) => s + w, 0) / col.sizes.length : 1;
  col.panes.splice(index, 0, id);
  col.sizes.splice(index, 0, avg);
  col.active = id;
}

// Removes the pane; an emptied column disappears with it.
function removeFromColumn(id) {
  const ci = columnIndexOf(id);
  if (ci === -1) return;
  const col = columns[ci];
  const i = col.panes.indexOf(id);
  col.panes.splice(i, 1);
  col.sizes.splice(i, 1);
  if (!col.panes.length) columns.splice(ci, 1);
  else if (col.active === id) col.active = col.panes[Math.min(i, col.panes.length - 1)];
}

// The pane that should take focus once `id` goes away: the next one down
// its stack, else the one above, else the neighbouring column's active pane.
function focusAfterRemoval(id) {
  const ci = columnIndexOf(id);
  if (ci === -1) return null;
  const col = columns[ci];
  const i = col.panes.indexOf(id);
  return col.panes[i + 1] ?? col.panes[i - 1]
    ?? columns[ci + 1]?.active ?? columns[ci - 1]?.active ?? null;
}

function removeSessionFromLayout(id) {
  if (focusedId === id) focusedId = focusAfterRemoval(id);
  removeFromColumn(id);
}

// The layout stays in localStorage, i.e. per client *and* per host: storage
// is keyed by origin, and the Electron client serves this page on a
// webmux://<host-slug> origin derived from the profile's host+instance, so
// different clients keep the layouts that fit their own screens.
function saveLayout() {
  localStorage.setItem('webmux-layout', JSON.stringify({ columns, focused: focusedId }));
}

// Accepts the split-tree formats that preceded columns and converts them:
// side-by-side splits become adjacent columns, a stacked split of two
// single columns becomes one stack (heights from the split ratio), and a
// pane's tabs each become a pane of their own.
function columnsFromTree(node) {
  if (!node || !node.type) return [];
  if (node.type === 'pane') {
    const ids = node.session != null ? [node.session] : (Array.isArray(node.tabs) ? node.tabs : []);
    if (!ids.length) return [];
    return [{ panes: [...ids], sizes: ids.map(() => 1), active: ids.includes(node.active) ? node.active : ids[0] }];
  }
  const a = columnsFromTree(node.a);
  const b = columnsFromTree(node.b);
  if (node.dir === 'col' && a.length === 1 && b.length === 1) {
    const ratio = Number(node.ratio) > 0 && Number(node.ratio) < 1 ? Number(node.ratio) : 0.5;
    const scale = (sizes, share) => {
      const sum = sizes.reduce((s, w) => s + w, 0) || 1;
      return sizes.map((w) => (w / sum) * share);
    };
    return [{
      panes: [...a[0].panes, ...b[0].panes],
      sizes: [...scale(a[0].sizes, ratio), ...scale(b[0].sizes, 1 - ratio)],
      active: a[0].active,
    }];
  }
  return [...a, ...b];
}

// Anything from storage is untrusted-ish: drop malformed columns and
// duplicate ids, normalise weights, and make sure `active` points at a pane.
function sanitizeColumns(raw) {
  const seen = new Set();
  const out = [];
  for (const col of Array.isArray(raw) ? raw : []) {
    if (!col || !Array.isArray(col.panes)) continue;
    const panes = [];
    const sizes = [];
    col.panes.forEach((id, i) => {
      if ((typeof id !== 'string' && typeof id !== 'number') || seen.has(id)) return;
      seen.add(id);
      panes.push(id);
      const w = Number(Array.isArray(col.sizes) ? col.sizes[i] : 1);
      sizes.push(Number.isFinite(w) && w > 0 ? w : 1);
    });
    if (!panes.length) continue;
    out.push({ panes, sizes, active: panes.includes(col.active) ? col.active : panes[0], full: col.full === true });
  }
  return out;
}

// Returns { columns, focused }; focused may name a pane that no longer exists.
function loadLayout() {
  try {
    const raw = JSON.parse(localStorage.getItem('webmux-layout'));
    if (raw && Array.isArray(raw.columns)) return { columns: sanitizeColumns(raw.columns), focused: raw.focused ?? null };
    return { columns: sanitizeColumns(columnsFromTree(raw)), focused: null }; // pre-columns split tree
  } catch { return { columns: [], focused: null }; }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Structural render: rebuilds the strip. Focus changes alone don't come
// through here (setFocus just retargets classes), so the terminals aren't
// re-attached — and re-fitted — for every ⌘←.
function render() {
  if (!allIds().includes(focusedId)) focusedId = columns[0]?.active ?? null;
  const scrollLeft = layoutEl.scrollLeft; // replaceChildren would reset it
  layoutEl.replaceChildren();
  for (const col of columns) layoutEl.appendChild(buildColumn(col));
  layoutEl.scrollLeft = scrollLeft;
  // xterm needs its element in the DOM before open(); open any new tiles now.
  for (const tile of tiles.values()) tile.openIfNeeded();
  applyColumnWidths();
  fitAll();
  updateTitle();
  revealFocused();
}

// The title is this page's one channel to the Electron client (main.js
// page-title-updated): the pane count, which it totals across hosts in the
// window title, and an offline marker while any session socket is down and
// retrying — its pill would otherwise stay green over a terminal saying
// "disconnected", because the ssh tunnel it supervises can outlive the
// server behind it.
let linkDown = false;
function updateTitle() {
  document.title = `webmux — ${tiles.size} pane${tiles.size === 1 ? '' : 's'}${linkDown ? ' · offline' : ''}`;
}
function setLinkDown(down) {
  if (linkDown === down) return;
  linkDown = down;
  if (down) logWarn('link down — a session socket dropped and is retrying');
  else logInfo('link up — a session socket is open again');
  updateTitle();
}

function buildColumn(col) {
  const el = document.createElement('div');
  el.className = 'column' + (col.full ? ' full' : '');
  col.panes.forEach((id, i) => {
    if (i) el.appendChild(makeDivider(col, i - 1));
    el.appendChild(buildPane(id, paneFlex(col, i)));
  });
  return el;
}

// Stack weights as a flex shorthand, normalised to sum to 1: flex-grow
// totals below 1 leave part of the container unfilled, so a lone survivor
// of a resized stack (weight 0.3) would otherwise sit in 30% of its column.
function paneFlex(col, i) {
  const sum = col.sizes.reduce((s, w) => s + w, 0) || 1;
  return `${col.sizes[i] / sum} 1 0`;
}

// Subtle monochrome pane-type markers (stroke follows the title's text color).
const PANE_ICON_SVG = {
  term: `<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor"
    stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"
    ><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>`,
  files: `<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor"
    stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"
    ><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`,
};

function buildPane(id, flex) {
  const el = document.createElement('div');
  el.className = 'pane';
  el.dataset.id = id;
  el.style.flex = flex;

  const bar = document.createElement('div');
  bar.className = 'pane-bar';
  bar.title = isFilesId(id) ? 'file browser' : `session ${id}`;

  const tile = tiles.get(id);
  const icon = document.createElement('span');
  icon.className = 'pane-icon';
  icon.innerHTML = PANE_ICON_SVG[isFilesId(id) ? 'files' : 'term'];
  const label = document.createElement('span');
  label.className = 'pane-label';
  label.textContent = tile?.label ? tile.label() : id;
  if (tile) tile.labelEl = label; // files tiles retitle themselves as you navigate
  const close = document.createElement('button');
  close.className = 'pane-close';
  close.title = isFilesId(id) ? 'Close' : 'Kill session';
  close.textContent = '✕';
  close.addEventListener('click', (ev) => {
    ev.stopPropagation();
    removeTile(id, true);
  });
  bar.append(icon, label, close);
  // Clicking the bar (not ✕) focuses the pane's content, like clicking in it.
  bar.addEventListener('click', () => tiles.get(id)?.focus());

  const body = document.createElement('div');
  body.className = 'pane-body';
  if (tile) body.appendChild(tile.root);

  el.append(bar, body);
  el.classList.toggle('focused', id === focusedId);
  el.addEventListener('pointerdown', () => setFocus(id), true);
  return el;
}

const paneEl = (id) => layoutEl.querySelector(`.pane[data-id="${CSS.escape(String(id))}"]`);

// Focus bookkeeping: the column remembers it as its active pane (so ⌘←/→
// return to it), the border moves, and the strip scrolls it into view.
// focusTile additionally puts keyboard focus in the content — needed for
// the keyboard paths; a pointerdown focuses the terminal on its own.
function setFocus(id, { focusTile = false } = {}) {
  const col = columnOf(id);
  if (!col) return;
  if (focusedId !== id || col.active !== id) {
    focusedId = id;
    col.active = id;
    layoutEl.querySelectorAll('.pane.focused').forEach((p) => p.classList.remove('focused'));
    paneEl(id)?.classList.add('focused');
    saveLayout();
  }
  revealFocused();
  if (focusTile) tiles.get(id)?.focus();
}

// Scroll the strip the minimum distance that shows the focused column in
// full (niri's default), never re-centering a column already on screen.
// Deferred a frame: focusing a pane's content (a terminal's hidden
// textarea, whether by click or from the keyboard paths) makes the browser
// scroll the strip instantly to show it, which would fight the animation
// here — let that land first, then take over.
let revealQueued = false;
function revealFocused() {
  if (revealQueued) return;
  revealQueued = true;
  requestAnimationFrame(() => {
    revealQueued = false;
    revealFocusedNow();
  });
}
function revealFocusedNow() {
  const colEl = paneEl(focusedId)?.parentElement;
  if (!colEl) return;
  const pad = 6; // #layout padding, so the pane border isn't flush with the edge
  const left = colEl.offsetLeft - pad;
  const right = colEl.offsetLeft + colEl.offsetWidth + pad;
  const view = layoutEl.clientWidth;
  // Judge visibility against where the strip is heading, not where it is:
  // a focus change mid-flight must not leave the column visible only until
  // the previous animation finishes pushing it away.
  let target = chase ? chase.target : layoutEl.scrollLeft;
  if (left < target) target = left;
  else if (right > target + view) target = right - view;
  scrollStripTo(target);
}

// Strip animation: chase the target with an exponential approach (the
// step each frame is a fixed fraction of the remaining distance, so it is
// fast when far and settles gently), tracking our own fractional position
// because scrollLeft rounds. A new target mid-flight just redirects the
// chase from wherever it is — no restart, no snap. A wheel pan cancels it.
const SCROLL_TAU_MS = 60; // time constant; ~95% of the way in 3τ
let chase = null; // { target, pos, last } while animating
function scrollStripTo(target) {
  target = Math.max(0, Math.min(Math.round(target), layoutEl.scrollWidth - layoutEl.clientWidth));
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    chase = null;
    layoutEl.scrollLeft = target;
    return;
  }
  if (chase) { chase.target = target; return; }
  if (target === layoutEl.scrollLeft) return;
  chase = { target, pos: layoutEl.scrollLeft, last: performance.now() };
  requestAnimationFrame(chaseStep);
}
function chaseStep(now) {
  if (!chase) return;
  const dt = Math.min(now - chase.last, 100); // a stalled tab doesn't teleport
  chase.last = now;
  const diff = chase.target - chase.pos;
  if (Math.abs(diff) < 0.5) {
    layoutEl.scrollLeft = chase.target;
    chase = null;
    return;
  }
  const k = 1 - Math.exp(-dt / SCROLL_TAU_MS);
  chase.pos += Math.sign(diff) * Math.max(Math.abs(diff) * k, Math.min(1, Math.abs(diff)));
  layoutEl.scrollLeft = chase.pos;
  requestAnimationFrame(chaseStep);
}

// Column width rule: every column is at least minCols terminal cells wide
// (plus the pane chrome around the grid) and at least half the strip, so
// two columns at most share the window side by side. With flex-grow the
// columns share any spare viewport width equally, and with flex-shrink 0
// they overflow into a horizontal scroll rather than squeezing below the
// minimum. A window narrower than the cell minimum caps a column at the
// viewport (the min(…, 100%) in the stylesheet) so it stays entirely
// visible.
let cellWidth = 0;
function measureCell() {
  const probe = document.createElement('span');
  probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font:13px ${TERM_FONT}`;
  probe.textContent = 'W'.repeat(100);
  document.body.appendChild(probe);
  cellWidth = probe.getBoundingClientRect().width / 100;
  probe.remove();
}
// Pane border (2) + term-holder padding (8) + xterm's viewport scrollbar (10)
// + a little rounding slack, so minCols cells really fit.
const PANE_CHROME_PX = 2 + 8 + 10 + 4;
function applyColumnWidths() {
  if (!cellWidth) measureCell();
  const cells = Math.ceil(getSettings().minCols * cellWidth) + PANE_CHROME_PX;
  const half = Math.floor((layoutEl.clientWidth - 12 - 6) / 2); // minus padding and one gap
  layoutEl.style.setProperty('--col-min', `${Math.max(cells, half)}px`);
}

// Divider between panes i and i+1 of a column: dragging reassigns the
// pair's combined weight.
function makeDivider(col, i) {
  const div = document.createElement('div');
  div.className = 'divider';
  div.addEventListener('pointerdown', (down) => {
    down.preventDefault();
    div.setPointerCapture(down.pointerId);
    const elA = div.previousElementSibling;
    const elB = div.nextElementSibling;
    const sum = col.sizes[i] + col.sizes[i + 1];

    const onMove = (ev) => {
      const top = elA.getBoundingClientRect().top;
      const size = elB.getBoundingClientRect().bottom - top;
      const min = Math.min(MIN_PANE_PX / size, 0.45);
      const ratio = Math.min(1 - min, Math.max(min, (ev.clientY - top) / size));
      col.sizes[i] = sum * ratio;
      col.sizes[i + 1] = sum * (1 - ratio);
      elA.style.flex = paneFlex(col, i);
      elB.style.flex = paneFlex(col, i + 1);
      fitAll();
    };
    const onUp = () => {
      div.removeEventListener('pointermove', onMove);
      div.removeEventListener('pointerup', onUp);
      fitAll();
      saveLayout();
    };
    div.addEventListener('pointermove', onMove);
    div.addEventListener('pointerup', onUp);
  });
  return div;
}

let fitQueued = false;
function fitAll() {
  if (fitQueued) return;
  fitQueued = true;
  requestAnimationFrame(() => {
    fitQueued = false;
    for (const tile of tiles.values()) tile.fitAndReport();
  });
}

// Transient status messages (clipboard syncs, upload progress, errors) show
// as a self-dismissing toast. Exported for files-widget.js.
let toastTimer;
export function setStatus(text) {
  const el = document.getElementById('toast');
  el.textContent = text;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 3000);
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(',', 2)[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

// Proactive clipboard sync: browsers have no clipboardchange event, but
// regaining window focus is the moment right after a copy elsewhere (e.g. a
// screenshot tool). Push any new clipboard image to the server's clipboard
// slot so shim reads are fresh even if a bare ^V slips through to a CLI.
let lastSyncedImage = '';
let lastSyncAt = 0;
async function syncClipboardImage() {
  if (!navigator.clipboard?.read || Date.now() - lastSyncAt < 1000) return;
  lastSyncAt = Date.now();
  try {
    const items = await navigator.clipboard.read();
    for (const item of items) {
      const type = item.types.find((t) => t.startsWith('image/'));
      if (!type) continue;
      const base64 = await blobToBase64(await item.getType(type));
      if (base64 === lastSyncedImage) return;
      lastSyncedImage = base64;
      const ws = [...tiles.values()].find((t) => t.ws?.readyState === WebSocket.OPEN)?.ws;
      if (ws) {
        ws.send(JSON.stringify({ type: 'clipboard-sync', mime: type, data: base64 }));
        setStatus('clipboard image synced to sessions');
      }
      return;
    }
  } catch { /* permission not granted (yet) — Ctrl+V interception still covers it */ }
}
window.addEventListener('focus', syncClipboardImage);

// Write text to the host (browser) clipboard, for OSC 52 copies from
// programs in a session. The async API needs a secure context; fall back to
// the legacy execCommand path on plain http.
async function writeHostClipboard(text, doneMsg = 'clipboard set from terminal') {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      setStatus(doneMsg);
      return;
    }
  } catch { /* fall through to execCommand */ }
  const prevFocus = document.activeElement;
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch {}
  ta.remove();
  prevFocus?.focus?.();
  setStatus(ok ? doneMsg : 'clipboard write blocked by the browser');
}

// 'open-url' frames the server could not target at one session are broadcast
// on every tab's socket; remember served ids so the chooser pops only once.
const seenOpenIds = new Set();

// Hand a URL to the system browser. The page runs inside the Electron
// client, where window.open never opens in-window: the client's
// window-open handler routes http(s) URLs to shell.openExternal.
const openInBrowser = (uri) => window.open(uri, '_blank', 'noopener');
const copyLink = (uri) => writeHostClipboard(uri, 'link copied');

// Clicking a detected URL (terminal web-links / OSC 8, markdown previews)
// opens it in the browser straight away; shift-click copies it instead.
export function activateLink(ev, uri) {
  if (ev.shiftKey) copyLink(uri);
  else openInBrowser(uri);
}

// Open/copy chooser for URLs that arrive without a click — a program in a
// session ran xdg-open (see the 'open-url' handler in Tile) — so there is
// no modifier to express intent. Returns focus to the tile on close. Also
// used by the file browser for mailto: links, which the shell won't open.
export function showLinkModal(uri, tile) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal link-modal" role="dialog" aria-label="Link options">
      <div class="link-url"></div>
      <div class="actions">
        <button class="link-cancel">Cancel</button>
        <button class="link-copy">Copy</button>
        <button class="link-open primary">Open in browser</button>
      </div>
    </div>`;
  overlay.querySelector('.link-url').textContent = uri;

  const close = () => {
    overlay.remove();
    document.removeEventListener('keydown', onKey, true);
    tile?.focus();
  };
  const onKey = (ev) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      close();
    }
  };
  document.addEventListener('keydown', onKey, true);
  overlay.addEventListener('click', (ev) => {
    if (ev.target === overlay) close();
  });
  overlay.querySelector('.link-cancel').addEventListener('click', close);
  overlay.querySelector('.link-copy').addEventListener('click', () => {
    close(); // close first: execCommand fallback needs focus off the modal
    copyLink(uri);
  });
  overlay.querySelector('.link-open').addEventListener('click', () => {
    openInBrowser(uri);
    close();
  });

  document.body.appendChild(overlay);
  overlay.querySelector('.link-open').focus();
}

// Client-wide settings panel (⚙ in the header, ⌘, in the client). Every
// control applies live; the store write (settings.js) is what makes the
// change client-wide, so the slider only persists on release.
let settingsOverlay = null;
function showSettingsModal() {
  if (settingsOverlay) return;
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal settings-modal" role="dialog" aria-label="Settings">
      <h2>Settings</h2>
      <p class="lead">Apply to every host on this client.</p>
      <label class="setting">
        <span class="setting-label">Color scheme</span>
        <span class="setting-control"><select class="theme-select"></select></span>
      </label>
      <label class="setting">
        <span class="setting-label">Unfocused pane fade</span>
        <span class="setting-control">
          <input class="fade-range" type="range" min="0" max="100" step="5" />
          <output class="fade-value"></output>
        </span>
        <span class="setting-desc">How much panes other than the focused one dim. 0% leaves them untouched.</span>
      </label>
      <label class="setting">
        <span class="setting-label">Minimum terminal width</span>
        <span class="setting-control">
          <input class="cols-input" type="number" min="40" max="400" step="1" />
          <span class="setting-unit">columns</span>
        </span>
        <span class="setting-desc">Every column is at least this many characters wide, and never narrower than half the window. Columns share the window while they fit; past that the layout scrolls sideways.</span>
      </label>
      <div class="setting">
        <span class="setting-label">Connection log</span>
        <span class="setting-control"><button type="button" class="log-open">Open log…</button></span>
        <span class="setting-desc">Tunnel setup, teardown, and reconnect events for every host on this client, live and copyable. Also written to a file on disk.</span>
      </div>
      <div class="actions">
        <button class="settings-close primary">Done</button>
      </div>
    </div>`;
  const select = overlay.querySelector('.theme-select');
  for (const [id, theme] of Object.entries(THEMES)) {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = theme.label;
    select.appendChild(opt);
  }
  const range = overlay.querySelector('.fade-range');
  const value = overlay.querySelector('.fade-value');
  const cols = overlay.querySelector('.cols-input');
  const sync = (s) => {
    select.value = s.theme;
    range.value = s.unfocusedFade;
    value.textContent = `${s.unfocusedFade}%`;
    if (document.activeElement !== cols) cols.value = s.minCols;
  };
  sync(getSettings());
  const unsubscribe = onSettingsChange(sync); // a push from another host's page

  const close = () => {
    unsubscribe();
    overlay.remove();
    settingsOverlay = null;
    document.removeEventListener('keydown', onKey, true);
    tiles.get(focusedId)?.focus();
  };
  const onKey = (ev) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      close();
    }
  };
  document.addEventListener('keydown', onKey, true);
  overlay.addEventListener('click', (ev) => {
    if (ev.target === overlay) close();
  });
  select.addEventListener('change', () => updateSettings({ theme: select.value }));
  range.addEventListener('input', () => {
    value.textContent = `${range.value}%`;
    updateSettings({ unfocusedFade: range.value }, { persist: false });
  });
  range.addEventListener('change', () => updateSettings({ unfocusedFade: range.value }));
  cols.addEventListener('change', () => {
    updateSettings({ minCols: cols.value });
    cols.value = getSettings().minCols; // show the clamped value
  });
  overlay.querySelector('.settings-close').addEventListener('click', close);
  overlay.querySelector('.log-open').addEventListener('click', async () => {
    if (!(await openLogWindow())) setStatus('the log window is part of the Electron client — see the browser console here');
  });

  settingsOverlay = overlay;
  document.body.appendChild(overlay);
  select.focus();
}

// The terminal canvas doesn't see CSS variables: repaint every open
// terminal's palette when the color scheme changes.
onSettingsChange((s) => {
  const theme = themeOf(s).xterm;
  for (const tile of tiles.values()) {
    if (tile.term) tile.term.options.theme = theme;
  }
});

// ---------------------------------------------------------------------------
// Tiles (terminal DOM + xterm + websocket, one per session)
// ---------------------------------------------------------------------------

function makeTile(sessionId) {
  const root = document.createElement('div');
  root.className = 'tile';
  root.innerHTML = `<div class="term-holder"></div>`;

  const tile = {
    root,
    term: null,
    fit: null,
    ws: null,
    attempts: 0, // socket connects this page has made for the session
    exited: false,
    dead: false, // tile removed — suppresses the reconnect loop
    online: false,
    sticky: true, // follow new output (manual stick — see the onScroll hook)
    prevScrollY: 0,
    retryDelay: 0,
    title: '',
    label() { return this.title || sessionId; },
    setTitle(title) {
      this.title = title || '';
      if (this.labelEl) this.labelEl.textContent = this.label();
    },
    focus() { this.term?.focus(); },
    openIfNeeded() {
      if (this.term || !root.isConnected) return;

      const term = new Terminal({
        cursorBlink: true,
        fontFamily: TERM_FONT,
        fontSize: 13,
        scrollback: 5000,
        theme: themeOf().xterm,
        // OSC 8 hyperlinks (Claude Code's /login URL, `ls --hyperlink`, gh)
        // are handled by xterm's built-in OscLinkProvider, not the web-links
        // addon below. Without this option its fallback is window.confirm()
        // followed by a URL-less window.open(), which the Electron shell
        // denies — so the native "Do you want to navigate…" sheet appeared
        // and OK did nothing. Route them like plain URLs: open, ⇧ copies.
        linkHandler: {
          activate: activateLink,
          allowNonHttpProtocols: false, // mailto:, file: etc. stay inert
        },
      });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);

      // URL detection: the web-links addon underlines http(s) URLs on hover;
      // a click opens the URL in the system browser, shift-click copies it.
      term.loadAddon(new WebLinksAddon.WebLinksAddon((ev, uri) => {
        ev.preventDefault();
        activateLink(ev, uri);
      }));

      // OSC 52 (ESC ] 52 ; <target> ; <base64> BEL): programs setting the
      // terminal clipboard land on the browser host's clipboard. Reads
      // ("?" payload) are ignored — answering would expose the clipboard to
      // anything running in any session.
      term.parser.registerOscHandler(52, (data) => {
        const payload = data.slice(data.indexOf(';') + 1);
        if (payload === '?') return true;
        try {
          const bytes = Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
          writeHostClipboard(new TextDecoder().decode(bytes));
        } catch { /* malformed base64 — ignore */ }
        return true;
      });

      term.open(root.querySelector('.term-holder'));
      this.term = term;
      this.fit = fit;

      // GPU rendering: xterm's default DOM renderer rebuilds row elements
      // on every repaint, which is the main-thread cost that shows with
      // several visible splits (and several hosts). The WebGL addon draws
      // from a glyph atlas instead; it must load after open(). Chromium
      // caps live WebGL contexts per process (16) and evicts the oldest
      // past that, and the GPU process can drop contexts on its own — in
      // either case dispose the addon and xterm falls back to the DOM
      // renderer for that terminal, which is exactly the status quo.
      try {
        const webgl = new WebglAddon.WebglAddon();
        webgl.onContextLoss(() => {
          logWarn('webgl context lost — terminal falls back to the DOM renderer', { session: sessionId });
          webgl.dispose();
        });
        term.loadAddon(webgl);
      } catch (err) {
        logWarn('webgl renderer unavailable — using the DOM renderer', { session: sessionId, error: String(err.message || err) });
      }

      // Manual scroll stickiness: xterm follows new output only when the
      // viewport sits *exactly* on the last line, so a scroll that lands a
      // hair short leaves the terminal silently unstuck. Instead, keep a
      // sticky flag: a downward scroll landing within a few lines of the
      // bottom turns it on (and snaps the rest of the way); scrolling up
      // turns it off, so scrolling back to read never gets yanked down.
      // The band is screen-relative, not scrollback-relative — a % of the
      // whole buffer would span hundreds of lines, and wheel momentum
      // jitter (a stray downward tick at the end of an upward flick) would
      // re-stick from way up. Output writes re-assert the stick (see the
      // 'output' handler).
      term.onScroll((y) => {
        const bottom = term.buffer.active.baseY;
        const nearBottom = bottom - y <= Math.max(3, Math.round(term.rows * 0.15));
        if (y < this.prevScrollY) this.sticky = false;
        else if (y > this.prevScrollY && nearBottom) this.sticky = true;
        this.prevScrollY = y;
        if (this.sticky && y < bottom) term.scrollToBottom();
      });
      // Wheel-up is unambiguous user intent to leave the bottom — unstick
      // on the gesture itself, not on the scroll events it produces.
      root.querySelector('.term-holder').addEventListener('wheel', (ev) => {
        if (ev.deltaY < 0) this.sticky = false;
      }, { passive: true, capture: true });

      this.connect();

      term.onData((data) => {
        if (this.ws?.readyState === WebSocket.OPEN) {
          this.ws.send(JSON.stringify({ type: 'input', data }));
        }
      });

      // Ctrl+V: xterm would swallow the keydown and send a bare ^V to the
      // pty, making clipboard-reading CLIs see a stale clipboard slot.
      // Returning false (without preventDefault) suppresses xterm's handling
      // but lets the browser's native paste proceed — on Windows/Linux a
      // paste event follows within a few ms carrying the real clipboard, and
      // it works even on insecure origins where navigator.clipboard doesn't
      // exist. If no event arrives (macOS: Ctrl+V isn't a paste shortcut),
      // fall back to the async clipboard API. Ctrl+Alt+V sends a literal ^V
      // (e.g. for vim visual-block mode).
      term.attachCustomKeyEventHandler((ev) => {
        if (ev.type === 'keydown' && ev.key.toLowerCase() === 'v'
            && ev.ctrlKey && !ev.metaKey && !ev.shiftKey) {
          if (ev.altKey) {
            this.ws?.send(JSON.stringify({ type: 'input', data: '\x16' }));
            return false;
          }
          const seen = this.nativePasteCount || 0;
          setTimeout(() => {
            if ((this.nativePasteCount || 0) === seen) this.interceptCtrlV();
          }, 120);
          return false;
        }
        return true;
      });

      // Native paste events (Ctrl+V on Windows/Linux, Cmd+V on macOS,
      // right-click): intercept in capture phase — xterm listens on its
      // hidden textarea. Images go through the upload flow; text falls
      // through to xterm's normal paste handling.
      root.querySelector('.term-holder').addEventListener('paste', (ev) => {
        this.nativePasteCount = (this.nativePasteCount || 0) + 1;
        const item = [...(ev.clipboardData?.items || [])]
          .find((i) => i.type.startsWith('image/'));
        if (!item) return;
        ev.preventDefault();
        ev.stopPropagation();
        this.pasteImage(item.getAsFile());
      }, true);

      term.focus();
    },
    // (Re)establish the WebSocket for this session. The server sends a full
    // snapshot on every attach, so reconnecting after a web-server restart
    // repaints the terminal exactly — the shells live in the pty host and
    // keep running. Retries with backoff until the session exits or the
    // tile is closed.
    connect() {
      const term = this.term;
      const attempt = ++this.attempts;
      const startedAt = Date.now();
      const ws = new WebSocket(`${WS_BASE}/ws?session=${sessionId}`);
      this.ws = ws;
      logDebug(attempt === 1 ? 'session socket connecting' : 'session socket reconnecting', { session: sessionId, attempt });

      ws.onopen = () => {
        this.online = true;
        this.retryDelay = 0;
        logInfo(attempt === 1 ? 'session socket open' : 'session socket reopened', {
          session: sessionId, attempt, ms: Date.now() - startedAt,
        });
        setLinkDown(false);
        this.fitAndReport();
      };
      ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'snapshot') {
          logDebug('snapshot received', { session: sessionId, bytes: msg.data ? msg.data.length : 0 });
          term.reset();
          if (msg.data) term.write(msg.data);
          this.setTitle(msg.title);
          this.fitAndReport();
        } else if (msg.type === 'output') {
          // The callback runs after the chunk is parsed, when baseY is final.
          term.write(msg.data, () => { if (this.sticky) term.scrollToBottom(); });
        } else if (msg.type === 'title') {
          this.setTitle(msg.title);
        } else if (msg.type === 'session-title') {
          // Broadcast for ANY session, muxed over every open socket so
          // background tabs (which have no socket) stay current. Arrives on
          // each open socket; setTitle is idempotent so that's fine.
          tiles.get(msg.session)?.setTitle(msg.title);
        } else if (msg.type === 'exit') {
          this.exited = true;
          logInfo('session exited', { session: sessionId, exitCode: msg.exitCode });
          term.write(`\r\n\x1b[31m[session exited: ${msg.exitCode}]\x1b[0m\r\n`);
          setTimeout(() => removeTile(sessionId, false), 1200);
        } else if (msg.type === 'paste-result') {
          setStatus(msg.mode === 'claude'
            ? 'image in clipboard — Ctrl+V forwarded to Claude'
            : `pasted image → ${msg.path}`);
        } else if (msg.type === 'open-url') {
          // A program in the session ran xdg-open (see shims/): nobody
          // clicked anything, so offer an open/copy chooser.
          if (!seenOpenIds.has(msg.id)) {
            seenOpenIds.add(msg.id);
            showLinkModal(msg.url, this);
          }
        } else if (msg.type === 'error') {
          logWarn('session gone on the host — closing its tab', { session: sessionId, error: msg.error || msg.message });
          removeTile(sessionId, false); // session no longer exists on the host
        }
      };
      ws.onclose = (ev) => {
        if (this.dead || this.exited) {
          logDebug('session socket closed (tab closed or session exited)', { session: sessionId, code: ev.code });
          return;
        }
        setLinkDown(true); // cleared by whichever socket next opens
        const wasOnline = this.online;
        if (this.online) {
          this.online = false;
          term.write('\r\n\x1b[33m[disconnected — reconnecting…]\x1b[0m\r\n');
        }
        this.retryDelay = Math.min((this.retryDelay || 500) * 2, 10000);
        logWarn(wasOnline ? 'session socket dropped — retrying' : 'session socket connect failed — retrying', {
          session: sessionId,
          code: ev.code,
          reason: ev.reason || undefined,
          clean: ev.wasClean,
          upMs: Date.now() - startedAt,
          retryInMs: this.retryDelay,
        });
        setTimeout(() => {
          // this.ws !== ws means something else already reconnected
          if (!this.dead && !this.exited && this.ws === ws) this.connect();
        }, this.retryDelay);
      };
    },
    async pasteImage(file) {
      if (!file || this.ws?.readyState !== WebSocket.OPEN) return;
      setStatus('uploading pasted image…');
      try {
        // Server updates the shim clipboard, then either forwards Ctrl+V to a
        // foreground Claude Code or types the file path into a plain shell.
        const base64 = await blobToBase64(file);
        this.ws.send(JSON.stringify({ type: 'paste-image', mime: file.type, data: base64 }));
      } catch (err) {
        setStatus(`image paste failed: ${err.message || err}`);
      }
    },
    // No native paste event followed Ctrl+V (macOS, or an empty clipboard):
    // read the clipboard through the async API. Image → paste flow; text →
    // normal paste; unavailable or empty → forward a literal ^V.
    async interceptCtrlV() {
      try {
        if (navigator.clipboard?.read) {
          const items = await navigator.clipboard.read();
          for (const item of items) {
            const type = item.types.find((t) => t.startsWith('image/'));
            if (type) return this.pasteImage(await item.getType(type));
          }
          for (const item of items) {
            if (item.types.includes('text/plain')) {
              const text = await (await item.getType('text/plain')).text();
              if (text) return this.term.paste(text);
            }
          }
        } else if (!window.isSecureContext) {
          setStatus('no clipboard API on http origin — pastes rely on native paste events here');
        }
      } catch {
        setStatus('clipboard access blocked — allow it in the browser, or right-click → paste');
      }
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'input', data: '\x16' }));
      }
    },
    fitAndReport() {
      // Background tabs are detached from the DOM; fitting them is
      // meaningless (zero-size) and would corrupt the terminal geometry.
      if (!this.term || !root.isConnected) return;
      try { this.fit.fit(); } catch { return; }
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'resize', cols: this.term.cols, rows: this.term.rows }));
      }
    },
  };

  tiles.set(sessionId, tile);
  return tile;
}

// Closing animation: a pane alone in its column takes the column with it,
// shrinking to zero width with its left edge fixed (the neighbours slide
// in from the right); a stacked pane shrinks to zero height from the
// bottom. The content stays put and is clipped, and nothing is refitted
// until the structural render afterwards. Resolves when done, or at once
// under reduced motion; bounded so a detached element can't stall it.
const CLOSE_MS = 160;
async function animateRemoval(id) {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const pane = paneEl(id);
  const col = columnOf(id);
  if (!pane || !col) return;
  const lone = col.panes.length === 1;
  const el = lone ? pane.parentElement : pane;
  const size = lone ? el.getBoundingClientRect().width : el.getBoundingClientRect().height;
  if (!lone) {
    const divider = pane.previousElementSibling || pane.nextElementSibling;
    if (divider?.classList.contains('divider')) divider.style.display = 'none';
  }
  Object.assign(el.style, { overflow: 'hidden', flex: 'none', minWidth: '0', minHeight: '0' });
  const prop = lone ? 'width' : 'height';
  const anim = el.animate([{ [prop]: `${size}px` }, { [prop]: '0px' }], { duration: CLOSE_MS, easing: 'ease-in', fill: 'forwards' });
  await Promise.race([anim.finished.catch(() => {}), new Promise((r) => setTimeout(r, CLOSE_MS + 50))]);
}

async function removeTile(sessionId, killServerSession) {
  const tile = tiles.get(sessionId);
  if (!tile) return;
  tiles.delete(sessionId);
  tile.dead = true; // stop the reconnect loop before closing the socket
  try { tile.ws?.close(); } catch {}
  const kill = killServerSession && !isFilesId(sessionId)
    ? fetch(`${API}/api/sessions/${sessionId}`, { method: 'DELETE' }).catch(() => {})
    : null;
  await animateRemoval(sessionId); // the terminal keeps painting while it shrinks
  tile.term?.dispose();
  tile.root.remove();
  await kill;
  discardWidgetState(sessionId);
  removeSessionFromLayout(sessionId);
  saveLayout();
  render();
  tiles.get(focusedId)?.focus();
}

// ---------------------------------------------------------------------------
// Session actions
// ---------------------------------------------------------------------------

async function createServerSession() {
  const res = await fetch(`${API}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cols: 80, rows: 24 }),
  });
  const { id } = await res.json();
  return id;
}

// A new pane opens as its own column immediately right of the focused one
// (niri's placement) and takes focus.
function openInNewColumn(id) {
  const ci = columnIndexOf(focusedId);
  columns.splice(ci === -1 ? columns.length : ci + 1, 0, newColumn(id));
  focusedId = id;
  saveLayout();
  render();
  tiles.get(id)?.focus();
}

// ⌘↩ / header button: new terminal.
async function newSession() {
  const id = await createServerSession();
  makeTile(id);
  openInNewColumn(id);
}

// ⌥⌘↩: new terminal stacked directly below the focused pane.
async function newSessionBelow() {
  const col = columnOf(focusedId);
  if (!col) return newSession();
  const id = await createServerSession();
  makeTile(id);
  insertIntoColumn(col, id, col.panes.indexOf(focusedId) + 1);
  focusedId = id;
  saveLayout();
  render();
  tiles.get(id)?.focus();
}

// ⌘⇧↩ / header button: file browser.
function newFilesSession() {
  const id = createFilesWidget();
  tiles.set(id, makeFilesTile(id));
  openInNewColumn(id);
}

// ---------------------------------------------------------------------------
// Pane commands (keyboard, and the client's Pane menu via 'webmux-pane')
// ---------------------------------------------------------------------------

function focusColumn(dir) {
  const target = columns[columnIndexOf(focusedId) + dir];
  if (target) setFocus(target.active, { focusTile: true });
}

function focusInColumn(dir) {
  const col = columnOf(focusedId);
  const target = col?.panes[col.panes.indexOf(focusedId) + dir];
  if (target != null) setFocus(target, { focusTile: true });
}

// After a structural move the focused pane keeps focus; re-render and put
// keyboard focus back in its content.
function commitMove() {
  saveLayout();
  render();
  tiles.get(focusedId)?.focus();
}

// ⇧⌘←/→: the whole column swaps places with its neighbour.
function moveColumn(dir) {
  const ci = columnIndexOf(focusedId);
  const ti = ci + dir;
  if (ci === -1 || ti < 0 || ti >= columns.length) return;
  [columns[ci], columns[ti]] = [columns[ti], columns[ci]];
  commitMove();
}

// ⇧⌘↑/↓ and ⌥⌘↑/↓: the pane swaps places within its stack.
function movePane(dir) {
  const col = columnOf(focusedId);
  if (!col) return;
  const i = col.panes.indexOf(focusedId);
  const j = i + dir;
  if (j < 0 || j >= col.panes.length) return;
  [col.panes[i], col.panes[j]] = [col.panes[j], col.panes[i]];
  [col.sizes[i], col.sizes[j]] = [col.sizes[j], col.sizes[i]];
  commitMove();
}

// ⌥⌘←/→, niri's consume-or-expel: a pane alone in its column merges into
// the neighbouring column on that side (at the bottom); a pane sharing a
// column splits out into a new column of its own on that side.
function consumeOrExpel(dir) {
  const ci = columnIndexOf(focusedId);
  if (ci === -1) return;
  const col = columns[ci];
  if (col.panes.length === 1) {
    const target = columns[ci + dir];
    if (!target) return;
    columns.splice(ci, 1);
    insertIntoColumn(target, focusedId);
  } else {
    removeFromColumn(focusedId);
    columns.splice(dir > 0 ? ci + 1 : ci, 0, newColumn(focusedId));
  }
  commitMove();
}

// ⌘W: close the focused pane — for a terminal that kills its session, no
// confirmation, same as ✕. Focus falls through as for any removal.
function closeFocused() {
  if (focusedId != null) removeTile(focusedId, true);
}

// ⌘F: toggle the focused pane between the width rule and the whole window.
// A stacked pane first splits out into a column of its own (right of its
// stack) and that column goes full; a lone pane just toggles its column.
function toggleFull() {
  const ci = columnIndexOf(focusedId);
  if (ci === -1) return;
  let col = columns[ci];
  if (col.panes.length > 1) {
    removeFromColumn(focusedId);
    col = newColumn(focusedId);
    columns.splice(ci + 1, 0, col);
    col.full = true;
  } else {
    col.full = !col.full;
  }
  commitMove();
}

const PANE_COMMANDS = {
  'new-terminal': newSession,
  'new-files': newFilesSession,
  'new-terminal-below': newSessionBelow,
  'close-pane': closeFocused,
  'toggle-full': toggleFull,
  'focus-left': () => focusColumn(-1),
  'focus-right': () => focusColumn(1),
  'focus-up': () => focusInColumn(-1),
  'focus-down': () => focusInColumn(1),
  'move-column-left': () => moveColumn(-1),
  'move-column-right': () => moveColumn(1),
  'move-pane-up': () => movePane(-1),
  'move-pane-down': () => movePane(1),
  'consume-expel-left': () => consumeOrExpel(-1),
  'consume-expel-right': () => consumeOrExpel(1),
};

// ⌘ bindings. Letters go by ev.code: ⌥ on macOS turns ⌥h into '˙' in
// ev.key, and shift into 'H'. ⌘H / ⌥⌘H / ⌘⇧L are freed in the client's
// menu (Hide, Hide Others and the Connection Log lost their accelerators)
// so they reach the page.
const DIR_BY_KEY = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down' };
const DIR_BY_CODE = { KeyH: 'left', KeyL: 'right', KeyK: 'up', KeyJ: 'down' };
function paneCommandForKey(ev) {
  if (ev.key === 'Enter') {
    if (ev.altKey) return ev.shiftKey ? null : 'new-terminal-below';
    return ev.shiftKey ? 'new-files' : 'new-terminal';
  }
  if (ev.code === 'KeyW') return ev.altKey || ev.shiftKey ? null : 'close-pane';
  if (ev.code === 'KeyF') return ev.altKey || ev.shiftKey ? null : 'toggle-full';
  const dir = DIR_BY_KEY[ev.key] || DIR_BY_CODE[ev.code];
  if (!dir) return null;
  const horizontal = dir === 'left' || dir === 'right';
  if (ev.altKey) return horizontal ? `consume-expel-${dir}` : `move-pane-${dir}`;
  if (ev.shiftKey) return horizontal ? `move-column-${dir}` : `move-pane-${dir}`;
  return `focus-${dir}`;
}

// Capture phase on window: runs before xterm's own keydown handling on its
// hidden textarea, so preventDefault + stopPropagation keeps the chord out
// of the pty. Real text fields (settings, rename box) keep ⌘←/→ as
// line-start/end; modals keep their keys too.
window.addEventListener('keydown', (ev) => {
  if (!ev.metaKey || ev.ctrlKey) return;
  const t = ev.target;
  if (t instanceof HTMLInputElement || t.isContentEditable
      || (t instanceof HTMLTextAreaElement && !t.classList.contains('xterm-helper-textarea'))) return;
  if (document.querySelector('.modal-overlay')) return;
  const cmd = paneCommandForKey(ev);
  if (!cmd) return;
  ev.preventDefault();
  ev.stopPropagation();
  PANE_COMMANDS[cmd]();
}, true);

// ---------------------------------------------------------------------------
// Startup: reconcile saved layout with live server sessions
// ---------------------------------------------------------------------------

async function attachExisting() {
  let sessions;
  try {
    sessions = await (await fetch(`${API}/api/sessions`)).json();
  } catch (err) {
    logError('session list fetch failed', { api: API || location.origin, error: String(err.message || err) });
    throw err;
  }
  logInfo('page attached', { sessions: sessions.length, api: API || location.origin });
  const live = sessions.map((s) => s.id);
  const liveSet = new Set(live);

  const saved = loadLayout();
  columns = saved.columns;
  for (const id of allIds()) {
    // stale terminal pane, session is gone (files panes live client-side only)
    if (!isFilesId(id) && !liveSet.has(id)) removeFromColumn(id);
  }
  const inLayout = new Set(allIds());
  for (const id of live) {
    if (!inLayout.has(id)) columns.push(newColumn(id)); // opened elsewhere — a column on the right
  }

  focusedId = allIds().includes(saved.focused) ? saved.focused : (columns[0]?.active ?? null);
  // Every pane is on the strip and connects its own socket, but seed the
  // titles from the session list so the bars read right before the
  // snapshots arrive.
  const titles = new Map(sessions.map((s) => [s.id, s.title]));
  for (const id of allIds()) {
    if (isFilesId(id)) tiles.set(id, makeFilesTile(id));
    else makeTile(id).setTitle(titles.get(id));
  }
  pruneWidgetStates(new Set(tiles.keys())); // drop state orphaned by closed panes
  saveLayout();
  render();
  if (!columns.length) await newSession();
  else tiles.get(focusedId)?.focus(); // every tile's open() grabbed focus in turn
}

document.getElementById('new-session').addEventListener('click', newSession);
document.getElementById('new-files').addEventListener('click', newFilesSession);
document.getElementById('settings').addEventListener('click', showSettingsModal);
// The Electron client hides the in-page header and relays its own header-
// strip buttons, the Pane menu, and the ⌘, menu item as these events
// (main.js chromeCmd).
window.addEventListener('webmux-new-terminal', newSession);
window.addEventListener('webmux-new-files', newFilesSession);
window.addEventListener('webmux-settings-open', showSettingsModal);
window.addEventListener('webmux-pane', (ev) => PANE_COMMANDS[ev.detail]?.());

// A file dropped outside a widget's drop zone must not navigate the page
// away from webmux (the browser default). Real targets handled it earlier
// in the bubble phase.
window.addEventListener('dragover', (ev) => ev.preventDefault());
window.addEventListener('drop', (ev) => ev.preventDefault());

// Two-finger horizontal scrolling pans the strip. Explicit rather than the
// browser's scroll chaining: xterm claims (preventDefault) any wheel event
// with a vertical component, and trackpad swipes are rarely perfectly
// horizontal. A file browser's own Miller columns scroll first; the strip
// takes over once they hit their edge.
layoutEl.addEventListener('wheel', (ev) => {
  if (Math.abs(ev.deltaX) <= Math.abs(ev.deltaY)) return;
  const inner = ev.target.closest?.('.files-cols');
  if (inner) {
    const atEdge = ev.deltaX > 0
      ? inner.scrollLeft + inner.clientWidth >= inner.scrollWidth - 1
      : inner.scrollLeft <= 0;
    if (!atEdge) return;
  }
  ev.preventDefault();
  ev.stopPropagation();
  chase = null; // the hand wins over an in-flight reveal
  layoutEl.scrollLeft += ev.deltaX;
}, { passive: false, capture: true });

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { applyColumnWidths(); fitAll(); revealFocused(); }, 100);
});

// The minimum column width follows the setting live.
onSettingsChange(() => {
  applyColumnWidths();
  fitAll();
  revealFocused();
});

// xterm measures the cell grid from the font at open(); if the webfont isn't
// ready yet the grid is sized from the fallback font and glyphs misalign.
// Wait for it (bounded, in case the font 404s), then re-measure any terminals
// that were opened before a late-arriving font.
async function start() {
  // Settings first: the theme must be on <html> (and in THEMES for xterm)
  // before any pane paints. loadSettings never rejects.
  const settingsReady = loadSettings();
  try {
    await Promise.race([
      Promise.all([
        document.fonts.load('13px "JetBrainsMono Nerd Font"'),
        document.fonts.load('bold 13px "JetBrainsMono Nerd Font"'),
      ]),
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
  } catch { /* fall back to monospace */ }
  await settingsReady;
  await attachExisting();
  document.fonts.ready.then(() => {
    for (const tile of tiles.values()) {
      if (!tile.term) continue;
      // re-assigning forces xterm to re-measure with the now-loaded font
      tile.term.options.fontFamily = 'monospace';
      tile.term.options.fontFamily = TERM_FONT;
    }
    measureCell(); // the column minimum is in cells of the real font too
    applyColumnWidths();
    fitAll();
  });
}

start();
