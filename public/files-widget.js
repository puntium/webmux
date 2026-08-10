/* File browser widget (Finder-style Miller columns) — a client-side tab type.

   A files tab lives entirely in the browser: its id is `files-<random>`
   (never a server session id) and its state ({ dir, cursor }) persists in
   localStorage next to the layout. Columns show the ancestor chain of `dir`;
   the cursor entry gets one extra column — a listing for directories, a
   preview (text/image/stat) for files. Arrows / hjkl navigate like yazi.
   Files or folders dragged onto a column upload into that column's
   directory (folders recreate their tree); files or images pasted while
   the widget is focused upload into the rightmost directory shown.

   app.js owns the layout/tab machinery and registers the tile returned by
   makeFilesTile() — the tile interface it expects is
   { root, openIfNeeded(), fitAndReport(), focus(), term, ws, label() }. */

const statusEl = document.getElementById('status');
const setStatus = (text) => { statusEl.textContent = text; };

export const isFilesId = (id) => typeof id === 'string' && id.startsWith('files-');

// ---------------------------------------------------------------------------
// Per-widget persisted state
// ---------------------------------------------------------------------------

const widgetStates = (() => {
  try { return JSON.parse(localStorage.getItem('webmux-widgets')) || {}; }
  catch { return {}; }
})();
const saveWidgets = () => localStorage.setItem('webmux-widgets', JSON.stringify(widgetStates));

export function createFilesWidget() {
  const id = `files-${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;
  widgetStates[id] = { type: 'files', dir: '~', cursor: null };
  saveWidgets();
  return id;
}

export function discardWidgetState(id) {
  if (!widgetStates[id]) return;
  delete widgetStates[id];
  saveWidgets();
}

export function pruneWidgetStates(keep) {
  for (const id of Object.keys(widgetStates)) {
    if (!keep.has(id)) delete widgetStates[id];
  }
  saveWidgets();
}

// ---------------------------------------------------------------------------
// Path + formatting helpers
// ---------------------------------------------------------------------------

const fsJoin = (dir, name) => (dir === '/' ? `/${name}` : `${dir}/${name}`);
const fsParent = (dir) => dir.slice(0, dir.lastIndexOf('/')) || '/';
const fsBase = (dir) => (dir === '/' ? '/' : dir.slice(dir.lastIndexOf('/') + 1));
const fsChain = (dir) => { // '/a/b' -> ['/', '/a', '/a/b']
  const chain = ['/'];
  let cur = '';
  for (const seg of dir.split('/').filter(Boolean)) chain.push(cur += '/' + seg);
  return chain;
};

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = bytes;
  let u = -1;
  do { v /= 1024; u++; } while (v >= 1024 && u < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[u]}`;
}

// Native file drops only — tab drags (text/plain) must fall through to the
// pane's own drop handling. Dropped directories are walked recursively so
// their contents upload under matching relative paths. Uploads are
// { file, name } pairs where name may contain '/' for files inside a
// dropped folder; empty directories are not recreated.
function entryFiles(entry, prefix) {
  return new Promise((resolve) => {
    if (entry.isFile) {
      entry.file((f) => resolve([{ file: f, name: prefix + f.name }]), () => resolve([]));
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      const batches = [];
      const readBatch = () => reader.readEntries(async (batch) => {
        if (!batch.length) return resolve((await Promise.all(batches)).flat());
        for (const e of batch) batches.push(entryFiles(e, `${prefix}${entry.name}/`));
        readBatch(); // readEntries returns ≤100 entries per call; drain it
      }, () => resolve([]));
      readBatch();
    } else resolve([]);
  });
}

async function dropFiles(ev) {
  const items = ev.dataTransfer?.items;
  if (!items) return [...(ev.dataTransfer?.files || [])].map((f) => ({ file: f, name: f.name }));
  // Entries must be grabbed synchronously — the dataTransfer is dead after
  // the drop handler yields; only the entry reads may be async.
  const entries = [...items]
    .filter((it) => it.kind === 'file')
    .map((it) => it.webkitGetAsEntry?.() || it.getAsFile())
    .filter(Boolean);
  const out = [];
  for (const e of entries) {
    if (e instanceof File) out.push({ file: e, name: e.name });
    else out.push(...await entryFiles(e, ''));
  }
  return out;
}

// ---------------------------------------------------------------------------
// The tile
// ---------------------------------------------------------------------------

