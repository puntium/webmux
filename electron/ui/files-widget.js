/* File browser widget (Finder-style Miller columns) — a client-side pane type.

   A files pane lives entirely in the browser: its id is `files-<random>`
   (never a server session id) and its state ({ dir, cursor }) persists in
   localStorage next to the layout. Columns show the ancestor chain of `dir`;
   the cursor entry gets one extra column — a listing for directories, a
   preview (text/image/zip tree/stat) for files — markdown renders by
   default, with a Rendered / Source toggle in the preview header, which
   also has a ⤓ button that downloads the file (/api/fs/raw?download=1);
   D does the same from the keyboard. Listing columns size themselves to
   their longest name (within limits); the preview column is wide for
   content and narrow when there is nothing to show but the stat line.
   Arrows / hjkl navigate like yazi; → on a file "drills" into its preview
   (the header takes the selection highlight, ↑/↓ scroll the content, ←
   steps back out); drilling back into a directory visited earlier in this
   session re-selects the entry that was under the cursor there. The pane
   title is the path to the selection, home abbreviated to ~ and parent
   segments collapsed to … before the file name is ever cut. r/F2 renames
   the selected entry inline and d/Delete deletes it (after a confirm
   centred in the pane; directories delete recursively) — both also have
   buttons on the selected row. Files or folders dragged onto a column upload into that column's
   directory (folders recreate their tree); files or images pasted while the
   widget is focused upload into the rightmost directory shown. Listings
   stay live: the cursor's directory (and the folder it points at) are
   watched over /api/fs/watch (server-sent events) and re-list on change,
   and the pane regaining focus re-lists every column shown.
   Renders are keyed diffs (patchCols): surviving columns keep their scroll
   position, removed ones collapse and new ones grow in, and the horizontal
   scroll eases to the newest column instead of jumping.

   app.js owns the layout machinery and registers the tile returned by
   makeFilesTile() — the tile interface it expects is
   { root, openIfNeeded(), fitAndReport(), focus(), term, ws, label() },
   plus an optional dispose() it calls when the pane closes. */

// Circular with app.js's import of this module, which is fine: both modules
// only call across the cycle at runtime, never during evaluation.
import { activateLink, setStatus, showLinkModal } from './app.js';
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

// The server's home directory (what '~' resolves to), learned once per page
// from the listing of '~' and used to abbreviate title paths. Left unknown
// (no abbreviation) while the API is unreachable; the next pane open retries.
let homeDir = null;
let homePromise = null;
const learnHome = () => homePromise ||= fetch(`${API}/api/fs/list?path=~`)
  .then((r) => r.json())
  .then((d) => { homeDir = d.path && d.path !== '/' ? d.path : null; })
  .catch(() => { homePromise = null; });
const tildePath = (p) => (homeDir && (p === homeDir || p.startsWith(homeDir + '/'))
  ? '~' + p.slice(homeDir.length)
  : p);

let measureCtx = null;
function textWidth(text, font) {
  measureCtx ||= document.createElement('canvas').getContext('2d');
  measureCtx.font = font;
  return measureCtx.measureText(text).width;
}

// Shorten a display path to `maxWidth` (as measured by `measure`) while
// keeping its last segment whole for as long as possible: interior
// directories collapse into one '…' starting next to the anchor ('~' or the
// root), then the anchor goes, then only the name is left (the label's own
// text-overflow takes it from there).
//   ~/src/webmux/electron/ui/app.js → ~/…/electron/ui/app.js → ~/…/ui/app.js
//   → ~/…/app.js → …/app.js → app.js
function fitPath(display, maxWidth, measure) {
  if (measure(display) <= maxWidth) return display;
  const dirs = display.split('/');
  const name = dirs.pop();
  if (!name) return display; // '/' itself
  for (let tail = dirs.length - 2; tail >= 0; tail--) {
    const s = `${[dirs[0], '…', ...dirs.slice(dirs.length - tail)].join('/')}/${name}`;
    if (measure(s) <= maxWidth) return s;
  }
  const s = `…/${name}`;
  return measure(s) <= maxWidth ? s : name;
}

