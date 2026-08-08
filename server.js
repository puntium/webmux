// webmux — tiled xterm.js sessions with persistent server-side state.
//
// Each session owns a PTY (node-pty) and a headless xterm instance
// (@xterm/headless). All PTY output is written into the headless terminal,
// so the full screen state (buffer, cursor, colors, modes) survives client
// disconnects. When a client (re)attaches, the buffer is replayed via
// @xterm/addon-serialize.

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const { Terminal } = require('@xterm/headless');
const { SerializeAddon } = require('@xterm/addon-serialize');

const PORT = process.env.PORT || 5000;
const SHELL = process.env.SHELL_CMD || process.env.SHELL || 'bash';
const SCROLLBACK = 5000;

// ---------------------------------------------------------------------------
// Session management
// ---------------------------------------------------------------------------

/** @type {Map<string, Session>} */
const sessions = new Map();
let nextId = 1;

class Session {
  constructor(id, cols = 80, rows = 24) {
    this.id = id;
    this.cols = cols;
    this.rows = rows;
    this.clients = new Set(); // attached WebSockets
    this.createdAt = Date.now();

    this.term = new Terminal({ cols, rows, scrollback: SCROLLBACK, allowProposedApi: true });
    this.serialize = new SerializeAddon();
    this.term.loadAddon(this.serialize);

    this.pty = pty.spawn(SHELL, [], {
      name: 'xterm-256color',
      cols,
      rows,
      cwd: process.env.HOME,
      env: {
        ...process.env,
        // Shimmed xclip/xsel serve the browser clipboard to CLIs like Claude
        // Code. DISPLAY is faked so clipboard readers don't bail early on a
        // headless host (real X clients would fail anyway).
        PATH: `${SHIM_DIR}:${process.env.PATH}`,
        WEBMUX_CLIPBOARD_DIR: PASTE_DIR,
        DISPLAY: process.env.DISPLAY || ':0',
      },
    });

    this.pty.onData((data) => {
      this.term.write(data); // keep headless state current
      for (const ws of this.clients) {
        if (ws.readyState === ws.OPEN) {
          ws.send(JSON.stringify({ type: 'output', data }));
        }
      }
    });

    this.pty.onExit(({ exitCode }) => {
      for (const ws of this.clients) {
        if (ws.readyState === ws.OPEN) {
          ws.send(JSON.stringify({ type: 'exit', exitCode }));
          ws.close();
        }
      }
      this.dispose();
      sessions.delete(this.id);
    });
  }

  attach(ws) {
    this.clients.add(ws);
    // Replay accumulated state so the client renders exactly what the
    // session looks like right now.
    ws.send(JSON.stringify({
      type: 'snapshot',
      data: this.serialize.serialize({ scrollback: SCROLLBACK }),
      cols: this.cols,
      rows: this.rows,
    }));
  }

  detach(ws) {
    this.clients.delete(ws);
  }

  input(data) {
    this.pty.write(data);
  }

  resize(cols, rows) {
    if (!Number.isInteger(cols) || !Number.isInteger(rows)) return;
    cols = Math.max(2, Math.min(500, cols));
    rows = Math.max(2, Math.min(300, rows));
    this.cols = cols;
    this.rows = rows;
    this.term.resize(cols, rows);
    this.pty.resize(cols, rows);
  }

  dispose() {
    try { this.pty.kill(); } catch {}
    this.term.dispose();
  }
}

function createSession(cols, rows) {
  const id = String(nextId++);
  const session = new Session(id, cols, rows);
  sessions.set(id, session);
  return session;
}

// ---------------------------------------------------------------------------
// HTTP API
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: '30mb' })); // pasted images arrive as base64 JSON
app.use(express.static(path.join(__dirname, 'public')));
app.use('/vendor/xterm', express.static(path.join(__dirname, 'node_modules/@xterm/xterm')));
app.use('/vendor/addon-fit', express.static(path.join(__dirname, 'node_modules/@xterm/addon-fit')));

app.get('/api/sessions', (_req, res) => {
  res.json([...sessions.values()].map((s) => ({
    id: s.id,
    cols: s.cols,
    rows: s.rows,
    createdAt: s.createdAt,
    clients: s.clients.size,
  })));
});

app.post('/api/sessions', (req, res) => {
  const { cols, rows } = req.body || {};
  const session = createSession(cols || 80, rows || 24);
  res.status(201).json({ id: session.id });
});

// Pasted images land in PASTE_DIR. The latest one is also written to the
// "clipboard" slot that the xclip/xsel shims serve, so clipboard-reading CLIs
// (Claude Code) see it natively.
const SHIM_DIR = path.join(__dirname, 'shims');
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
// (tpgid of the shell's controlling tty, via /proc).
function foregroundCmdline(session) {
  try {
    const stat = fs.readFileSync(`/proc/${session.pty.pid}/stat`, 'utf8');
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

app.delete('/api/sessions/:id', (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) return res.status(404).json({ error: 'not found' });
  session.dispose(); // pty.kill triggers onExit → cleanup
  sessions.delete(session.id);
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// WebSocket attach: /ws?session=<id>
// ---------------------------------------------------------------------------

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const session = sessions.get(url.searchParams.get('session'));
  if (!session) {
    ws.send(JSON.stringify({ type: 'error', message: 'no such session' }));
    ws.close();
    return;
  }

  session.attach(ws);

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'input') session.input(msg.data);
    else if (msg.type === 'resize') session.resize(msg.cols, msg.rows);
    else if (msg.type === 'paste-image') handlePasteImage(session, ws, msg);
    else if (msg.type === 'clipboard-sync') writeClipboardSlot(msg); // slot only, no injection
  });

  ws.on('close', () => session.detach(ws));
});

server.listen(PORT, () => {
  console.log(`webmux listening on http://localhost:${PORT}`);
});
