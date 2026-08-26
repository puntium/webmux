// webmux — tiled xterm.js sessions with persistent server-side state.
//
// This process is a thin, restartable proxy: HTTP/static plus WebSocket
// termination. The ptys themselves live in a separate long-lived pty host
// daemon (ptyhost.js) reached over a named unix socket, so restarting this
// server never kills a shell. The host is spawned on demand at startup
// (detached) and stops only on `node ptyhost.js shutdown` or an explicit
// kill.
//
// The HTTP server itself also listens on a unix socket (no TCP): filesystem
// permissions (0600 in the 0700 runtime dir) are the whole access story, so
// only this user can connect. The Electron client (electron/) reaches it via
// an SSH forward — `ssh -L 127.0.0.1:<port>:<socket> host` — making sshd the
// only remote way in. There is no browser/TCP deployment mode.

const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');
const yaml = require('js-yaml');
const { WebSocketServer } = require('ws');
const { DEFAULT_NAME, PROTOCOL, runDir, socketPath, readLines, control, ensureHost } = require('./ptyhost-client');

// Deployed payloads carry a PAYLOAD_HASH file stamped by deploy/build-payload.js;
// the Electron client compares it against the payload it ships to decide
// whether to push an update. A dev checkout has no such file and reports
// 'dev', which never matches — so an auto-deploy profile pointed at a dev
// server will replace it (into ~/.webmux/dist, the checkout is untouched).
let PAYLOAD_HASH = 'dev';
try { PAYLOAD_HASH = fs.readFileSync(path.join(__dirname, 'PAYLOAD_HASH'), 'utf8').trim() || 'dev'; } catch { /* dev checkout */ }

// ---------------------------------------------------------------------------
// Config (config.yaml, gitignored — see config.example.yaml)
// ---------------------------------------------------------------------------

const CONFIG_FILE = path.join(__dirname, 'config.yaml');
let config = {};
try {
  config = yaml.load(fs.readFileSync(CONFIG_FILE, 'utf8')) || {};
} catch (err) {
  // No config file, or one that is all comments (js-yaml throws "input is
  // empty" for those), means all defaults; real parse errors still abort.
  const emptyDoc = err.name === 'YAMLException' && /input is empty/.test(err.message);
  if (err.code !== 'ENOENT' && !emptyDoc) {
    console.error(`failed to load ${CONFIG_FILE}: ${err.message}`);
    process.exit(1);
  }
}

// The browser/TCP deployment (TLS + Basic auth on a port) is gone; flag
// leftover config so an old config.yaml fails loudly instead of silently
// serving without the protection it asks for.
for (const key of ['auth', 'tls', 'bind']) {
  if (key in config) {
    console.error(`${CONFIG_FILE}: '${key}' is no longer supported — the server only listens on a unix socket now (connect with the Electron client over SSH; see docs/electron-client.md)`);
    process.exit(1);
  }
}

// Which pty host this server fronts. Different names → independent hosts
// (own socket, own sessions), so several webmux instances can coexist.
const HOST_NAME = process.env.WEBMUX_PTYHOST || config.ptyhost || DEFAULT_NAME;

// Where this HTTP server listens: next to the pty host's socket in the
// runtime dir (0700), named after the host so instances don't collide.
// `socket:` in config overrides the path.
const HTTP_SOCK = config.socket
  ? path.resolve(String(config.socket))
  : path.join(runDir(), `${HOST_NAME}.http.sock`);

// ---------------------------------------------------------------------------
// Pty host RPC (sessions live in ptyhost.js, not here)
// ---------------------------------------------------------------------------

// Control-plane command to the pty host. If the host is gone (crashed or
// explicitly shut down while we were up), respawn it once and retry so the
// web UI self-heals instead of erroring until a server restart.
async function hostControl(msg) {
  try {
    return await control(HOST_NAME, msg);
  } catch {
    await ensureHost(HOST_NAME);
    return control(HOST_NAME, msg);
  }
}

// ---------------------------------------------------------------------------
// HTTP API
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: '30mb' })); // pasted images arrive as base64 JSON
app.use(express.static(path.join(__dirname, 'public')));
app.use('/vendor/xterm', express.static(path.join(__dirname, 'node_modules/@xterm/xterm')));
app.use('/vendor/addon-fit', express.static(path.join(__dirname, 'node_modules/@xterm/addon-fit')));
app.use('/vendor/addon-web-links', express.static(path.join(__dirname, 'node_modules/@xterm/addon-web-links')));

