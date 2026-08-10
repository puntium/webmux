/* webmux client — tmux-style split layout with tabbed panes.
   Layout is a binary tree: internal nodes are splits with a direction and
   ratio (resizable by dragging the divider); leaves are panes, each holding a
   tabbed set of sessions with one active tab. Tabs can be dragged between
   panes (and reordered within one), but dropping never creates a new split —
   splits happen only via the explicit ↔ / ↕ buttons. Sessions live on the
   server; the tree is saved to localStorage so a reload restores both the
   sessions (from headless snapshots) and the arrangement.

   Tabs hold either a terminal session (id from the server) or a client-side
   widget (id `files-<random>`, the Miller-columns file browser implemented
   in files-widget.js). Both kinds are represented by a "tile" with the same
   interface: { root, openIfNeeded(), fitAndReport(), focus(), term?, ws?,
   label?() }. */

import {
  isFilesId, createFilesWidget, makeFilesTile, discardWidgetState, pruneWidgetStates,
} from './files-widget.js';

const layoutEl = document.getElementById('layout');
const statusEl = document.getElementById('status');
const tiles = new Map(); // sessionId -> tile
const MIN_PANE_PX = 110;

// tree: { type:'pane', tabs:[id], active:id } | { type:'split', dir:'row'|'col', ratio, a, b }
let tree = null;
let focusedPane = null; // pane node that last had user interaction
let dragSessionId = null; // session id of the tab being dragged, if any

// ---------------------------------------------------------------------------
// Layout tree helpers
// ---------------------------------------------------------------------------

const paneNode = (id) => ({ type: 'pane', tabs: [id], active: id });

function treeContains(node, target) {
  if (!node || !target) return false;
  if (node === target) return true;
  return node.type === 'split' && (treeContains(node.a, target) || treeContains(node.b, target));
}

function findPane(node, sessionId) {
  if (!node) return null;
  if (node.type === 'pane') return node.tabs.includes(sessionId) ? node : null;
  return findPane(node.a, sessionId) || findPane(node.b, sessionId);
}

function firstPane(node) {
  if (!node) return null;
  return node.type === 'pane' ? node : firstPane(node.a) || firstPane(node.b);
}

function replaceNode(node, target, replacement) {
  if (!node) return node;
  if (node === target) return replacement;
  if (node.type === 'split') {
    node.a = replaceNode(node.a, target, replacement);
    node.b = replaceNode(node.b, target, replacement);
  }
  return node;
}

function pruneEmpty(node) {
  if (!node) return null;
  if (node.type === 'pane') return node.tabs.length ? node : null;
  const a = pruneEmpty(node.a);
  const b = pruneEmpty(node.b);
  if (!a) return b; // sibling takes the whole area
  if (!b) return a;
  node.a = a;
  node.b = b;
  return node;
}

function collectIds(node, out = []) {
  if (!node) return out;
  if (node.type === 'pane') out.push(...node.tabs);
  else { collectIds(node.a, out); collectIds(node.b, out); }
  return out;
}

function removeSessionFromTree(sessionId) {
  const pane = findPane(tree, sessionId);
  if (!pane) return;
  const i = pane.tabs.indexOf(sessionId);
  pane.tabs.splice(i, 1);
  if (pane.active === sessionId) {
    pane.active = pane.tabs[Math.min(i, pane.tabs.length - 1)] ?? null;
  }
  tree = pruneEmpty(tree);
}

function saveLayout() {
  localStorage.setItem('webmux-layout', JSON.stringify(tree));
}

// Accepts the pre-tabs format ({ type:'pane', session }) and upgrades it.
function migrate(node) {
  if (!node || !node.type) return null;
  if (node.type === 'pane') {
    if (node.session != null) return paneNode(node.session);
    if (!Array.isArray(node.tabs) || node.tabs.length === 0) return null;
    if (!node.tabs.includes(node.active)) node.active = node.tabs[0];
    return node;
  }
  node.a = migrate(node.a);
  node.b = migrate(node.b);
  if (!node.a) return node.b;
  if (!node.b) return node.a;
  return node;
}

