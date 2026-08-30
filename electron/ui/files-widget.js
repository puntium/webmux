/* File browser widget (Finder-style Miller columns) — a client-side tab type.

   A files tab lives entirely in the browser: its id is `files-<random>`
   (never a server session id) and its state ({ dir, cursor }) persists in
   localStorage next to the layout. Columns show the ancestor chain of `dir`;
   the cursor entry gets one extra column — a listing for directories, a
   preview (text/image/stat) for files — markdown renders by default, with a
   Rendered / Source toggle in the preview header. Arrows / hjkl navigate
   like yazi;
   r/F2 renames the selected entry inline and d/Delete deletes it (after a
   confirm; directories delete recursively) — both also have buttons on the
   selected row. Files or folders dragged onto a column upload into that
   column's directory (folders recreate their tree); files or images pasted
   while the widget is focused upload into the rightmost directory shown.
   Renders are keyed diffs (patchCols): surviving columns keep their scroll
   position, removed ones collapse and new ones grow in, and the horizontal
   scroll eases to the newest column instead of jumping.

   app.js owns the layout/tab machinery and registers the tile returned by
   makeFilesTile() — the tile interface it expects is
   { root, openIfNeeded(), fitAndReport(), focus(), term, ws, label() }. */

// Circular with app.js's import of this module, which is fine: both modules
// only call across the cycle at runtime, never during evaluation.
import { setStatus, showLinkModal } from './app.js';
import { API } from './env.js';

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

const isMarkdownName = (name) => /\.(md|markdown|mdown|mkd)$/i.test(name);

// Resolve a relative link from a markdown file against that file's
// directory; returns null for anything with a scheme (http:, mailto:, …).
function resolveRelative(baseDir, href) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return null;
  const segs = (href.startsWith('/') ? [] : baseDir.split('/').filter(Boolean));
  for (const seg of href.split('/')) {
    if (!seg || seg === '.') continue;
    if (seg === '..') segs.pop();
    else segs.push(seg);
  }
  return '/' + segs.join('/');
}

// Markdown → DOM via marked (vendored by the client at /vendor/marked). The
// preview is a viewer, not a web page: raw HTML in the source is shown as
// literal text, the output is parsed in an inert document and scrubbed
// (no scripts, no on* handlers) before it touches the page, and relative
// image paths are served through /api/fs/raw so a README's screenshots
// show. Returns null when the renderer isn't available.
let mdParser = null;
function renderMarkdown(src, fileDir) {
  if (typeof marked === 'undefined') return null;
  mdParser ||= new marked.Marked({
    gfm: true,
    renderer: {
      html({ text, block }) {
        const esc = text.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
        return block ? `<p>${esc}</p>\n` : esc;
      },
    },
  });
  let html;
  try { html = mdParser.parse(src); }
  catch { return null; }
  const doc = new DOMParser().parseFromString(`<div class="files-md">${html}</div>`, 'text/html');
  for (const el of doc.querySelectorAll('script, style, iframe, object, embed, link, meta')) el.remove();
  for (const el of doc.body.querySelectorAll('*')) {
    for (const a of [...el.attributes]) {
      if (/^on/i.test(a.name)) el.removeAttribute(a.name);
    }
  }
  for (const img of doc.querySelectorAll('img[src]')) {
    const local = resolveRelative(fileDir, img.getAttribute('src'));
    if (local) img.src = `${API}/api/fs/raw?path=${encodeURIComponent(local)}`;
  }
  for (const input of doc.querySelectorAll('input')) input.disabled = true; // task-list boxes
  return document.adoptNode(doc.body.firstElementChild);
}

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

// Delete confirmation, styled like the terminal link chooser. Resolves true
// on confirm; Escape / backdrop / Cancel resolve false.
function confirmModal(text) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'link-modal-overlay';
    overlay.innerHTML = `
      <div class="link-modal" role="dialog" aria-label="Confirm delete">
        <div class="link-url"></div>
        <div class="link-actions">
          <button class="link-cancel">Cancel</button>
          <button class="confirm-del danger">Delete</button>
        </div>
      </div>`;
    overlay.querySelector('.link-url').textContent = text;
    const done = (val) => {
      overlay.remove();
      document.removeEventListener('keydown', onKey, true);
      resolve(val);
    };
    const onKey = (ev) => {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        ev.stopPropagation();
        done(false);
      }
    };
    document.addEventListener('keydown', onKey, true);
    overlay.addEventListener('click', (ev) => { if (ev.target === overlay) done(false); });
    overlay.querySelector('.link-cancel').addEventListener('click', () => done(false));
    overlay.querySelector('.confirm-del').addEventListener('click', () => done(true));
    document.body.appendChild(overlay);
    overlay.querySelector('.confirm-del').focus();
  });
}