app.get('/api/sessions', async (_req, res) => {
  try {
    res.json((await hostControl({ cmd: 'list' })).sessions);
  } catch (err) {
    res.status(502).json({ error: String(err.message || err) });
  }
});

app.post('/api/sessions', async (req, res) => {
  const { cols, rows } = req.body || {};
  try {
    const r = await hostControl({ cmd: 'create', cols: cols || 80, rows: rows || 24 });
    res.status(201).json({ id: r.id });
  } catch (err) {
    res.status(502).json({ error: String(err.message || err) });
  }
});

// Pasted images land in PASTE_DIR. The latest one is also written to the
// "clipboard" slot that the xclip/xsel shims serve, so clipboard-reading CLIs
// (Claude Code) see it natively. Must match the pty host's PASTE_DIR (it
// exports WEBMUX_CLIPBOARD_DIR into sessions).
const PASTE_DIR = path.join(os.tmpdir(), 'webmux-pastes');
fs.mkdirSync(PASTE_DIR, { recursive: true });
const PASTE_EXT = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/bmp': 'bmp',
};
let pasteSeq = 0;

// Command line of the process in the foreground of a session's terminal
// (tpgid of the shell's controlling tty, via /proc). The shell pid comes
// from the pty host's snapshot frame; host and server share a machine, so
// /proc is readable directly.
function foregroundCmdline(session) {
  try {
    const stat = fs.readFileSync(`/proc/${session.pid}/stat`, 'utf8');
    const tpgid = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[5];
    return fs.readFileSync(`/proc/${tpgid}/cmdline`, 'utf8').replace(/\0/g, ' ').trim();
  } catch {
    return '';
  }
}

function isClaudeForeground(session) {
  const argv = foregroundCmdline(session).split(' ');
  return argv.slice(0, 2).some((a) => path.basename(a).startsWith('claude'));
}

// Update the clipboard slot the xclip/xsel shims serve. Returns the decoded
// image, or null if the payload isn't a supported image.
function writeClipboardSlot({ mime, data }) {
  const ext = PASTE_EXT[mime];
  if (!ext || typeof data !== 'string') return null;
  const buf = Buffer.from(data, 'base64');
  fs.writeFileSync(path.join(PASTE_DIR, 'clipboard'), buf);
  fs.writeFileSync(path.join(PASTE_DIR, 'clipboard.mime'), mime);
  return { buf, ext };
}

// An image pasted in the browser. Always update the clipboard slot; then
// either nudge a foreground Claude Code with Ctrl+V (it will spawn our xclip
// shim and find the image "in the clipboard"), or type the file path for a
// plain shell.
function handlePasteImage(session, ws, msg) {
  const slot = writeClipboardSlot(msg);
  if (!slot) return;
  const { buf, ext } = slot;

  if (isClaudeForeground(session)) {
    session.input('\x16'); // Ctrl+V
    ws.send(JSON.stringify({ type: 'paste-result', mode: 'claude' }));
  } else {
    const file = path.join(PASTE_DIR, `paste-${Date.now()}-${pasteSeq++}.${ext}`);
    fs.writeFileSync(file, buf);
    session.input(`'${file}' `);
    ws.send(JSON.stringify({ type: 'paste-result', mode: 'path', path: file }));
  }
}

app.post('/api/paste', (req, res) => {
  const { mime, data } = req.body || {};
  const ext = PASTE_EXT[mime];
  if (!ext || typeof data !== 'string') {
    return res.status(400).json({ error: 'expected { mime: image/*, data: base64 }' });
  }
  const file = path.join(PASTE_DIR, `paste-${Date.now()}-${pasteSeq++}.${ext}`);
  try {
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
  } catch (err) {
    return res.status(500).json({ error: String(err) });
  }
  res.json({ path: file });
});

// ---------------------------------------------------------------------------
// Browser-open spool (xdg-open & friends). No browser exists on this headless
// host, so the shims in shims/ drop "open-*" files into PASTE_DIR (line 1:
// session id, line 2: URL) instead of opening anything. We watch the dir,
// claim each file by rename (several webmux servers may share the spool), and
// forward the URL to the browser client as an 'open-url' message — the client
// shows the same open/copy chooser as a clicked terminal URL.
// ---------------------------------------------------------------------------

const wsClients = new Set(); // every attached browser socket
const wsBySession = new Map(); // session id -> Set<ws>, for targeted delivery
let openSeq = 0;

