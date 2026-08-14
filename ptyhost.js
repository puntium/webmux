// webmux pty host — the small long-lived daemon that owns the ptys.
//
// The web server (server.js) is a thin restartable proxy; this process holds
// every session's pty (node-pty) plus its headless xterm mirror
// (@xterm/headless + serialize addon), so shells and full screen state
// survive web server restarts. Its dependency footprint is deliberately tiny
// so it almost never needs a restart itself.
//
// It listens on a named unix socket ($XDG_RUNTIME_DIR/webmux/<name>.sock)
// and speaks newline-delimited JSON mirroring the WebSocket message types
// ~1:1. Multiple hosts can run side by side under different names.
//
// Lifecycle: started on demand by server.js (detached, so killing the web
// server leaves it running) or standalone via `node ptyhost.js [--name X]`.
// It exits only on an explicit `node ptyhost.js shutdown [--name X]`,
// SIGTERM/SIGINT, or kill — never because a web server went away.
//
// Protocol (the first line of each connection picks the mode):
//   {cmd:'ping'}               → {ok, name, pid, sessions}
//   {cmd:'list'}               → {ok, sessions: [{id, cols, rows, title, createdAt, clients, pid}]}
//   {cmd:'create', cols, rows} → {ok, id}
//   {cmd:'kill', session}      → {ok} after killing that session's pty
//   {cmd:'shutdown'}           → {ok}, then all ptys are killed and the daemon exits
//   {cmd:'attach', session}    → switches to streaming: snapshot/output/title/exit
//                                out, input/resize in; closing the connection detaches

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const pty = require('node-pty');
const { Terminal } = require('@xterm/headless');
const { SerializeAddon } = require('@xterm/addon-serialize');
const { DEFAULT_NAME, socketPath, control } = require('./ptyhost-client');

const SHELL = process.env.SHELL_CMD || process.env.SHELL || 'bash';
const SCROLLBACK = 5000;
const SHIM_DIR = path.join(__dirname, 'shims');
const PASTE_DIR = path.join(os.tmpdir(), 'webmux-pastes');

let name = DEFAULT_NAME;
const positional = [];
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--name') name = argv[++i];
  else if (argv[i].startsWith('--name=')) name = argv[i].slice('--name='.length);
  else positional.push(argv[i]);
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/** @type {Map<string, Session>} */
const sessions = new Map();

function send(sock, obj) {
  if (!sock.destroyed) sock.write(JSON.stringify(obj) + '\n');
}

class Session {
  constructor(cols = 80, rows = 24) {
    this.id = crypto.randomUUID(); // stable across web server restarts, never collides
    this.cols = cols;
    this.rows = rows;
    this.clients = new Set(); // attached unix sockets
    this.createdAt = Date.now();
    this.disposed = false;

    this.term = new Terminal({ cols, rows, scrollback: SCROLLBACK, allowProposedApi: true });
    this.serialize = new SerializeAddon();
    this.term.loadAddon(this.serialize);

    // Track OSC 0/2 titles on the headless terminal so they survive
    // disconnects (serialize doesn't capture the title); broadcast changes.
    this.title = '';
    this.term.onTitleChange((title) => {
      this.title = title;
      for (const sock of this.clients) send(sock, { type: 'title', title });
    });

    const env = {
      ...process.env,
      // Shimmed xclip/xsel serve the browser clipboard to CLIs like Claude
      // Code. DISPLAY is faked so clipboard readers don't bail early on a
      // headless host (real X clients would fail anyway).
      PATH: `${SHIM_DIR}:${process.env.PATH}`,
      WEBMUX_CLIPBOARD_DIR: PASTE_DIR,
      DISPLAY: process.env.DISPLAY || ':0',
    };
    // The host may itself run under tmux; hide that from sessions so a
    // nested `tmux` starts cleanly and CLIs don't adapt to a mux they can't
    // actually see.
    delete env.TMUX;
    delete env.TMUX_PANE;
    if (env.TERM_PROGRAM === 'tmux') {
      delete env.TERM_PROGRAM;
      delete env.TERM_PROGRAM_VERSION;
    }

    this.pty = pty.spawn(SHELL, [], {
      name: 'xterm-256color',
      cols,
      rows,
      cwd: process.env.HOME,
      env,
    });

    this.pty.onData((data) => {
      this.term.write(data); // keep headless state current
      for (const sock of this.clients) send(sock, { type: 'output', data });
    });

    this.pty.onExit(({ exitCode }) => {
      for (const sock of this.clients) {
        send(sock, { type: 'exit', exitCode });
        sock.end();
      }
      this.dispose();
      sessions.delete(this.id);
    });
  }

  attach(sock) {
    this.clients.add(sock);
    // Replay accumulated state so the client renders exactly what the
    // session looks like right now. pid rides along for the web server's
    // foreground-process detection (paste routing).
    send(sock, {
      type: 'snapshot',
      data: this.serialize.serialize({ scrollback: SCROLLBACK }),
      cols: this.cols,
      rows: this.rows,
      title: this.title,
      pid: this.pty.pid,
    });
  }