export function makeFilesTile(id) {
  const state = (widgetStates[id] ||= { type: 'files', dir: '~', cursor: null });

  const root = document.createElement('div');
  root.className = 'tile files-tile';
  const colsEl = document.createElement('div');
  colsEl.className = 'files-cols';
  colsEl.tabIndex = 0; // receives arrow-key navigation and paste events
  root.appendChild(colsEl);

  // Short-TTL listing cache: keyboard navigation stays snappy, external
  // changes still show up on the next interaction a few seconds later.
  const listCache = new Map(); // dir -> { t, data }
  const LIST_TTL = 4000;
  async function list(dir) {
    const hit = listCache.get(dir);
    if (hit && Date.now() - hit.t < LIST_TTL) return hit.data;
    let data;
    try {
      data = await (await fetch(`/api/fs/list?path=${encodeURIComponent(dir)}`)).json();
    } catch (err) {
      data = { error: String(err) };
    }
    listCache.set(dir, { t: Date.now(), data });
    return data;
  }

  const msg = (text) => {
    const el = document.createElement('div');
    el.className = 'files-msg';
    el.textContent = text;
    return el;
  };

  async function uploadTo(dir, files) {
    setStatus(`uploading ${files.length} file(s)…`);
    let lastName = null;
    for (const f of files) {
      const q = `dir=${encodeURIComponent(dir)}&name=${encodeURIComponent(f.name || 'pasted')}`;
      try {
        const res = await fetch(`/api/fs/upload?${q}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/octet-stream' },
          body: f.file,
        });
        const out = await res.json();
        if (out.error) throw new Error(out.error);
        lastName = out.name.split('/')[0]; // cursor lands on the top-level entry
      } catch (err) {
        setStatus(`upload failed: ${err.message || err}`);
        return;
      }
    }
    setStatus(`uploaded ${files.length} file(s) → ${dir}`);
    listCache.delete(dir);
    state.dir = dir;
    state.cursor = lastName;
    rerender();
  }

  // targetDir is a thunk: for the colsEl fallback the target (the rightmost
  // directory) changes as the user navigates.
  function enableDrop(el, targetDir) {
    el.addEventListener('dragover', (ev) => {
      if (![...(ev.dataTransfer?.types || [])].includes('Files')) return;
      ev.preventDefault();
      ev.stopPropagation();
      ev.dataTransfer.dropEffect = 'copy';
      el.classList.add('drop-target');
    });
    el.addEventListener('dragleave', (ev) => {
      if (!el.contains(ev.relatedTarget)) el.classList.remove('drop-target');
    });
    el.addEventListener('drop', async (ev) => {
      if (!ev.dataTransfer?.files.length) return; // tab drag — bubble to the pane
      ev.preventDefault();
      ev.stopPropagation();
      el.classList.remove('drop-target');
      const dir = targetDir(); // capture before the async walk; navigation may move it
      const files = await dropFiles(ev);
      if (!files.length) return setStatus('nothing to upload');
      uploadTo(dir, files);
    });
  }

  function buildCol(dirPath, data, hlName, isCursorCol) {
    const col = document.createElement('div');
    col.className = 'files-col';
    enableDrop(col, () => dirPath);
    if (data.error) {
      col.appendChild(msg(data.error));
      return col;
    }
    if (!data.entries.length) {
      col.appendChild(msg('(empty)'));
      return col;
    }
    for (const e of data.entries) {
      const row = document.createElement('div');
      row.className = 'files-entry';
      if (e.name === hlName) row.classList.add(isCursorCol ? 'cursor' : 'on-path');
      if (e.name.startsWith('.')) row.classList.add('hidden-file');
      const nm = document.createElement('span');
      nm.className = 'files-name' + (e.symlink ? ' symlink' : '');
      nm.textContent = e.name;
      row.appendChild(nm);
      if (e.type === 'dir') {
        const arrow = document.createElement('span');
        arrow.className = 'files-arrow';
        arrow.textContent = '›';
        row.appendChild(arrow);
      }
      row.addEventListener('click', () => {
        state.dir = dirPath;
        state.cursor = e.name;
        rerender();
        colsEl.focus();
      });
      col.appendChild(row);
    }
    if (data.truncated) col.appendChild(msg('(list truncated)'));
    return col;
  }

  function previewContent(filePath, info) {
    const wrap = document.createElement('div');
    wrap.className = 'files-preview-inner';

    const head = document.createElement('div');
    head.className = 'files-preview-head';
    const fname = document.createElement('div');
    fname.className = 'fname';
    fname.textContent = fsBase(filePath);
    const fmeta = document.createElement('div');
    fmeta.className = 'fmeta';
    fmeta.textContent = `${formatSize(info.size)} · ${new Date(info.mtime).toLocaleString()}`;
    head.append(fname, fmeta);

    const body = document.createElement('div');
    body.className = 'files-preview-body';
    if (info.kind === 'image') {
      const img = document.createElement('img');
      img.src = `/api/fs/raw?path=${encodeURIComponent(filePath)}`;
      img.alt = fsBase(filePath);
      body.appendChild(img);
    } else if (info.kind === 'text') {
      const pre = document.createElement('pre');
      pre.textContent = info.content || '(empty file)';
      body.appendChild(pre);
      if (info.truncated) body.appendChild(msg('(preview truncated)'));
    } else if (info.kind === 'binary') {
      body.appendChild(msg('binary file'));
    } else {
      body.appendChild(msg('no preview'));
    }

    wrap.append(head, body);
    return wrap;
  }

  function buildPreviewCol(filePath, g) {
    const col = document.createElement('div');
    col.className = 'files-col files-preview';
    enableDrop(col, () => fsParent(filePath));
    col.appendChild(msg('…'));
    fetch(`/api/fs/preview?path=${encodeURIComponent(filePath)}`)
      .then((r) => r.json())
      .then((info) => {
        if (g !== gen) return; // superseded by a newer render
        col.replaceChildren(info.error ? msg(info.error) : previewContent(filePath, info));
      })
      .catch(() => { if (g === gen) col.replaceChildren(msg('preview failed')); });
    return col;
  }

  let gen = 0; // render generation, guards async results from stale renders
  let rightmostDir = null; // deepest directory column shown — the paste target
  async function rerender() {
    const g = ++gen;
    const chain = fsChain(state.dir);
    const lists = await Promise.all(chain.map(list));
    if (g !== gen) return;

    const entries = lists[chain.length - 1].entries || [];
    const cursorEntry = entries.find((e) => e.name === state.cursor) || null;
    if (!cursorEntry) state.cursor = null;
    rightmostDir = cursorEntry?.type === 'dir'
      ? fsJoin(state.dir, cursorEntry.name)
      : state.dir;

    const colEls = chain.map((dirPath, i) => buildCol(
      dirPath,
      lists[i],
      i < chain.length - 1 ? fsBase(chain[i + 1]) : state.cursor,
      i === chain.length - 1,
    ));

    if (cursorEntry?.type === 'dir') {
      const subList = await list(rightmostDir);
      if (g !== gen) return;
      colEls.push(buildCol(rightmostDir, subList, null, false));
    } else if (cursorEntry) {
      colEls.push(buildPreviewCol(fsJoin(state.dir, cursorEntry.name), g));
    }

    colsEl.replaceChildren(...colEls);
    if (tile.labelEl) tile.labelEl.textContent = tile.label();
    saveWidgets();
    requestAnimationFrame(() => {
      colsEl.scrollLeft = colsEl.scrollWidth; // newest column in view
      colsEl.querySelector('.files-entry.cursor')?.scrollIntoView({ block: 'nearest' });
    });
  }

  enableDrop(colsEl, () => rightmostDir || state.dir);

  colsEl.addEventListener('paste', (ev) => {
    const files = [...(ev.clipboardData?.items || [])]
      .filter((i) => i.kind === 'file')
      .map((i) => i.getAsFile())
      .filter(Boolean)
      .map((f) => ({ file: f, name: f.name }));
    if (!files.length) return;
    ev.preventDefault();
    uploadTo(rightmostDir || state.dir, files);
  });

  colsEl.addEventListener('keydown', async (ev) => {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    const step = { ArrowUp: -1, k: -1, ArrowDown: 1, j: 1 }[ev.key];
    if (step) {
      ev.preventDefault();
      const entries = (await list(state.dir)).entries || [];
      if (!entries.length) return;
      const i = entries.findIndex((e) => e.name === state.cursor);
      const next = i === -1
        ? (step > 0 ? 0 : entries.length - 1)
        : Math.max(0, Math.min(entries.length - 1, i + step));
      state.cursor = entries[next].name;
      rerender();
    } else if (ev.key === 'ArrowRight' || ev.key === 'l' || ev.key === 'Enter') {
      const cur = ((await list(state.dir)).entries || []).find((e) => e.name === state.cursor);
      if (cur?.type !== 'dir') return;
      ev.preventDefault();
      state.dir = fsJoin(state.dir, cur.name);
      state.cursor = ((await list(state.dir)).entries || [])[0]?.name ?? null;
      rerender();
    } else if (ev.key === 'ArrowLeft' || ev.key === 'h') {
      if (state.dir === '/') return;
      ev.preventDefault();
      state.cursor = fsBase(state.dir);
      state.dir = fsParent(state.dir);
      rerender();
    }
  });

  const tile = {
    root,
    term: null,
    ws: null,
    labelEl: null,
    opened: false,
    label: () => fsBase(state.dir),
    focus() { colsEl.focus(); },
    fitAndReport() {}, // no terminal geometry to report
    openIfNeeded() {
      if (!root.isConnected) return;
      if (this.opened) {
        // re-attached after a tab switch: restore the rightmost-column view
        requestAnimationFrame(() => { colsEl.scrollLeft = colsEl.scrollWidth; });
        return;
      }
      this.opened = true;
      (async () => {
        // Resolve '~' (or a since-deleted dir) to a real absolute path first.
        let data = await list(state.dir);
        if (data.error) {
          state.cursor = null;
          data = await list('~');
        }
        state.dir = data.path || '/';
        rerender();
      })();
    },
  };

  return tile;
}