function processOpenSpool() {
  let names;
  try { names = fs.readdirSync(PASTE_DIR); } catch { return; }
  for (const n of names) {
    if (!n.startsWith('open-')) continue;
    const claimed = path.join(PASTE_DIR, `.claimed-${n}`);
    try { fs.renameSync(path.join(PASTE_DIR, n), claimed); } catch { continue; } // lost the claim race
    let sid, url;
    try {
      [sid, url] = fs.readFileSync(claimed, 'utf8').split('\n');
      fs.rmSync(claimed, { force: true });
    } catch { continue; }
    if (!/^https?:\/\//.test(url)) continue;
    // Deliver to the session the opener ran in when known (WEBMUX_SESSION,
    // exported by the pty host); otherwise broadcast — every tab's socket
    // gets the frame, so the client dedupes by id.
    const targets = wsBySession.get(sid)?.size ? wsBySession.get(sid) : wsClients;
    const frame = JSON.stringify({ type: 'open-url', url, id: `open-${Date.now()}-${openSeq++}` });
    for (const ws of targets) {
      if (ws.readyState === ws.OPEN) ws.send(frame);
    }
  }
}

// Spool files left over from before this server started are stale requests;
// popping them up now would be surprising. Drop them.
for (const n of fs.readdirSync(PASTE_DIR)) {
  if (n.startsWith('open-') || n.startsWith('.claimed-open-')) {
    fs.rmSync(path.join(PASTE_DIR, n), { force: true });
  }
}
fs.watch(PASTE_DIR, () => processOpenSpool());

// ---------------------------------------------------------------------------
// File browser API (Miller-columns widget). No sandboxing: terminals already
// expose the whole filesystem, so these endpoints match that trust level.
// ---------------------------------------------------------------------------

const HOME = process.env.HOME || os.homedir();
const FS_LIST_MAX = 2000;
const TEXT_PREVIEW_BYTES = 64 * 1024;
const IMAGE_MIME = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
  webp: 'image/webp', bmp: 'image/bmp', svg: 'image/svg+xml', ico: 'image/x-icon',
  avif: 'image/avif',
};

function resolveFsPath(p) {
  if (!p || typeof p !== 'string' || p === '~') return HOME;
  if (p.startsWith('~/')) return path.join(HOME, p.slice(2));
  return path.resolve(p);
}

app.get('/api/fs/list', (req, res) => {
  const dir = resolveFsPath(req.query.path);
  let dirents;
  try { dirents = fs.readdirSync(dir, { withFileTypes: true }); }
  catch (err) { return res.status(400).json({ error: err.code || String(err) }); }
  const entries = dirents.map((d) => {
    const e = { name: d.name, type: d.isDirectory() ? 'dir' : 'file' };
    if (d.isSymbolicLink()) {
      e.symlink = true;
      // classify by target so symlinked dirs are drillable; broken links stay files
      try { if (fs.statSync(path.join(dir, d.name)).isDirectory()) e.type = 'dir'; } catch {}
    }
    return e;
  });
  entries.sort((a, b) => (a.type === b.type
    ? a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
    : a.type === 'dir' ? -1 : 1));
  res.json({
    path: dir,
    entries: entries.slice(0, FS_LIST_MAX),
    truncated: entries.length > FS_LIST_MAX,
  });
});

app.get('/api/fs/preview', (req, res) => {
  const file = resolveFsPath(req.query.path);
  let st;
  try { st = fs.statSync(file); }
  catch (err) { return res.status(400).json({ error: err.code || String(err) }); }
  const base = { size: st.size, mtime: st.mtimeMs };
  if (!st.isFile()) return res.json({ kind: 'other', ...base });
  if (IMAGE_MIME[path.extname(file).slice(1).toLowerCase()]) {
    return res.json({ kind: 'image', ...base });
  }
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(Math.min(st.size, TEXT_PREVIEW_BYTES));
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const head = buf.subarray(0, n);
    if (head.includes(0)) return res.json({ kind: 'binary', ...base });
    res.json({ kind: 'text', content: head.toString('utf8'), truncated: n < st.size, ...base });
  } catch (err) {
    res.status(400).json({ error: err.code || String(err) });
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
});