// Zip members as a tree: { name, dir, size, children: Map }. Directories
// with no entry of their own are implied by their children's paths; a
// member that has children is a directory whatever its own entry said.
function zipTree(entries) {
  const root = { children: new Map() };
  for (const e of entries) {
    let node = root;
    for (const seg of e.name.split('/').filter(Boolean)) {
      let next = node.children.get(seg);
      if (!next) node.children.set(seg, next = { name: seg, dir: true, size: 0, children: new Map() });
      node = next;
    }
    if (node !== root && !e.dir) { node.dir = false; node.size = e.size; }
  }
  return root;
}

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

// Native file drops only (text/plain drags are not files and fall through). Dropped directories are walked recursively so
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

// Delete confirmation, styled like the terminal link chooser but scoped to
// the pane: the overlay is absolutely positioned inside `host` so the box
// centres over the file browser and the rest of the layout is untouched.
// Resolves true on confirm; Escape / backdrop / Cancel resolve false.
function confirmModal(host, text) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay files-modal-overlay';
    overlay.innerHTML = `
      <div class="modal files-confirm" role="dialog" aria-label="Confirm delete">
        <div class="files-confirm-text"></div>
        <div class="actions">
          <button class="link-cancel">Cancel</button>
          <button class="confirm-del danger">Delete</button>
        </div>
      </div>`;
    overlay.querySelector('.files-confirm-text').textContent = text;
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
    host.appendChild(overlay);
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

  // Short-TTL listing cache: keyboard navigation stays snappy; external
  // changes arrive through the directory watch and the focus refresh
  // (both drop the affected entries), or on the next interaction a few
  // seconds later at worst.
  const listCache = new Map(); // dir -> { t, data }
  const LIST_TTL = 4000;

  // Where the cursor sat in each directory visited this session (memory
  // only): drilling back into a folder re-selects that entry.
  const cursorMemory = new Map(); // dir -> entry name
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
    const ok = await confirmModal(root, entry.type === 'dir'
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
      if (!ev.dataTransfer?.files.length) return; // not a file drop
      ev.preventDefault();
      ev.stopPropagation();
      el.classList.remove('drop-target');
      const dir = targetDir(); // capture before the async walk; navigation may move it
      const files = await dropFiles(ev);
      if (!files.length) return setStatus('nothing to upload');
      uploadTo(dir, files);
    });
  }

  // A listing column is as wide as its longest name plus the row chrome
  // (padding, arrow, the selected row's action buttons), between COL_MIN and
  // COL_MAX, so long filenames read whole instead of ellipsizing at a fixed
  // width. Measured on a canvas in the rows' font — cheaper than a layout
  // pass and, being an explicit pixel width, still animatable.
  const COL_MIN = 200;
  const COL_MAX = 420;
  const COL_CHROME = 72;
  function colWidth(entries) {
    const font = `12.5px ${getComputedStyle(colsEl).fontFamily || 'sans-serif'}`;
    let w = 0;
    for (const e of entries) w = Math.max(w, textWidth(e.name, font));
    return Math.round(Math.max(COL_MIN, Math.min(COL_MAX, w + COL_CHROME)));
  }

  function buildCol(dirPath, data, hlName, isCursorCol) {
    const col = document.createElement('div');
    col.className = 'files-col';
    col.dataset.key = dirPath;
    if (data.entries?.length) col.style.width = `${colWidth(data.entries)}px`;
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
        setDrilled(null); // the listing row takes the selection back
        rerender();
        colsEl.focus();
      });
      col.appendChild(row);
    }
    if (data.truncated) col.appendChild(msg('(list truncated)'));
    return col;
  }

  // Download: a link to the raw bytes as an attachment. Same-origin (plain
  // browser) the download attribute saves it directly; under the Electron
  // client the API is another origin, so the click is a navigation that
  // main.js lets through for exactly this URL shape — the attachment
  // response then becomes a save dialog and the page stays put. The
  // preview header's ⤓ is such a link; D builds and clicks a throwaway one.
  const downloadHref = (filePath) => `${API}/api/fs/raw?path=${encodeURIComponent(filePath)}&download=1`;
  function download(filePath) {
    const a = document.createElement('a');
    a.href = downloadHref(filePath);
    a.download = fsBase(filePath);
    a.hidden = true;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setStatus(`downloading ${fsBase(filePath)}`);
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
    const metaBits = [formatSize(info.size)];
    if (info.kind === 'zip') metaBits.push(`${info.count} ${info.count === 1 ? 'entry' : 'entries'}`);
    metaBits.push(new Date(info.mtime).toLocaleString());
    fmeta.textContent = metaBits.join(' · ');
    ftext.append(fname, fmeta);
    head.appendChild(ftext);

    if (info.kind !== 'other') {
      const dl = document.createElement('a');
      dl.className = 'files-act files-download';
      dl.href = downloadHref(filePath);
      dl.download = fsBase(filePath);
      dl.title = 'Download (D)';
      dl.setAttribute('aria-label', `Download ${fsBase(filePath)}`);
      dl.textContent = '⤓';
      dl.addEventListener('click', () => {
        setStatus(`downloading ${fsBase(filePath)}`);
        colsEl.focus(); // keep keyboard navigation on the columns
      });
      head.appendChild(dl);
    }

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
      // Links: web URLs behave like terminal links (click opens, ⇧-click
      // copies); mailto: gets the chooser since the shell won't open it;
      // relative ones navigate the browser to that entry.
      body.addEventListener('click', (ev) => {
        const a = ev.target.closest('a[href]');
        if (!a || !body.contains(a)) return;
        ev.preventDefault();
        const href = a.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        if (/^https?:/i.test(href)) return activateLink(ev, href);
        if (/^mailto:/i.test(href)) return showLinkModal(href, tile);
        const local = resolveRelative(fileDir, href.split(/[#?]/)[0]);
        if (!local) return setStatus(`can't open ${href}`);
        state.dir = fsParent(local);
        state.cursor = fsBase(local);
        rerender();
      });
    } else if (info.kind === 'text') {
      sourceView();
    } else if (info.kind === 'zip') {
      // Table of contents as a `tree`-style listing: one row per member,
      // nested under its parent with ├──/└── connectors instead of the full
      // path repeated on every line; folders first, then by name; files
      // carry their uncompressed size at the right.
      const listEl = document.createElement('div');
      listEl.className = 'files-zip';
      const isDir = (n) => n.dir || n.children.size > 0;
      const byName = (a, b) => (isDir(a) === isDir(b)
        ? a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
        : isDir(a) ? -1 : 1);
      const walk = (node, indent) => {
        const kids = [...node.children.values()].sort(byName);
        kids.forEach((kid, i) => {
          const last = i === kids.length - 1;
          const row = document.createElement('div');
          row.className = 'files-zip-entry' + (isDir(kid) ? ' dir' : '');
          const tree = document.createElement('span');
          tree.className = 'files-zip-tree';
          tree.textContent = indent + (last ? '└── ' : '├── ');
          const nm = document.createElement('span');
          nm.className = 'files-zip-name';
          nm.textContent = kid.name + (isDir(kid) ? '/' : '');
          const sz = document.createElement('span');
          sz.className = 'files-zip-size';
          sz.textContent = isDir(kid) ? '' : formatSize(kid.size);
          row.append(tree, nm, sz);
          listEl.appendChild(row);
          walk(kid, indent + (last ? '    ' : '│   '));
        });
      };
      walk(zipTree(info.entries), '');
      body.appendChild(listEl);
      if (!info.entries.length) body.appendChild(msg('(empty archive)'));
      if (info.truncated) body.appendChild(msg('(list truncated)'));
    } else if (info.kind === 'binary') {
      body.appendChild(msg('binary file'));
    } else {
      body.appendChild(msg('no preview'));
    }

    wrap.append(head, body);
    return wrap;
  }

  // Previews with nothing to show but the header (binary files, sockets,
  // stat errors) get the narrow preview column.
  const hasPreview = (info) => !info.error && ['image', 'text', 'zip'].includes(info.kind);

  function buildPreviewCol(filePath, g) {
    const col = document.createElement('div');
    col.className = 'files-col files-preview';
    // Fixed key: moving the cursor between files updates the one preview
    // column in place instead of tearing it down and growing a new one.
    col.dataset.key = 'preview';
    col.dataset.path = filePath;
    enableDrop(col, () => fsParent(filePath));
    // Start at the width the preview column already has (narrow or wide)
    // and settle once the stat arrives, so stepping between files of a
    // kind doesn't flicker the column through the other width.
    const prev = colsEl.querySelector('.files-preview:not(.leaving)');
    col.classList.toggle('narrow', !!prev?.classList.contains('narrow'));
    // A re-render of the same file (directory watch, focus refresh) keeps
    // the reader's place in the content.
    const keepScroll = prev?.dataset.path === filePath
      ? prev.querySelector('.files-preview-body')?.scrollTop || 0
      : 0;
    col.appendChild(msg('…'));
    // Clicking the preview (not its buttons or links) drills into it, like →.
    col.addEventListener('click', (ev) => {
      if (ev.target.closest('a, button, input')) return;
      if (col.classList.contains('narrow')) return;
      setDrilled(filePath);
    });
    fetch(`${API}/api/fs/preview?path=${encodeURIComponent(filePath)}`)
      .then((r) => r.json())
      .then((info) => {
        if (g !== gen) return; // superseded by a newer render
        const narrow = !hasPreview(info);
        const resized = col.classList.contains('narrow') !== narrow;
        col.classList.toggle('narrow', narrow);
        col.replaceChildren(info.error ? msg(info.error) : previewContent(filePath, info));
        if (keepScroll) {
          const body = col.querySelector('.files-preview-body');
          if (body) body.scrollTop = keepScroll;
        }
        if (narrow && drilled === filePath) setDrilled(null); // nothing to scroll
        if (resized) smoothScrollRight(); // follow the column's width transition
      })
      .catch(() => { if (g === gen) col.replaceChildren(msg('preview failed')); });
    return col;
  }

  // "Drilled" preview: → on a file moves the selection into its preview
  // column. The header takes the cursor highlight (the listing row drops to
  // the on-path look), ↑/↓ PageUp/PageDown Home/End scroll the content and
  // ←/Escape step back out. Memory only and bound to one file: the cursor
  // moving anywhere else leaves it. The horizontal scroll follows the
  // selection: drilling in brings the whole preview column on screen (its
  // header buttons included, even if that pushes the listing off the left
  // edge), leaving puts the cursor's column back in view.
  let drilled = null; // path of the file whose preview holds the selection
  function setDrilled(filePath) {
    if (drilled === filePath) return;
    drilled = filePath;
    colsEl.classList.toggle('drilled', !!drilled);
    smoothScrollRight();
  }
  const previewBody = () => colsEl.querySelector('.files-preview:not(.leaving) .files-preview-body');
  const SCROLL_STEP = 48; // px per ↑/↓ — about three lines of the mono preview

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
    else cursorMemory.set(state.dir, cursorEntry.name);
    const previewPath = cursorEntry && cursorEntry.type !== 'dir' ? fsJoin(state.dir, cursorEntry.name) : null;
    if (drilled && drilled !== previewPath) setDrilled(null);
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
      colEls.push(buildPreviewCol(previewPath, g));
    }

    const animate = patchCols(colEls);
    fitLabel();
    saveWidgets();
    syncWatchers();
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
      setTimeout(drop, 300); // in case animationend never fires (hidden pane)
    }
    return animate;
  }

  // Ease the horizontal scroll toward "rightmost column at the right edge",
  // re-reading the target every frame because column widths are animating
  // underneath. The cursor's own column is never pushed off the left edge —
  // unless the selection is in the preview, which then shows whole instead.
  // A wheel gesture cancels the chase so the user can take over mid-flight.
  let scrollAnim = 0;
  colsEl.addEventListener('wheel', () => cancelAnimationFrame(scrollAnim), { passive: true });
  function smoothScrollRight() {
    cancelAnimationFrame(scrollAnim);
    if (!colsEl.isConnected) return;
    const target = () => {
      let t = colsEl.scrollWidth - colsEl.clientWidth;
      const cursorCol = drilled ? null : colsEl.querySelector('.files-entry.cursor')?.closest('.files-col');
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

  // Live listings: one server-sent-events stream per watched directory —
  // the cursor's directory and, when the cursor is on a folder, that folder
  // (the deepest listing shown). A change drops that directory's cache
  // entry and re-renders. Directories whose listing failed aren't watched
  // (the server would only report them gone again); `gone` closes the
  // stream so EventSource doesn't keep reconnecting to a deleted path.
  const watchers = new Map(); // dir -> EventSource
  let watchRefresh = 0;
  function syncWatchers() {
    const want = new Set([state.dir, rightmostDir].filter((d) => d && !listCache.get(d)?.data?.error));
    for (const [dir, es] of watchers) {
      if (!want.has(dir)) { es.close(); watchers.delete(dir); }
    }
    for (const dir of want) {
      if (watchers.has(dir)) continue;
      const es = new EventSource(`${API}/api/fs/watch?path=${encodeURIComponent(dir)}`);
      let opened = false;
      es.addEventListener('open', () => {
        if (opened) changed(dir); // reconnected after a tunnel blip: events may have been missed
        opened = true;
      });
      es.addEventListener('change', () => changed(dir));
      es.addEventListener('gone', () => { es.close(); watchers.delete(dir); changed(dir); });
      es.addEventListener('error', () => {
        // A CLOSED stream won't retry on its own; forget it so the next
        // render can open a fresh one. CONNECTING is a retry in progress.
        if (es.readyState === EventSource.CLOSED) watchers.delete(dir);
      });
      watchers.set(dir, es);
    }
  }
  function changed(dir) {
    listCache.delete(dir);
    if (colsEl.querySelector('.files-rename')) return; // don't yank the input mid-rename
    clearTimeout(watchRefresh);
    watchRefresh = setTimeout(rerender, 50);
  }

  // The pane regaining focus (a click into it, ⌘-navigation onto it, the
  // app returning to the foreground) re-lists every column shown: parents
  // too, not only the cursor's directory. Cache entries fetched in the last
  // second are kept, so the focus that follows the first render doesn't
  // list everything twice.
  function refreshAll() {
    if (!root.isConnected || !tile.opened) return;
    const now = Date.now();
    for (const [dir, hit] of listCache) {
      if (now - hit.t > 1000) listCache.delete(dir);
    }
    if (colsEl.querySelector('.files-rename')) return;
    rerender();
  }
  root.addEventListener('focusin', (ev) => {
    if (root.contains(ev.relatedTarget)) return; // focus moved within the pane (rename input, modal, buttons)
    refreshAll();
  });
  const onWindowFocus = () => { if (root.contains(document.activeElement)) refreshAll(); };
  window.addEventListener('focus', onWindowFocus);

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

  // Pane title: the path to the selection, home abbreviated to '~', fitted
  // to the label's width by fitPath (parents collapse to '…' before the
  // name is touched). Refitted on every render and whenever the label's box
  // changes size (pane or window resize, columns moving). Measured in the
  // focused bar's bold weight so the text still fits when focus arrives;
  // the full path is the label's tooltip.
  let labelEl = null;
  const labelRO = new ResizeObserver(() => fitLabel());
  function fitLabel() {
    if (!labelEl?.clientWidth) return;
    const full = tile.label();
    labelEl.title = full;
    const cs = getComputedStyle(labelEl);
    const font = `600 ${cs.fontSize} ${cs.fontFamily}`;
    labelEl.textContent = fitPath(full, labelEl.clientWidth - 1, (t) => textWidth(t, font));
  }

  colsEl.addEventListener('keydown', async (ev) => {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (ev.target !== colsEl) return; // e.g. the inline rename input
    if (drilled) {
      // The selection is in the preview: vertical keys scroll it, ← leaves.
      // Anything else (r, d, D…) still acts on the file under the cursor.
      const body = previewBody();
      const by = { ArrowUp: -SCROLL_STEP, k: -SCROLL_STEP, ArrowDown: SCROLL_STEP, j: SCROLL_STEP }[ev.key]
        ?? (body && { PageUp: -body.clientHeight * 0.9, PageDown: body.clientHeight * 0.9, ' ': body.clientHeight * 0.9 }[ev.key]);
      if (by) {
        ev.preventDefault();
        body?.scrollBy(0, by);
        return;
      }
      if (ev.key === 'Home' || ev.key === 'End') {
        ev.preventDefault();
        if (body) body.scrollTop = ev.key === 'Home' ? 0 : body.scrollHeight;
        return;
      }
      if (ev.key === 'ArrowLeft' || ev.key === 'h' || ev.key === 'Escape') {
        ev.preventDefault();
        setDrilled(null);
        return;
      }
      if (ev.key === 'ArrowRight' || ev.key === 'l' || ev.key === 'Enter') {
        ev.preventDefault();
        return;
      }
    }
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
      if (!cur) return;
      ev.preventDefault();
      if (cur.type !== 'dir') {
        // A file: drill into its preview, once there is content to scroll
        // (a narrow stat-only column has nothing to drill into).
        if (previewBody() && !colsEl.querySelector('.files-preview.narrow')) {
          setDrilled(fsJoin(state.dir, cur.name));
        }
        return;
      }
      state.dir = fsJoin(state.dir, cur.name);
      const sub = (await list(state.dir)).entries || [];
      const remembered = cursorMemory.get(state.dir);
      state.cursor = (sub.find((e) => e.name === remembered) || sub[0])?.name ?? null;
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
    } else if (ev.key === 'D') {
      if (!state.cursor) return;
      ev.preventDefault();
      const cur = ((await list(state.dir)).entries || []).find((e) => e.name === state.cursor);
      if (!cur) return;
      if (cur.type === 'dir') return setStatus('select a file to download');
      download(fsJoin(state.dir, cur.name));
    }
  });

  const tile = {
    root,
    term: null,
    ws: null,
    opened: false,
    // app.js assigns the bar's label element here (again after every layout
    // re-render); the widget keeps it fitted as long as it is attached.
    get labelEl() { return labelEl; },
    set labelEl(el) {
      if (labelEl) labelRO.unobserve(labelEl);
      labelEl = el;
      if (el) labelRO.observe(el);
    },
    label: () => tildePath(state.cursor ? fsJoin(state.dir, state.cursor) : state.dir),
    focus() { colsEl.focus({ preventScroll: true }); }, // app.js animates the strip itself
    fitAndReport() {}, // no terminal geometry to report
    dispose() { // pane closed: drop the watch streams and the window listener
      window.removeEventListener('focus', onWindowFocus);
      labelRO.disconnect();
      for (const es of watchers.values()) es.close();
      watchers.clear();
    },
    openIfNeeded() {
      if (!root.isConnected) return;
      if (this.opened) {
        // re-attached after a layout re-render: restore the rightmost-column view
        requestAnimationFrame(() => { colsEl.scrollLeft = colsEl.scrollWidth; });
        return;
      }
      this.opened = true;
      (async () => {
        // Resolve '~' (or a since-deleted dir) to a real absolute path first.
        let [data] = await Promise.all([list(state.dir), learnHome()]);
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