function loadLayout() {
  try { return migrate(JSON.parse(localStorage.getItem('webmux-layout'))); }
  catch { return null; }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function render() {
  if (tree && !treeContains(tree, focusedPane)) focusedPane = firstPane(tree);
  layoutEl.replaceChildren();
  if (tree) layoutEl.appendChild(buildNode(tree));
  // xterm needs its element in the DOM before open(); open any new tiles now.
  for (const tile of tiles.values()) tile.openIfNeeded();
  fitAll();
  setStatus(`${tiles.size} tab(s)`);
}

function buildNode(node) {
  if (node.type === 'pane') {
    const el = buildPane(node);
    el.style.flex = '1 1 0';
    return el;
  }
  const el = document.createElement('div');
  el.className = `split ${node.dir}`;
  const a = buildNode(node.a);
  const b = buildNode(node.b);
  a.style.flex = `${node.ratio} 1 0`;
  b.style.flex = `${1 - node.ratio} 1 0`;
  el.append(a, makeDivider(node, a, b), b);
  return el;
}

function buildPane(node) {
  const el = document.createElement('div');
  el.className = 'pane';

  const bar = document.createElement('div');
  bar.className = 'pane-bar';

  const tabsEl = document.createElement('div');
  tabsEl.className = 'tabs';
  for (const id of node.tabs) tabsEl.appendChild(buildTab(node, id));

  const newTab = document.createElement('button');
  newTab.className = 'new-tab';
  newTab.title = 'New terminal tab';
  newTab.textContent = '+';
  newTab.addEventListener('click', () => newTabInPane(node));

  const actions = document.createElement('span');
  actions.className = 'pane-actions';
  actions.innerHTML = `
    <button class="split-h" title="Split side by side (shift: move current tab)">↔</button>
    <button class="split-v" title="Split stacked (shift: move current tab)">↕</button>`;
  actions.querySelector('.split-h').addEventListener('click', (ev) => splitPane(node, 'row', ev.shiftKey));
  actions.querySelector('.split-v').addEventListener('click', (ev) => splitPane(node, 'col', ev.shiftKey));

  bar.append(tabsEl, newTab, actions);

  const body = document.createElement('div');
  body.className = 'pane-body';
  const active = tiles.get(node.active);
  if (active) body.appendChild(active.root);

  el.append(bar, body);
  el.classList.toggle('focused', node === focusedPane);
  el.addEventListener('pointerdown', () => {
    if (focusedPane === node) return;
    focusedPane = node;
    document.querySelectorAll('.pane.focused').forEach((p) => p.classList.remove('focused'));
    el.classList.add('focused');
  }, true);

  // A dragged tab can be dropped anywhere on this pane; unless it lands on a
  // specific tab (handled in buildTab), it is appended at the end. Panes are
  // the only drop targets — dropping never creates a new split.
  el.addEventListener('dragover', (ev) => {
    if (dragSessionId == null) return;
    ev.preventDefault();
    ev.dataTransfer.dropEffect = 'move';
    el.classList.add('drop-target');
  });
  el.addEventListener('dragleave', (ev) => {
    if (!el.contains(ev.relatedTarget)) el.classList.remove('drop-target');
  });
  el.addEventListener('drop', (ev) => {
    if (dragSessionId == null) return;
    ev.preventDefault();
    el.classList.remove('drop-target');
    moveTab(dragSessionId, node, node.tabs.length);
  });

  return el;
}

function buildTab(node, id) {
  const tab = document.createElement('div');
  tab.className = 'tab' + (id === node.active ? ' active' : '');
  tab.draggable = true;
  tab.title = isFilesId(id) ? 'file browser' : `session ${id}`;

  const tile = tiles.get(id);
  const label = document.createElement('span');
  label.className = 'tab-label';
  label.textContent = tile?.label ? tile.label() : id;
  if (tile) tile.labelEl = label; // files tiles retitle the tab as you navigate
  const close = document.createElement('button');
  close.className = 'tab-close';
  close.title = isFilesId(id) ? 'Close' : 'Kill session';
  close.textContent = '✕';
  tab.append(label, close);

  tab.addEventListener('click', () => {
    if (node.active !== id) {
      node.active = id;
      saveLayout();
      render();
    }
    tiles.get(id)?.focus();
  });
  close.addEventListener('click', (ev) => {
    ev.stopPropagation();
    removeTile(id, true);
  });

  tab.addEventListener('dragstart', (ev) => {
    dragSessionId = id;
    ev.dataTransfer.setData('text/plain', id);
    ev.dataTransfer.effectAllowed = 'move';
    tab.classList.add('dragging');
  });
  tab.addEventListener('dragend', () => {
    dragSessionId = null;
    tab.classList.remove('dragging');
    document.querySelectorAll('.drop-target, .drop-before, .drop-after')
      .forEach((n) => n.classList.remove('drop-target', 'drop-before', 'drop-after'));
  });

  // Dropping on a tab inserts before or after it depending on which half of
  // the tab the pointer is over.
  const dropAfter = (ev) => ev.clientX > tab.getBoundingClientRect().left + tab.offsetWidth / 2;
  tab.addEventListener('dragover', (ev) => {
    if (dragSessionId == null) return;
    ev.preventDefault();
    const after = dropAfter(ev);
    tab.classList.toggle('drop-before', !after);
    tab.classList.toggle('drop-after', after);
  });
  tab.addEventListener('dragleave', () => tab.classList.remove('drop-before', 'drop-after'));
  tab.addEventListener('drop', (ev) => {
    if (dragSessionId == null) return;
    ev.preventDefault();
    ev.stopPropagation(); // the pane's drop handler would append instead
    tab.classList.remove('drop-before', 'drop-after');
    moveTab(dragSessionId, node, node.tabs.indexOf(id) + (dropAfter(ev) ? 1 : 0));
  });

  return tab;
}

function moveTab(sessionId, targetPane, index) {
  const src = findPane(tree, sessionId);
  if (!src) return;
  const from = src.tabs.indexOf(sessionId);
  src.tabs.splice(from, 1);
  if (src === targetPane && index > from) index--;
  if (src !== targetPane && src.active === sessionId) {
    src.active = src.tabs[Math.min(from, src.tabs.length - 1)] ?? null;
  }
  targetPane.tabs.splice(index, 0, sessionId);
  targetPane.active = sessionId;
  focusedPane = targetPane;
  tree = pruneEmpty(tree); // the source pane may now be empty
  saveLayout();
  render();
  tiles.get(sessionId)?.focus();
}

function makeDivider(node, elA, elB) {
  const div = document.createElement('div');
  div.className = `divider ${node.dir}`;
  div.addEventListener('pointerdown', (down) => {
    down.preventDefault();
    div.setPointerCapture(down.pointerId);
    const parent = div.parentElement;
    const horizontal = node.dir === 'row';

    const onMove = (ev) => {
      const rect = parent.getBoundingClientRect();
      const size = horizontal ? rect.width : rect.height;
      const pos = horizontal ? ev.clientX - rect.left : ev.clientY - rect.top;
      const min = Math.min(MIN_PANE_PX / size, 0.45);
      node.ratio = Math.min(1 - min, Math.max(min, pos / size));
      elA.style.flex = `${node.ratio} 1 0`;
      elB.style.flex = `${1 - node.ratio} 1 0`;
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

function setStatus(text) {
  statusEl.textContent = text;
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
async function writeHostClipboard(text) {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      setStatus('clipboard set from terminal');
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
  setStatus(ok ? 'clipboard set from terminal' : 'clipboard write blocked by the browser');
}

// Clicking a detected URL in a terminal pops this chooser instead of xterm's
// default open-immediately behavior. Returns focus to the terminal on close.
function showLinkModal(uri, tile) {
  const overlay = document.createElement('div');
  overlay.className = 'link-modal-overlay';
  overlay.innerHTML = `
    <div class="link-modal" role="dialog" aria-label="Link options">
      <div class="link-url"></div>
      <div class="link-actions">
        <button class="link-cancel">Cancel</button>
        <button class="link-copy">Copy</button>
        <button class="link-open primary">Open in new tab</button>
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
    writeHostClipboard(uri);
  });
  overlay.querySelector('.link-open').addEventListener('click', () => {
    window.open(uri, '_blank', 'noopener');
    close();
  });

  document.body.appendChild(overlay);
  overlay.querySelector('.link-open').focus();
}

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
    exited: false,
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
        theme: { background: '#1f1f2b' },
      });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);

      // URL detection: the web-links addon underlines http(s) URLs on hover;
      // a click lands here instead of opening directly, so the user chooses
      // between copying and opening.
      term.loadAddon(new WebLinksAddon.WebLinksAddon((ev, uri) => {
        ev.preventDefault();
        showLinkModal(uri, this);
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

      const ws = new WebSocket(
        `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws?session=${sessionId}`
      );
      this.ws = ws;

      ws.onopen = () => this.fitAndReport();
      ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'snapshot') {
          term.reset();
          if (msg.data) term.write(msg.data);
          this.setTitle(msg.title);
          this.fitAndReport();
        } else if (msg.type === 'output') {
          term.write(msg.data);
        } else if (msg.type === 'title') {
          this.setTitle(msg.title);
        } else if (msg.type === 'exit') {
          this.exited = true;
          term.write(`\r\n\x1b[31m[session exited: ${msg.exitCode}]\x1b[0m\r\n`);
          setTimeout(() => removeTile(sessionId, false), 1200);
        } else if (msg.type === 'paste-result') {
          setStatus(msg.mode === 'claude'
            ? 'image in clipboard — Ctrl+V forwarded to Claude'
            : `pasted image → ${msg.path}`);
        } else if (msg.type === 'error') {
          removeTile(sessionId, false);
        }
      };
      ws.onclose = () => {
        if (!this.exited) term.write('\r\n\x1b[33m[disconnected]\x1b[0m\r\n');
      };

      term.onData((data) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'input', data }));
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

async function removeTile(sessionId, killServerSession) {
  const tile = tiles.get(sessionId);
  if (!tile) return;
  tiles.delete(sessionId);
  try { tile.ws?.close(); } catch {}
  tile.term?.dispose();
  tile.root.remove();
  if (killServerSession && !isFilesId(sessionId)) {
    await fetch(`/api/sessions/${sessionId}`, { method: 'DELETE' }).catch(() => {});
  }
  discardWidgetState(sessionId);
  removeSessionFromTree(sessionId);
  saveLayout();
  render();
}

// ---------------------------------------------------------------------------
// Session actions
// ---------------------------------------------------------------------------

async function createServerSession() {
  const res = await fetch('/api/sessions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cols: 80, rows: 24 }),
  });
  const { id } = await res.json();
  return id;
}

// Shift-clicking a split button moves the pane's current tab into the new
// split instead of spawning a fresh terminal (only when other tabs remain —
// a pane can't be left empty).
async function splitPane(pane, dir, moveActiveTab = false) {
  let fresh;
  if (moveActiveTab && pane.tabs.length > 1) {
    const id = pane.active;
    const i = pane.tabs.indexOf(id);
    pane.tabs.splice(i, 1);
    pane.active = pane.tabs[Math.min(i, pane.tabs.length - 1)];
    fresh = paneNode(id);
  } else {
    const id = await createServerSession();
    makeTile(id);
    fresh = paneNode(id);
  }
  tree = replaceNode(tree, pane, { type: 'split', dir, ratio: 0.5, a: pane, b: fresh });
  focusedPane = fresh;
  saveLayout();
  render();
  tiles.get(fresh.active)?.focus();
}

async function newTabInPane(pane) {
  const id = await createServerSession();
  makeTile(id);
  pane.tabs.push(id);
  pane.active = id;
  focusedPane = pane;
  saveLayout();
  render();
}

// Header button: open a tab in the focused pane (never a new split).
async function newSession() {
  const pane = treeContains(tree, focusedPane) ? focusedPane : firstPane(tree);
  if (pane) return newTabInPane(pane);
  const id = await createServerSession();
  makeTile(id);
  tree = paneNode(id);
  focusedPane = tree;
  saveLayout();
  render();
}

// Header button: file browser tab in the focused pane, like newSession.
function newFilesSession() {
  const pane = treeContains(tree, focusedPane) ? focusedPane : firstPane(tree);
  const id = createFilesWidget();
  tiles.set(id, makeFilesTile(id));
  if (pane) {
    pane.tabs.push(id);
    pane.active = id;
    focusedPane = pane;
  } else {
    tree = paneNode(id);
    focusedPane = tree;
  }
  saveLayout();
  render();
  tiles.get(id).focus();
}

// ---------------------------------------------------------------------------
// Startup: reconcile saved layout with live server sessions
// ---------------------------------------------------------------------------

async function attachExisting() {
  const live = (await (await fetch('/api/sessions')).json()).map((s) => s.id);
  const liveSet = new Set(live);

  tree = loadLayout();
  for (const id of collectIds(tree)) {
    // stale terminal tab, session is gone (files tabs live client-side only)
    if (!isFilesId(id) && !liveSet.has(id)) removeSessionFromTree(id);
  }
  const inTree = new Set(collectIds(tree));
  for (const id of live) {
    if (inTree.has(id)) continue; // session opened elsewhere — tab it into the first pane
    if (tree) firstPane(tree).tabs.push(id);
    else tree = paneNode(id);
  }

  focusedPane = firstPane(tree);
  for (const id of collectIds(tree)) {
    if (isFilesId(id)) tiles.set(id, makeFilesTile(id));
    else makeTile(id);
  }
  pruneWidgetStates(new Set(tiles.keys())); // drop state orphaned by closed tabs
  saveLayout();
  render();
  if (!tree) await newSession();
}

document.getElementById('new-session').addEventListener('click', newSession);
document.getElementById('new-files').addEventListener('click', newFilesSession);

// A file dropped outside a widget's drop zone must not navigate the page
// away from webmux (the browser default). Real targets handled it earlier
// in the bubble phase.
window.addEventListener('dragover', (ev) => ev.preventDefault());
window.addEventListener('drop', (ev) => ev.preventDefault());

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(fitAll, 100);
});

// xterm measures the cell grid from the font at open(); if the webfont isn't
// ready yet the grid is sized from the fallback font and glyphs misalign.
// Wait for it (bounded, in case the font 404s), then re-measure any terminals
// that were opened before a late-arriving font.
const TERM_FONT = '"JetBrainsMono Nerd Font", monospace';

async function start() {
  try {
    await Promise.race([
      Promise.all([
        document.fonts.load('13px "JetBrainsMono Nerd Font"'),
        document.fonts.load('bold 13px "JetBrainsMono Nerd Font"'),
      ]),
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
  } catch { /* fall back to monospace */ }
  await attachExisting();
  document.fonts.ready.then(() => {
    for (const tile of tiles.values()) {
      if (!tile.term) continue;
      // re-assigning forces xterm to re-measure with the now-loaded font
      tile.term.options.fontFamily = 'monospace';
      tile.term.options.fontFamily = TERM_FONT;
    }
    fitAll();
  });
}

start();
