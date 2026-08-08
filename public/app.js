/* webmux client — tmux-style split layout, one xterm.js instance per pane.
   Layout is a binary tree: leaves are panes (sessions), internal nodes are
   splits with a direction and ratio, resizable by dragging the divider.
   Sessions live on the server; the tree is saved to localStorage so a reload
   restores both the sessions (from headless snapshots) and the arrangement. */

const layoutEl = document.getElementById('layout');
const statusEl = document.getElementById('status');
const tiles = new Map(); // sessionId -> tile
const MIN_PANE_PX = 110;

// tree: { type:'pane', session } | { type:'split', dir:'row'|'col', ratio, a, b }
let tree = null;

// ---------------------------------------------------------------------------
// Layout tree helpers
// ---------------------------------------------------------------------------

const leaf = (id) => ({ type: 'pane', session: id });

function splitLeaf(node, id, dir, newNode) {
  if (!node) return node;
  if (node.type === 'pane') {
    return node.session === id
      ? { type: 'split', dir, ratio: 0.5, a: node, b: newNode }
      : node;
  }
  node.a = splitLeaf(node.a, id, dir, newNode);
  node.b = splitLeaf(node.b, id, dir, newNode);
  return node;
}

function pruneLeaf(node, id) {
  if (!node) return null;
  if (node.type === 'pane') return node.session === id ? null : node;
  const a = pruneLeaf(node.a, id);
  const b = pruneLeaf(node.b, id);
  if (!a) return b; // sibling takes the whole area
  if (!b) return a;
  node.a = a;
  node.b = b;
  return node;
}

function collectIds(node, out = []) {
  if (!node) return out;
  if (node.type === 'pane') out.push(node.session);
  else { collectIds(node.a, out); collectIds(node.b, out); }
  return out;
}

function saveLayout() {
  localStorage.setItem('webmux-layout', JSON.stringify(tree));
}

function loadLayout() {
  try { return JSON.parse(localStorage.getItem('webmux-layout')); }
  catch { return null; }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function render() {
  layoutEl.replaceChildren();
  if (tree) layoutEl.appendChild(buildNode(tree));
  // xterm needs its element in the DOM before open(); open any new tiles now.
  for (const tile of tiles.values()) tile.openIfNeeded();
  fitAll();
  setStatus(`${tiles.size} session(s)`);
}

function buildNode(node) {
  if (node.type === 'pane') {
    const tile = tiles.get(node.session);
    tile.root.style.flex = '1 1 0';
    return tile.root;
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

// ---------------------------------------------------------------------------
// Tiles (pane DOM + terminal + websocket)
// ---------------------------------------------------------------------------

function makeTile(sessionId) {
  const root = document.createElement('div');
  root.className = 'tile';
  root.innerHTML = `
    <div class="tile-bar">
      <span>session ${sessionId}</span>
      <span class="tile-actions">
        <button class="split-h" title="Split side by side">↔</button>
        <button class="split-v" title="Split stacked">↕</button>
        <button class="close" title="Kill session">✕</button>
      </span>
    </div>
    <div class="term-holder"></div>`;

  const tile = {
    root,
    term: null,
    fit: null,
    ws: null,
    exited: false,
    openIfNeeded() {
      if (this.term || !root.isConnected) return;

      const term = new Terminal({
        cursorBlink: true,
        fontSize: 13,
        scrollback: 5000,
        theme: { background: '#1f1f2b' },
      });
      const fit = new FitAddon.FitAddon();
      term.loadAddon(fit);
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
          this.fitAndReport();
        } else if (msg.type === 'output') {
          term.write(msg.data);
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
      if (!this.term) return;
      try { this.fit.fit(); } catch { return; }
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'resize', cols: this.term.cols, rows: this.term.rows }));
      }
    },
  };

  root.querySelector('.split-h').addEventListener('click', () => splitPane(sessionId, 'row'));
  root.querySelector('.split-v').addEventListener('click', () => splitPane(sessionId, 'col'));
  root.querySelector('.close').addEventListener('click', () => removeTile(sessionId, true));

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
  if (killServerSession) {
    await fetch(`/api/sessions/${sessionId}`, { method: 'DELETE' }).catch(() => {});
  }
  tree = pruneLeaf(tree, sessionId);
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

async function splitPane(sessionId, dir) {
  const id = await createServerSession();
  makeTile(id);
  tree = splitLeaf(tree, sessionId, dir, leaf(id));
  saveLayout();
  render();
}

async function newSession() {
  const id = await createServerSession();
  makeTile(id);
  const dir = layoutEl.clientWidth > layoutEl.clientHeight ? 'row' : 'col';
  tree = tree ? { type: 'split', dir, ratio: 0.5, a: tree, b: leaf(id) } : leaf(id);
  saveLayout();
  render();
}

// ---------------------------------------------------------------------------
// Startup: reconcile saved layout with live server sessions
// ---------------------------------------------------------------------------

async function attachExisting() {
  const live = (await (await fetch('/api/sessions')).json()).map((s) => s.id);
  const liveSet = new Set(live);

  tree = loadLayout();
  for (const id of collectIds(tree)) {
    if (!liveSet.has(id)) tree = pruneLeaf(tree, id); // stale pane, session is gone
  }
  const inTree = new Set(collectIds(tree));
  for (const id of live) {
    if (inTree.has(id)) continue; // session opened elsewhere — add it to the layout
    const dir = layoutEl.clientWidth > layoutEl.clientHeight ? 'row' : 'col';
    tree = tree ? { type: 'split', dir, ratio: 0.5, a: tree, b: leaf(id) } : leaf(id);
  }

  for (const id of collectIds(tree)) makeTile(id);
  saveLayout();
  render();
  if (!tree) await newSession();
}

document.getElementById('new-session').addEventListener('click', newSession);

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(fitAll, 100);
});

attachExisting();