// Upload from the file browser (drag-drop / paste): raw body written into
// ?dir under ?name, deduped Finder-style ("name (1).ext") on collision. A
// name may contain '/' (folder drops upload each file with its relative
// path); intermediate directories are created, and only the basename is
// deduped — re-dropping a folder merges into the existing one. The client
// always sends application/octet-stream so the global JSON body parser
// stays out of the way.
function uniqueName(dir, name) {
  const base = path.basename(name || 'file');
  const ext = path.extname(base);
  const stem = base.slice(0, base.length - ext.length);
  let candidate = base;
  for (let i = 1; fs.existsSync(path.join(dir, candidate)); i++) {
    candidate = `${stem} (${i})${ext}`;
  }
  return candidate;
}

app.post('/api/fs/upload', express.raw({ type: () => true, limit: '200mb' }), (req, res) => {
  const dir = resolveFsPath(req.query.dir);
  const segments = String(req.query.name || '').split('/').filter((s) => s && s !== '.');
  if (segments.some((s) => s === '..')) {
    return res.status(400).json({ error: 'invalid name' });
  }
  const base = segments.pop() || 'file';
  const target = path.join(dir, ...segments);
  const data = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
  try {
    fs.mkdirSync(target, { recursive: true });
    const name = uniqueName(target, base);
    fs.writeFileSync(path.join(target, name), data);
    res.json({ name: [...segments, name].join('/') });
  } catch (err) {
    res.status(400).json({ error: err.code || String(err) });
  }
});

// Delete / rename from the file browser. Deletes are recursive — the client
// confirms before calling; renames stay within the entry's directory.
app.post('/api/fs/delete', (req, res) => {
  const target = resolveFsPath(req.body?.path);
  if (target === '/' || target === HOME) {
    return res.status(400).json({ error: 'refusing to delete that' });
  }
  try {
    fs.rmSync(target, { recursive: true });
    res.json({ ok: true });
  } catch (err) {
    res.status(400).json({ error: err.code || String(err) });
  }
});

app.post('/api/fs/rename', (req, res) => {
  const from = resolveFsPath(req.body?.path);
  const name = String(req.body?.name || '');
  if (!name || name === '.' || name === '..' || name.includes('/')) {
    return res.status(400).json({ error: 'invalid name' });
  }
  const to = path.join(path.dirname(from), name);
  if (to !== from && fs.existsSync(to)) {
    return res.status(400).json({ error: 'name already taken' });
  }
  try {
    fs.renameSync(from, to);
    res.json({ ok: true, name });
  } catch (err) {
    res.status(400).json({ error: err.code || String(err) });
  }
});

// Raw file bytes (image previews load this as <img src>).
app.get('/api/fs/raw', (req, res) => {
  const file = resolveFsPath(req.query.path);
  const mime = IMAGE_MIME[path.extname(file).slice(1).toLowerCase()];
  res.setHeader('Content-Type', mime || 'application/octet-stream');
  fs.createReadStream(file)
    .on('error', () => {
      if (!res.headersSent) res.status(400);
      res.end();
    })
    .pipe(res);
});

app.delete('/api/sessions/:id', async (req, res) => {
  try {
    const r = await hostControl({ cmd: 'kill', session: req.params.id });
    if (!r.ok) return res.status(404).json({ error: r.error || 'not found' });
    res.json({ ok: true });
  } catch (err) {
    res.status(502).json({ error: String(err.message || err) });
  }
});

// ---------------------------------------------------------------------------
// WebSocket attach: /ws?session=<id>
// ---------------------------------------------------------------------------

// One long-lived watch connection to the pty host, fanning session-level
// events (currently title changes) out to every browser socket. This is what
// keeps background tabs' titles live: their tiles have no websocket of their
// own, so title events ride along on whichever sockets are open and the
// client routes them by session id. Reconnects with a delay if the host goes
// away (nudging it back up first, in case nothing else has).
function watchHostEvents() {
  const sock = net.connect(socketPath(HOST_NAME));
  sock.on('connect', () => sock.write(JSON.stringify({ cmd: 'watch' }) + '\n'));
  readLines(sock, (line) => {
    for (const ws of wsClients) {
      if (ws.readyState === ws.OPEN) ws.send(line);
    }
  });
  sock.on('error', () => {}); // 'close' handles the retry
  sock.on('close', () => {
    setTimeout(() => ensureHost(HOST_NAME).catch(() => {}).then(watchHostEvents), 1000);
  });
}