  detach(sock) {
    this.clients.delete(sock);
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

  describe() {
    return {
      id: this.id,
      cols: this.cols,
      rows: this.rows,
      title: this.title,
      createdAt: this.createdAt,
      clients: this.clients.size,
      pid: this.pty.pid,
    };
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    try { this.pty.kill(); } catch { /* already gone */ }
    this.term.dispose();
  }
}

// ---------------------------------------------------------------------------
// Daemon
// ---------------------------------------------------------------------------

function shutdown(code = 0) {
  for (const s of sessions.values()) s.dispose();
  try { fs.rmSync(socketPath(name), { force: true }); } catch { /* best effort */ }
  process.exit(code);
}

function handleCommand(sock, msg, onAttach) {
  switch (msg.cmd) {
    case 'ping':
      send(sock, { ok: true, name, pid: process.pid, sessions: sessions.size });
      sock.end();
      break;
    case 'list':
      send(sock, { ok: true, sessions: [...sessions.values()].map((s) => s.describe()) });
      sock.end();
      break;
    case 'create': {
      const s = new Session(msg.cols || 80, msg.rows || 24);
      sessions.set(s.id, s);
      console.log(`session ${s.id} created (${s.cols}x${s.rows})`);
      send(sock, { ok: true, id: s.id });
      sock.end();
      break;
    }
    case 'kill': {
      const s = sessions.get(msg.session);
      if (!s) { send(sock, { ok: false, error: 'not found' }); sock.end(); break; }
      s.dispose(); // pty.kill triggers onExit → exit broadcast + map cleanup
      sessions.delete(s.id);
      send(sock, { ok: true });
      sock.end();
      break;
    }
    case 'shutdown':
      console.log(`shutdown requested; killing ${sessions.size} session(s)`);
      send(sock, { ok: true });
      sock.end();
      shutdown();
      break;
    case 'attach': {
      const s = sessions.get(msg.session);
      if (!s) { send(sock, { type: 'error', message: 'no such session' }); sock.end(); break; }
      s.attach(sock);
      onAttach(s);
      break;
    }
    default:
      send(sock, { ok: false, error: `unknown cmd ${JSON.stringify(msg.cmd)}` });
      sock.end();
  }
}

function daemon() {
  const { readLines } = require('./ptyhost-client');
  const sockPath = socketPath(name);
  fs.mkdirSync(PASTE_DIR, { recursive: true });

  const server = net.createServer((sock) => {
    sock.on('error', () => {}); // peer vanished mid-write — detach handles it
    let attached = null;
    let first = true;
    readLines(sock, (line) => {
      let msg;
      try { msg = JSON.parse(line); } catch { return; }
      if (first) {
        first = false;
        handleCommand(sock, msg, (s) => { attached = s; });
      } else if (attached) {
        if (msg.type === 'input') attached.input(msg.data);
        else if (msg.type === 'resize') attached.resize(msg.cols, msg.rows);
      }
    });
    sock.on('close', () => { if (attached) attached.detach(sock); });
  });

  server.on('error', async (err) => {
    if (err.code !== 'EADDRINUSE') throw err;
    // Socket file exists: defer to a live daemon, or clear a stale file left
    // by a dead one and retry.
    try {
      await control(name, { cmd: 'ping' });
      console.error(`pty host '${name}' is already running at ${sockPath}`);
      process.exit(1);
    } catch {
      fs.rmSync(sockPath, { force: true });
      server.listen(sockPath);
    }
  });

  server.listen(sockPath, () => {
    console.log(`webmux pty host '${name}' (pid ${process.pid}) listening on ${sockPath}`);
  });

  process.on('SIGTERM', () => shutdown());
  process.on('SIGINT', () => shutdown());
  // Survive terminal hangup when started from a shell by hand; explicit
  // shutdown/kill is the only intended way to stop a host.
  process.on('SIGHUP', () => {});
}

// ---------------------------------------------------------------------------
// CLI: `node ptyhost.js [--name X] [shutdown|list|ping]`
// ---------------------------------------------------------------------------

async function cli(cmd) {
  try {
    const res = await control(name, { cmd });
    if (cmd === 'list') {
      for (const s of res.sessions) {
        console.log(`${s.id}  ${s.cols}x${s.rows}  clients=${s.clients}  pid=${s.pid}  ${s.title}`);
      }
      if (!res.sessions.length) console.log(`(no sessions on pty host '${name}')`);
    } else if (cmd === 'shutdown') {
      console.log(`pty host '${name}' shut down`);
    } else {
      console.log(JSON.stringify(res));
    }
  } catch {
    console.error(`no pty host '${name}' running (socket: ${socketPath(name)})`);
    process.exit(1);
  }
}

const command = positional[0];
if (!command) daemon();
else if (['shutdown', 'list', 'ping'].includes(command)) cli(command);
else {
  console.error(`usage: node ptyhost.js [--name X] [shutdown|list|ping]`);
  process.exit(2);
}
