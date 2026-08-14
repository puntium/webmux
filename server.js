// webmux — tiled xterm.js sessions with persistent server-side state.
//
// This process is a thin, restartable proxy: HTTP/static/auth/TLS plus
// WebSocket termination. The ptys themselves live in a separate long-lived
// pty host daemon (ptyhost.js) reached over a named unix socket, so
// restarting this server never kills a shell. The host is spawned on demand
// at startup (detached) and stops only on `node ptyhost.js shutdown` or an
// explicit kill.

const http = require('http');
const https = require('https');
const net = require('net');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');
const yaml = require('js-yaml');
const { WebSocketServer } = require('ws');
const { DEFAULT_NAME, socketPath, readLines, control, ensureHost } = require('./ptyhost-client');

const PORT = process.env.PORT || 5000;

// ---------------------------------------------------------------------------
// Config (config.yaml, gitignored — see config.example.yaml)
// ---------------------------------------------------------------------------

const CONFIG_FILE = path.join(__dirname, 'config.yaml');
let config = {};
try {
  config = yaml.load(fs.readFileSync(CONFIG_FILE, 'utf8')) || {};
} catch (err) {
  if (err.code !== 'ENOENT') {
    console.error(`failed to load ${CONFIG_FILE}: ${err.message}`);
    process.exit(1);
  }
}

let AUTH = null;
if (config.auth) {
  const { username, password } = config.auth;
  if (!username || !password) {
    console.error(`${CONFIG_FILE}: auth requires both username and password`);
    process.exit(1);
  }
  AUTH = { username: String(username), password: String(password) };
}

// Which pty host this server fronts. Different names → independent hosts
// (own socket, own sessions), so several webmux instances can coexist.
const HOST_NAME = process.env.WEBMUX_PTYHOST || config.ptyhost || DEFAULT_NAME;

// TLS is on by default so browsers treat webmux as a secure context (async
// clipboard API, OSC 52 writes). A self-signed cert is generated once and
// persisted to .tls/ (gitignored), so the exception accepted in the browser
// survives restarts. Config: `tls: false` for plain http, or
// `tls: {cert, key}` to serve real certificates.
const TLS_DIR = path.join(__dirname, '.tls');

async function tlsOptions() {
  if (config.tls === false) return null;
  if (config.tls && typeof config.tls === 'object') {
    const { cert, key } = config.tls;
    if (!cert || !key) {
      console.error(`${CONFIG_FILE}: tls requires both cert and key paths`);
      process.exit(1);
    }
    return { cert: fs.readFileSync(cert), key: fs.readFileSync(key) };
  }
  const certFile = path.join(TLS_DIR, 'cert.pem');
  const keyFile = path.join(TLS_DIR, 'key.pem');
  if (!fs.existsSync(certFile) || !fs.existsSync(keyFile)) {
    const selfsigned = require('selfsigned');
    const pems = await selfsigned.generate(
      [{ name: 'commonName', value: os.hostname() }],
      {
        days: 3650,
        keySize: 2048,
        extensions: [{
          name: 'subjectAltName',
          altNames: [
            { type: 2, value: 'localhost' },
            { type: 2, value: os.hostname() },
            { type: 7, ip: '127.0.0.1' },
          ],
        }],
      },
    );
    fs.mkdirSync(TLS_DIR, { recursive: true });
    fs.writeFileSync(keyFile, pems.private, { mode: 0o600 });
    fs.writeFileSync(certFile, pems.cert);
    console.log(`generated self-signed certificate in ${TLS_DIR}`);
  }
  return { cert: fs.readFileSync(certFile), key: fs.readFileSync(keyFile) };
}

// Hash before comparing so timingSafeEqual gets equal-length inputs and the
// comparison leaks nothing about length or content.
function secretsEqual(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function isAuthorized(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const sep = decoded.indexOf(':');
  if (sep < 0) return false;
  // Bitwise & so both comparisons always run (no early-out on bad username).
  return Boolean(
    secretsEqual(decoded.slice(0, sep), AUTH.username) &
    secretsEqual(decoded.slice(sep + 1), AUTH.password)
  );
}

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
if (AUTH) {
  app.use((req, res, next) => {
    if (isAuthorized(req)) return next();
    res.set('WWW-Authenticate', 'Basic realm="webmux", charset="UTF-8"');
    res.status(401).send('Authentication required');
  });
}
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

async function main() {
  // Spawn (or adopt) the pty host before accepting clients. It runs
  // detached, so it — and every shell in it — outlives this server.
  const pong = await ensureHost(HOST_NAME);
  console.log(`pty host '${HOST_NAME}' up (pid ${pong.pid}, ${pong.sessions} session(s))`);

  const TLS = await tlsOptions();
  const server = TLS ? https.createServer(TLS, app) : http.createServer(app);
  const wss = new WebSocketServer({
    server,
    path: '/ws',
    // Browsers reuse cached Basic credentials on same-origin upgrade requests,
    // so an authenticated page connects transparently.
    verifyClient: AUTH ? ({ req }) => isAuthorized(req) : undefined,
  });

  wss.on('connection', (ws, req) => {
    const url = new URL(req.url, 'http://localhost');
    const id = url.searchParams.get('session');

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

    ws.on('close', () => sock.destroy());
  });

  // `bind: 127.0.0.1` restricts the server to loopback — the tunnel-only
  // deployment (Electron client over SSH), where auth and TLS are off and
  // sshd is the front door. Default: all interfaces, as before.
  const BIND = config.bind || undefined;
  server.listen(PORT, BIND, () => {
    console.log(`webmux listening on http${TLS ? 's' : ''}://${BIND || 'localhost'}:${PORT} (pty host '${HOST_NAME}')`);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