async function main() {
  // Spawn (or adopt) the pty host before accepting clients. It runs
  // detached, so it — and every shell in it — outlives this server.
  const pong = await ensureHost(HOST_NAME);
  console.log(`pty host '${HOST_NAME}' up (pid ${pong.pid}, ${pong.sessions} session(s))`);
  watchHostEvents();

  const server = http.createServer(app);
  const wss = new WebSocketServer({ server, path: '/ws' });
  // ws re-emits the http server's errors here; the server's own 'error'
  // handler below is the one that deals with them (EADDRINUSE recovery).
  wss.on('error', () => {});

  wss.on('connection', (ws, req) => {
    const url = new URL(req.url, 'http://localhost');
    const id = url.searchParams.get('session');

    // Register for open-url delivery (see the browser-open spool above).
    wsClients.add(ws);
    if (id) {
      let set = wsBySession.get(id);
      if (!set) wsBySession.set(id, set = new Set());
      set.add(ws);
    }

    // One pty-host connection per attached browser client. The host's frames
    // mirror the WS protocol, so host→browser lines are forwarded verbatim
    // (snapshot/output/title/exit/error). Writes issued before the unix
    // socket finishes connecting are queued by net internally.
    const sock = net.connect(socketPath(HOST_NAME));
    const send = (obj) => { if (!sock.destroyed) sock.write(JSON.stringify(obj) + '\n'); };
    const session = { pid: 0, input: (data) => send({ type: 'input', data }) };

    send({ cmd: 'attach', session: id });
    readLines(sock, (line) => {
      if (!session.pid) {
        // First frame is the snapshot; remember the shell pid for
        // foreground-process detection (paste routing).
        try { session.pid = JSON.parse(line).pid || 0; } catch { /* not JSON — drop */ }
      }
      if (ws.readyState === ws.OPEN) ws.send(line);
    });
    sock.on('error', () => {}); // host gone → 'close' handles it
    sock.on('close', () => ws.close());

    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch { return; }
      if (msg.type === 'input') send({ type: 'input', data: msg.data });
      else if (msg.type === 'resize') send({ type: 'resize', cols: msg.cols, rows: msg.rows });
      else if (msg.type === 'paste-image') handlePasteImage(session, ws, msg);
      else if (msg.type === 'clipboard-sync') writeClipboardSlot(msg); // slot only, no injection
    });

    ws.on('close', () => {
      sock.destroy();
      wsClients.delete(ws);
      const set = wsBySession.get(id);
      if (set) {
        set.delete(ws);
        if (!set.size) wsBySession.delete(id);
      }
    });
  });

  // Same stale-socket dance as the pty host: if the socket file exists,
  // defer to a live server, or clear the leftover of a dead one and retry.
  server.on('error', (err) => {
    if (err.code !== 'EADDRINUSE') throw err;
    const probe = net.connect(HTTP_SOCK);
    probe.on('connect', () => {
      probe.destroy();
      console.error(`another webmux server is already listening on ${HTTP_SOCK}`);
      process.exit(1);
    });
    probe.on('error', () => {
      fs.rmSync(HTTP_SOCK, { force: true });
      server.listen(HTTP_SOCK);
    });
  });

  server.listen(HTTP_SOCK, () => {
    fs.chmodSync(HTTP_SOCK, 0o600); // dir is 0700 already; belt and braces
    // Advertise the socket path at a fixed home-relative location so the
    // Electron client can auto-discover it (`ssh host cat
    // .webmux/<name>.http.sock.path` — sshd runs remote commands with the
    // home dir as cwd) instead of knowing the uid behind $XDG_RUNTIME_DIR.
    const advertDir = path.join(HOME, '.webmux');
    fs.mkdirSync(advertDir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(advertDir, `${HOST_NAME}.http.sock.path`), HTTP_SOCK + '\n', { mode: 0o600 });
    // Richer JSON advert for the auto-deploy flow (deploy/remote-start.js and
    // the Electron client's push logic): which payload is running, as which
    // pid, speaking which pty-host protocol. The legacy .path file stays for
    // plain discovery-only profiles.
    fs.writeFileSync(path.join(advertDir, `${HOST_NAME}.json`), JSON.stringify({
      socket: HTTP_SOCK,
      payloadHash: PAYLOAD_HASH,
      protocol: PROTOCOL,
      pid: process.pid,
      startedAt: Date.now(),
    }) + '\n', { mode: 0o600 });
    console.log(`webmux listening on ${HTTP_SOCK} (pty host '${HOST_NAME}')`);
  });

  const cleanup = () => {
    try { fs.rmSync(HTTP_SOCK, { force: true }); } catch { /* best effort */ }
    process.exit(0);
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