async function fsApi(endpoint, body) {
  const res = await fetch(`${API}/api/fs/${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const out = await res.json();
  if (out.error) throw new Error(out.error);
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
      data = await (await fetch(`${API}/api/fs/list?path=${encodeURIComponent(dir)}`)).json();
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
        const res = await fetch(`${API}/api/fs/upload?${q}`, {
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

  // Delete the entry under the cursor (after confirmation); the cursor moves
  // to the next entry, Finder-style, so repeated deletes flow.
  async function deleteCursor() {
    const name = state.cursor;
    if (!name) return;
    const entries = (await list(state.dir)).entries || [];
    const entry = entries.find((e) => e.name === name);
    if (!entry) return;
    const ok = await confirmModal(entry.type === 'dir'
      ? `Delete folder “${name}” and everything in it?`
      : `Delete “${name}”?`);
    colsEl.focus();
    if (!ok) return;
    try {
      await fsApi('delete', { path: fsJoin(state.dir, name) });
    } catch (err) {
      setStatus(`delete failed: ${err.message || err}`);
      return;
    }
    setStatus(`deleted ${name}`);
    const i = entries.findIndex((e) => e.name === name);
    const rest = entries.filter((e) => e.name !== name);
    state.cursor = rest[Math.min(i, rest.length - 1)]?.name ?? null;
    listCache.delete(state.dir);
    rerender();
  }

  // Swap the cursor row's name for an inline input. Enter commits, Escape or
  // focus loss cancels; the stem is preselected like Finder's rename.
  function startRename() {
    const row = colsEl.querySelector('.files-entry.cursor');
    const nameEl = row?.querySelector('.files-name');
    if (!nameEl || row.querySelector('input')) return;
    const oldName = state.cursor;
    const input = document.createElement('input');
    input.className = 'files-rename';
    input.value = oldName;
    nameEl.replaceWith(input);
    input.focus();
    const dot = oldName.startsWith('.') ? -1 : oldName.lastIndexOf('.');
    input.setSelectionRange(0, dot > 0 ? dot : oldName.length);
    let settled = false;
    const finish = async (commit) => {
      if (settled) return;
      settled = true;
      const newName = input.value.trim();
      if (commit && newName && newName !== oldName) {
        try {
          const out = await fsApi('rename', { path: fsJoin(state.dir, oldName), name: newName });
          state.cursor = out.name;
          setStatus(`renamed ${oldName} → ${out.name}`);
        } catch (err) {
          setStatus(`rename failed: ${err.message || err}`);
        }
        listCache.delete(state.dir);
      }
      rerender();
      colsEl.focus();
    };
    input.addEventListener('keydown', (ev) => {
      ev.stopPropagation(); // typed letters must not become navigation
      if (ev.key === 'Enter') finish(true);
      else if (ev.key === 'Escape') finish(false);
    });
    input.addEventListener('blur', () => finish(false));
    input.addEventListener('click', (ev) => ev.stopPropagation()); // no cursor re-set
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
    col.dataset.key = dirPath;
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
      if (isCursorCol && e.name === hlName) {
        // Mouse affordance for the keyboard actions, shown on the selected
        // row only.
        const mkAct = (txt, title, fn) => {
          const b = document.createElement('button');
          b.className = 'files-act';
          b.textContent = txt;
          b.title = title;
          b.addEventListener('click', (ev) => { ev.stopPropagation(); fn(); });
          return b;
        };
        const acts = document.createElement('span');
        acts.className = 'files-acts';
        acts.append(
          mkAct('✎', 'Rename (r)', startRename),
          mkAct('✕', 'Delete (d)', deleteCursor),
        );
        row.appendChild(acts);
      }
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

  // Rendered-vs-source choice for markdown previews. Remembered while the
  // tile lives (not persisted): flipping to Source and stepping to the next
  // .md keeps showing source; a fresh tile starts rendered.
  let mdShowSource = false;

  function previewContent(filePath, info) {
    const wrap = document.createElement('div');
    wrap.className = 'files-preview-inner';

    const head = document.createElement('div');
    head.className = 'files-preview-head';
    const ftext = document.createElement('div');
    ftext.className = 'ftext';
    const fname = document.createElement('div');
    fname.className = 'fname';
    fname.textContent = fsBase(filePath);
    const fmeta = document.createElement('div');
    fmeta.className = 'fmeta';
    fmeta.textContent = `${formatSize(info.size)} · ${new Date(info.mtime).toLocaleString()}`;
    ftext.append(fname, fmeta);
    head.appendChild(ftext);

    const body = document.createElement('div');
    body.className = 'files-preview-body';
    const sourceView = () => {
      const pre = document.createElement('pre');
      pre.textContent = info.content || '(empty file)';
      body.replaceChildren(pre);
      if (info.truncated) body.appendChild(msg('(preview truncated)'));
    };
    if (info.kind === 'image') {
      const img = document.createElement('img');
      img.src = `${API}/api/fs/raw?path=${encodeURIComponent(filePath)}`;
      img.alt = fsBase(filePath);
      body.appendChild(img);
    } else if (info.kind === 'text' && isMarkdownName(filePath)) {
      const fileDir = fsParent(filePath);
      const renderedView = () => {
        const md = info.content ? renderMarkdown(info.content, fileDir) : null;
        if (!md) return sourceView(); // renderer unavailable / empty file
        body.replaceChildren(md);
        if (info.truncated) body.appendChild(msg('(preview truncated)'));
      };
      const toggle = document.createElement('div');
      toggle.className = 'files-view-toggle';
      toggle.setAttribute('role', 'group');
      toggle.setAttribute('aria-label', 'Markdown view');
      const mkBtn = (txt, source) => {
        const b = document.createElement('button');
        b.textContent = txt;
        b.addEventListener('click', () => {
          if (mdShowSource === source) return;
          mdShowSource = source;
          apply();
          colsEl.focus();
        });
        return b;
      };
      const btns = [mkBtn('Rendered', false), mkBtn('Source', true)];
      toggle.append(...btns);
      head.appendChild(toggle);
      const apply = () => {
        btns[0].setAttribute('aria-pressed', String(!mdShowSource));
        btns[1].setAttribute('aria-pressed', String(mdShowSource));
        if (mdShowSource) sourceView();
        else renderedView();
      };
      apply();
      // Links: web URLs go through the app's link chooser like terminal
      // links; relative ones navigate the browser to that entry.
      body.addEventListener('click', (ev) => {
        const a = ev.target.closest('a[href]');
        if (!a || !body.contains(a)) return;
        ev.preventDefault();
        const href = a.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        if (/^(https?|mailto):/i.test(href)) return showLinkModal(href, tile);
        const local = resolveRelative(fileDir, href.split(/[#?]/)[0]);
        if (!local) return setStatus(`can't open ${href}`);
        state.dir = fsParent(local);
        state.cursor = fsBase(local);
        rerender();
      });
    } else if (info.kind === 'text') {
      sourceView();
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
    // Fixed key: moving the cursor between files updates the one preview
    // column in place instead of tearing it down and growing a new one.
    col.dataset.key = 'preview';
    enableDrop(col, () => fsParent(filePath));
    col.appendChild(msg('…'));
    fetch(`${API}/api/fs/preview?path=${encodeURIComponent(filePath)}`)
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
  let previewName = null; // file under the cursor (preview showing) — names the tab
  async function rerender() {
    const g = ++gen;
    const chain = fsChain(state.dir);
    const lists = await Promise.all(chain.map(list));
    if (g !== gen) return;

    const entries = lists[chain.length - 1].entries || [];
    const cursorEntry = entries.find((e) => e.name === state.cursor) || null;
    if (!cursorEntry) state.cursor = null;
    previewName = cursorEntry && cursorEntry.type !== 'dir' ? cursorEntry.name : null;
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

    const animate = patchCols(colEls);
    if (tile.labelEl) tile.labelEl.textContent = tile.label();
    saveWidgets();
    requestAnimationFrame(() => {
      if (animate) smoothScrollRight();
      else colsEl.scrollLeft = colsEl.scrollWidth; // first render: jump straight there
      revealCursorRow();
    });
  }

  // Swap the visible column set with enter/leave animations. Columns are
  // keyed by directory path (the preview column by a fixed key): surviving
  // columns are replaced in place with their scroll position carried over,
  // removed ones collapse (.leaving) and new ones grow in (.entering).
  // Entering columns go before any collapsing ones so the two motions read
  // as a single slide. Miller-column navigation only ever changes a suffix
  // of the column list, so in-order insertion after the previous kept/new
  // column is always position-correct.
  function patchCols(colEls) {
    const live = [...colsEl.children].filter((el) => !el.classList.contains('leaving'));
    const oldByKey = new Map(live.map((el) => [el.dataset.key, el]));
    const newKeys = new Set(colEls.map((el) => el.dataset.key));
    const animate = live.length > 0; // the initial render appears without motion
    const leaving = new Set(live.filter((el) => !newKeys.has(el.dataset.key)));
    const isPreview = (el) => el?.classList?.contains('files-preview');
    let anchor = null;
    for (const el of colEls) {
      const old = oldByKey.get(el.dataset.key);
      if (old) {
        const scrollTop = old.scrollTop;
        old.replaceWith(el);
        el.scrollTop = scrollTop;
      } else {
        const next = anchor ? anchor.nextSibling : colsEl.firstChild;
        if (animate && leaving.has(next) && !isPreview(next) && !isPreview(el)) {
          // Same-width column dying in this exact slot (e.g. cursor moved to
          // a sibling folder): the slot's geometry doesn't change, so a
          // grow-beside-collapse would just shove the old column sideways.
          // Swap immediately and fade the new content in instead.
          leaving.delete(next);
          next.replaceWith(el);
          el.classList.add('swapping');
        } else {
          if (animate) el.classList.add('entering');
          colsEl.insertBefore(el, next);
        }
      }
      anchor = el;
    }
    for (const el of leaving) {
      el.classList.add('leaving');
      const drop = (ev) => { if (!ev || ev.target === el) el.remove(); };
      el.addEventListener('animationend', drop);
      setTimeout(drop, 300); // in case animationend never fires (hidden tab)
    }
    return animate;
  }

  // Ease the horizontal scroll toward "rightmost column at the right edge",
  // re-reading the target every frame because column widths are animating
  // underneath. The cursor's own column is never pushed off the left edge.
  // A wheel gesture cancels the chase so the user can take over mid-flight.
  let scrollAnim = 0;
  colsEl.addEventListener('wheel', () => cancelAnimationFrame(scrollAnim), { passive: true });
  function smoothScrollRight() {
    cancelAnimationFrame(scrollAnim);
    if (!colsEl.isConnected) return;
    const target = () => {
      let t = colsEl.scrollWidth - colsEl.clientWidth;
      const cursorCol = colsEl.querySelector('.files-entry.cursor')?.closest('.files-col');
      if (cursorCol) {
        t = Math.min(t, colsEl.scrollLeft
          + cursorCol.getBoundingClientRect().left - colsEl.getBoundingClientRect().left);
      }
      return Math.max(0, t);
    };
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      // Wait out the (near-instant) column animations, then jump.
      setTimeout(() => { colsEl.scrollLeft = target(); }, 30);
      return;
    }
    const t0 = performance.now();
    const step = (now) => {
      const d = target() - colsEl.scrollLeft;
      if (now - t0 >= 300) { colsEl.scrollLeft += d; return; } // settle exactly
      colsEl.scrollLeft += d * 0.25;
      scrollAnim = requestAnimationFrame(step);
    };
    scrollAnim = requestAnimationFrame(step);
  }

  // Vertical-only "scrollIntoView nearest" for the cursor row — real
  // scrollIntoView also scrolls ancestors horizontally, which would fight
  // smoothScrollRight.
  function revealCursorRow() {
    const row = colsEl.querySelector('.files-entry.cursor');
    if (!row) return;
    const col = row.parentElement;
    if (row.offsetTop < col.scrollTop) col.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > col.scrollTop + col.clientHeight) {
      col.scrollTop = row.offsetTop + row.offsetHeight - col.clientHeight;
    }
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
    if (ev.target !== colsEl) return; // e.g. the inline rename input
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
    } else if (ev.key === 'r' || ev.key === 'F2') {
      if (!state.cursor) return;
      ev.preventDefault();
      startRename();
    } else if (ev.key === 'd' || ev.key === 'Delete' || ev.key === 'Backspace') {
      if (!state.cursor) return;
      ev.preventDefault();
      deleteCursor();
    }
  });

  const tile = {
    root,
    term: null,
    ws: null,
    labelEl: null,
    opened: false,
    label: () => previewName || fsBase(state.dir),
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
