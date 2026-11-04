#!/usr/bin/env node
// webmux end-to-end harness: drives a webmux server over its unix socket
// (HTTP API + WebSocket attach) and checks the behavior the Electron client
// relies on. It is implementation-agnostic: the reference is the node
// server.js (+ ptyhost.js), the target is `webmux-host serve`; both must pass.
//
//   node host/test/e2e.js                                   # Go binary (default)
//   E2E_SERVER_CMD="node server.js" node host/test/e2e.js   # node reference
//
// Env:
//   E2E_SERVER_CMD            server command line (split on spaces; default
//                             host/dist/webmux-host-linux-x64 serve)
//   E2E_PTYHOST_SHUTDOWN_CMD  pty-host shutdown command; "{name}" is replaced
//                             by the instance name (default derived from the
//                             server command: `node <dir>/ptyhost.js --name X
//                             shutdown` or `<binary> ptyhost --name X shutdown`)
//   E2E_SHELL                 SHELL_CMD for sessions (default sh: predictable
//                             prompt, no rc files)
//   E2E_KEEP=1                keep the scratch dir
//   E2E_VERBOSE=1             dump frames as they arrive
//
// Isolation: everything lives in a scratch dir: XDG_RUNTIME_DIR (pty host
// socket), TMPDIR (paste/spool dir), HOME (shell cwd, `~` for fs routes),
// WEBMUX_SOCKET (HTTP socket; also suppresses the ~/.webmux advert), and a
// unique WEBMUX_PTYHOST name, so no real pty host or paste dir is touched.
//
// Exit code 0 iff every check passed. Uses only node built-ins + `ws` (repo
// root node_modules).

'use strict';
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawn, spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
let WebSocket;
try { WebSocket = require('ws'); } catch { WebSocket = require(path.join(REPO, 'node_modules', 'ws')); }

const VERBOSE = !!process.env.E2E_VERBOSE;
const serverArgv = (process.env.E2E_SERVER_CMD
  || `${path.join(REPO, 'host', 'dist', 'webmux-host-linux-x64')} serve`).trim().split(/\s+/);

// Socket paths are capped at 108 bytes; keep the scratch dir short.
const tmpBase = os.tmpdir().length > 40 ? '/tmp' : os.tmpdir();
const SCRATCH = fs.mkdtempSync(path.join(tmpBase, 'wm-e2e-'));
const NAME = `e2e-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
const dirs = {
  run: path.join(SCRATCH, 'run'),
  tmp: path.join(SCRATCH, 'tmp'),
  home: path.join(SCRATCH, 'home'),
  fs: path.join(SCRATCH, 'fsdir'),
};
for (const d of Object.values(dirs)) fs.mkdirSync(d, { recursive: true, mode: 0o700 });
const SOCK = path.join(SCRATCH, 'http.sock');
const USER = os.userInfo().username;
const EXPECTED_PASTE_DIR = path.join(dirs.tmp, `webmux-pastes-${USER}`);

const ENV = {
  ...process.env,
  XDG_RUNTIME_DIR: dirs.run,
  TMPDIR: dirs.tmp,
  HOME: dirs.home,
  WEBMUX_SOCKET: SOCK,
  WEBMUX_PTYHOST: NAME,
  SHELL_CMD: process.env.E2E_SHELL || 'sh',
  PS1: '$ ',
  ENV: '', // sh: no rc file
};
delete ENV.TMUX;
delete ENV.TMUX_PANE;

function shutdownArgv() {
  if (process.env.E2E_PTYHOST_SHUTDOWN_CMD) {
    return process.env.E2E_PTYHOST_SHUTDOWN_CMD.replace(/\{name\}/g, NAME).trim().split(/\s+/);
  }
  const js = serverArgv.find((a) => /server\.js$/.test(a));
  if (js) return [serverArgv[0], path.join(path.dirname(path.resolve(js)), 'ptyhost.js'), '--name', NAME, 'shutdown'];
  return [serverArgv[0], 'ptyhost', '--name', NAME, 'shutdown'];
}

// ---------------------------------------------------------------------------
// tiny test runner
// ---------------------------------------------------------------------------

const results = [];
async function check(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`ok    ${name} (${Date.now() - t0} ms)`);
  } catch (err) {
    results.push({ name, ok: false, err });
    console.log(`FAIL  ${name}: ${err && err.message ? err.message : err}`);
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }
// HTTP/SSE JSON is only ever JSON.parse'd by the client, so eq() compares
// parsed values structurally (object key order ignored; the Go server emits
// sorted keys, node emits insertion order). Byte-verbatim comparison is kept
// only for pty-host frames forwarded over the WebSocket: eqRaw().
function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) o[k] = canon(v[k]);
    return o;
  }
  return v;
}
function eq(a, b, msg) {
  const ja = JSON.stringify(canon(a));
  const jb = JSON.stringify(canon(b));
  if (ja !== jb) throw new Error(`${msg}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
}
// The frame's raw WebSocket text must equal JSON.stringify(want) exactly:
// the server forwards pty-host lines verbatim and the pty host's JSON shapes
// (key order included) are the protocol.
function eqRaw(frame, want, msg) {
  const raw = frame && frame[RAW];
  const jw = JSON.stringify(want);
  if (raw !== jw) throw new Error(`${msg}: got ${raw}, want ${jw}`);
}
const RAW = Symbol('raw');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// HTTP over the unix socket
// ---------------------------------------------------------------------------

function request(method, p, { body, headers = {}, json } = {}) {
  return new Promise((resolve, reject) => {
    let payload = body;
    if (json !== undefined) {
      payload = Buffer.from(JSON.stringify(json));
      headers = { 'Content-Type': 'application/json', ...headers };
    }
    const req = http.request({ socketPath: SOCK, path: p, method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        let parsed;
        try { parsed = JSON.parse(buf.toString('utf8')); } catch { /* not JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, buf, json: parsed });
      });
    });
    req.on('error', reject);
    req.setTimeout(10000, () => req.destroy(new Error(`${method} ${p}: timeout`)));
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}
const q = (p, params) => `${p}?${new URLSearchParams(params)}`;

function expectCors(r, what) {
  eq(r.headers['access-control-allow-origin'], '*', `${what}: CORS header`);
}

// ---------------------------------------------------------------------------
// WebSocket attach
// ---------------------------------------------------------------------------

class Conn {
  constructor(id, label) {
    this.id = id;
    this.label = label;
    this.frames = [];
    this.out = '';
    this.waiters = [];
    this.closed = false;
    // ws drops a `socketPath` option (8.x resets it); its IPC form is the
    // ws+unix://<socket>:<path> URL.
    this.ws = new WebSocket(`ws+unix://${SOCK}:/ws?session=${encodeURIComponent(id)}`);
    this.ws.on('message', (raw) => {
      let f;
      try { f = JSON.parse(raw.toString('utf8')); } catch { f = { type: '<non-json>', raw: raw.toString() }; }
      Object.defineProperty(f, RAW, { value: raw.toString('utf8') });
      if (VERBOSE) console.log(`  [${label}]`, JSON.stringify(f).slice(0, 200));
      this.frames.push(f);
      if (f.type === 'output' && typeof f.data === 'string') this.out += f.data;
      this.poke();
    });
    this.ws.on('close', () => { this.closed = true; this.poke(); });
    this.ws.on('error', (err) => { this.error = err; this.poke(); });
    this.opened = new Promise((resolve, reject) => {
      this.ws.once('open', resolve);
      this.ws.once('error', reject);
    });
  }
  poke() { for (const w of this.waiters.slice()) w(); }
  // Resolves with the first value pred() returns truthy, re-evaluated on
  // every incoming frame.
  until(pred, ms, what) {
    return new Promise((resolve, reject) => {
      const tryIt = () => {
        let v;
        try { v = pred(); } catch (e) { done(); return reject(e); }
        if (v) { done(); resolve(v); }
      };
      const timer = setTimeout(() => {
        done();
        reject(new Error(`[${this.label}] timed out after ${ms} ms waiting for ${what}; last output: ${JSON.stringify(this.out.slice(-300))}`));
      }, ms);
      const done = () => { clearTimeout(timer); this.waiters = this.waiters.filter((w) => w !== tryIt); };
      this.waiters.push(tryIt);
      tryIt();
    });
  }
  frame(pred, ms = 5000, what = 'frame', from = 0) {
    return this.until(() => this.frames.slice(from).find(pred), ms, what);
  }
  mark() { return { out: this.out.length, frames: this.frames.length }; }
  output(re, from, ms = 5000) {
    return this.until(() => this.out.slice(from ? from.out : 0).match(re), ms, `output ${re}`);
  }
  send(obj) { this.ws.send(JSON.stringify(obj)); }
  type(line) { this.send({ type: 'input', data: `${line}\r` }); }
  close() {
    return new Promise((resolve) => {
      if (this.closed) return resolve();
      this.ws.once('close', resolve);
      this.ws.close();
    });
  }
}

async function attach(id, label) {
  const c = new Conn(id, label);
  await c.opened;
  const snap = await c.frame((f) => f.type === 'snapshot', 5000, 'snapshot');
  return { c, snap };
}

// Visible text of a VT stream: drop CSI/OSC/DCS and two-byte escapes.
function stripVT(s) {
  return s
    .replace(/\x1b\][\s\S]*?(?:\x07|\x1b\\)/g, '')
    .replace(/\x1bP[\s\S]*?\x1b\\/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\x1b[()*+][0-9A-Za-z]/g, '')
    .replace(/\x1b[=>78DEHMNOZc]/g, '');
}

// Shell output of a command, delimited by markers that the echoed command
// line itself cannot match (the quotes split them).
let markSeq = 0;
async function run(c, cmd, ms = 5000) {
  const n = ++markSeq;
  const from = c.mark();
  c.type(`echo "<<""${n}"; ${cmd}; echo "${n}"">>"`);
  const m = await c.output(new RegExp(`<<${n}\\r?\\n([\\s\\S]*?)${n}>>`), from, ms);
  return m[1].replace(/\r/g, '');
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

// 1x1 transparent PNG.
const PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const PNG = Buffer.from(PNG_B64, 'base64');

// Minimal stored-entry zip: one file + one dir, valid central directory.
function makeZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const nameBuf = Buffer.from(name, 'utf8');
    const crc = zlib.crc32 ? zlib.crc32(data) : 0;
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0x800, 6);
    lh.writeUInt32LE(crc, 14); lh.writeUInt32LE(data.length, 18); lh.writeUInt32LE(data.length, 22);
    lh.writeUInt16LE(nameBuf.length, 26);
    locals.push(lh, nameBuf, data);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 4); ch.writeUInt16LE(20, 6); ch.writeUInt16LE(0x800, 8);
    ch.writeUInt32LE(crc, 16); ch.writeUInt32LE(data.length, 20); ch.writeUInt32LE(data.length, 24);
    ch.writeUInt16LE(nameBuf.length, 28); ch.writeUInt32LE(offset, 42);
    centrals.push(ch, nameBuf);
    offset += 30 + nameBuf.length + data.length;
  }
  const cd = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); eocd.writeUInt16LE(entries.length, 8); eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(cd.length, 12); eocd.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, eocd]);
}

function writeFsFixtures() {
  const d = dirs.fs;
  fs.mkdirSync(path.join(d, 'Sub'));
  fs.mkdirSync(path.join(d, 'adir'));
  fs.writeFileSync(path.join(d, 'b.txt'), 'hello text\n');
  fs.writeFileSync(path.join(d, 'A.md'), '# title\n');
  fs.writeFileSync(path.join(d, 'img.png'), PNG);
  fs.writeFileSync(path.join(d, 'blob.dat'), Buffer.from([1, 2, 0, 3]));
  fs.writeFileSync(path.join(d, 'arch.zip'), makeZip([
    { name: 'docs/', data: Buffer.alloc(0) },
    { name: 'docs/hello.txt', data: Buffer.from('hello') },
  ]));
  fs.writeFileSync(path.join(d, 'fake.zip'), 'not a zip at all, just text that is long enough');
  fs.writeFileSync(path.join(d, 'naïve "q".txt'), 'x');
  fs.symlinkSync('adir', path.join(d, 'link-to-dir'));
  fs.symlinkSync('nowhere', path.join(d, 'broken-link'));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

let server;
let serverExit = null;
const serverLog = path.join(SCRATCH, 'server.log');

async function main() {
  console.log(`server:  ${serverArgv.join(' ')}`);
  console.log(`scratch: ${SCRATCH}  instance: ${NAME}`);
  writeFsFixtures();

  const logFd = fs.openSync(serverLog, 'a');
  server = spawn(serverArgv[0], serverArgv.slice(1), {
    env: ENV, cwd: REPO, stdio: ['ignore', logFd, logFd],
  });
  fs.closeSync(logFd);
  server.on('exit', (code, sig) => { serverExit = { code, sig }; });

  await check('server comes up (GET / answers within 20 s)', async () => {
    for (let i = 0; i < 200; i++) {
      if (serverExit) throw new Error(`server exited early: ${JSON.stringify(serverExit)}`);
      try { const r = await request('GET', '/'); if (r.status) return; } catch { /* not yet */ }
      await sleep(100);
    }
    throw new Error('no answer');
  });
  if (results.some((r) => !r.ok)) return;

  await check('health: GET / identity', async () => {
    const r = await request('GET', '/');
    eq(r.status, 200, 'status');
    expectCors(r, 'GET /');
    assert(/^application\/json/.test(r.headers['content-type'] || ''), `content-type ${r.headers['content-type']}`);
    eq(r.json, { ok: true, server: 'webmux', payloadHash: r.json && r.json.payloadHash, ptyhost: NAME }, 'body');
    assert(typeof r.json.payloadHash === 'string' && r.json.payloadHash, 'payloadHash string');
  });

  await check('CORS preflight: OPTIONS → 204', async () => {
    const r = await request('OPTIONS', '/api/sessions');
    eq(r.status, 204, 'status');
    expectCors(r, 'OPTIONS');
    eq(r.headers['access-control-allow-methods'], 'GET, POST, DELETE, OPTIONS', 'allow-methods');
    eq(r.headers['access-control-allow-headers'], 'Content-Type', 'allow-headers');
    eq(r.headers['access-control-max-age'], '600', 'max-age');
  });

  await check('unknown route → 404 {error:"not found"}', async () => {
    const r = await request('GET', '/api/nope');
    eq(r.status, 404, 'status');
    expectCors(r, '404');
    eq(r.json, { error: 'not found' }, 'body');
  });

  await check('advert not written under WEBMUX_SOCKET', async () => {
    assert(!fs.existsSync(path.join(dirs.home, '.webmux', `${NAME}.json`)), 'advert exists');
  });

  let A;
  let B;
  await check('POST /api/sessions → 201 {id}', async () => {
    const r = await request('POST', '/api/sessions', { json: { cols: 80, rows: 24 } });
    eq(r.status, 201, 'status');
    expectCors(r, 'create');
    assert(r.json && typeof r.json.id === 'string', `body ${r.buf}`);
    eq(Object.keys(r.json), ['id'], 'keys');
    A = r.json.id;
    assert(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(A), `uuid v4: ${A}`);
    const r2 = await request('POST', '/api/sessions'); // no body → 80x24 defaults
    eq(r2.status, 201, 'status (no body)');
    B = r2.json.id;
  });
  if (!A) return;

  await check('POST /api/sessions with invalid JSON → 400', async () => {
    const r = await request('POST', '/api/sessions', { body: '{nope', headers: { 'Content-Type': 'application/json' } });
    eq(r.status, 400, 'status');
    eq(r.json, { error: 'invalid JSON body' }, 'body');
  });

  await check('GET /api/sessions lists both with describe() fields', async () => {
    const r = await request('GET', '/api/sessions');
    eq(r.status, 200, 'status');
    assert(Array.isArray(r.json), 'array');
    const a = r.json.find((s) => s.id === A);
    const b = r.json.find((s) => s.id === B);
    assert(a && b, 'both listed');
    eq(Object.keys(a).sort(), ['clients', 'cols', 'createdAt', 'id', 'pid', 'rows', 'title'], 'fields');
    eq([a.cols, a.rows, b.cols, b.rows, a.clients], [80, 24, 80, 24, 0], 'sizes/clients');
    assert(typeof a.createdAt === 'number' && a.pid > 0, 'createdAt/pid');
  });

  let ca;
  let cb;
  await check('WS attach: first frame is snapshot {data, cols, rows, title, pid}', async () => {
    const { c, snap } = await attach(A, 'A');
    ca = c;
    eq(c.frames[0].type, 'snapshot', 'first frame type');
    eq(Object.keys(snap).sort(), ['cols', 'data', 'pid', 'rows', 'title', 'type'], 'snapshot keys');
    assert(typeof snap.data === 'string', 'data string');
    eq([snap.cols, snap.rows, snap.title], [80, 24, ''], 'cols/rows/title');
    assert(Number.isInteger(snap.pid) && snap.pid > 0, `pid ${snap.pid}`);
    const att = await attach(B, 'B');
    cb = att.c;
  });
  if (!ca) return;

  await check('input printf hello → output', async () => {
    const from = ca.mark();
    ca.type("printf 'hello\\n'");
    await ca.output(/[\r\n]hello\r\n/, from); // the shell may emit \e[?2004l\r before output
  });

  await check('session env: shims on PATH, WEBMUX_SESSION, WEBMUX_CLIPBOARD_DIR, TERM, BROWSER', async () => {
    const out = await run(ca, 'echo "S=$WEBMUX_SESSION"; echo "D=$WEBMUX_CLIPBOARD_DIR"; echo "T=$TERM"; echo "X=$(command -v xdg-open)"; echo "B=$BROWSER"; echo "DISP=$DISPLAY"; echo "PWD=$(pwd)"');
    const kv = Object.fromEntries(out.trim().split('\n').map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
    eq(kv.S, A, 'WEBMUX_SESSION');
    eq(kv.D, EXPECTED_PASTE_DIR, 'WEBMUX_CLIPBOARD_DIR');
    eq(kv.T, 'xterm-256color', 'TERM');
    assert(/\/shims\/xdg-open$/.test(kv.X), `xdg-open resolves to ${kv.X}`);
    eq(kv.B, kv.X, 'BROWSER is the xdg-open shim');
    assert(kv.DISP, 'DISPLAY set');
    eq(kv.PWD, dirs.home, 'cwd is $HOME');
  });

  await check('seq 1 200, reconnect: snapshot carries scrollback 1..200', async () => {
    const out = await run(ca, 'seq 1 200');
    eq(out.trim().split('\n').length, 200, 'live output line count');
    await ca.close();
    const { c, snap } = await attach(A, 'A2');
    ca = c;
    const lines = new Set(stripVT(snap.data).split(/\r?\n/).map((l) => l.trim()));
    const missing = [];
    for (let i = 1; i <= 200; i++) if (!lines.has(String(i))) missing.push(i);
    assert(!missing.length, `snapshot lacks ${missing.length} numbers (first: ${missing.slice(0, 10).join(',')}); snapshot ${snap.data.length} chars`);
    eq([snap.cols, snap.rows], [80, 24], 'snapshot size');
  });

  await check('resize 100x30 → stty size, list, snapshot', async () => {
    ca.send({ type: 'resize', cols: 100, rows: 30 });
    await sleep(200);
    const out = await run(ca, 'stty size');
    eq(out.trim(), '30 100', 'stty size');
    const r = await request('GET', '/api/sessions');
    const a = r.json.find((s) => s.id === A);
    eq([a.cols, a.rows, a.clients], [100, 30, 1], 'listed size/clients');
  });

  await check('resize is clamped (cols 2..500, rows 2..300)', async () => {
    ca.send({ type: 'resize', cols: 9999, rows: 1 });
    await sleep(200);
    const out = await run(ca, 'stty size');
    eq(out.trim(), '2 500', 'stty size after clamp');
    ca.send({ type: 'resize', cols: 100, rows: 30 });
    await sleep(200);
    eq((await run(ca, 'stty size')).trim(), '30 100', 'restored');
  });

  await check('OSC 2 title → title frame (A) and session-title (B), list, snapshot', async () => {
    const fa = ca.frames.length;
    const fb = cb.frames.length;
    ca.type("printf '\\033]2;e2e-title\\007'");
    const t = await ca.frame((f) => f.type === 'title', 5000, 'title frame', fa);
    eqRaw(t, { type: 'title', title: 'e2e-title' }, 'title frame');
    const st = await cb.frame((f) => f.type === 'session-title', 5000, 'session-title on B', fb);
    eqRaw(st, { type: 'session-title', session: A, title: 'e2e-title' }, 'session-title frame');
    const r = await request('GET', '/api/sessions');
    eq(r.json.find((s) => s.id === A).title, 'e2e-title', 'listed title');
    const att = await attach(A, 'A-title');
    eq(att.snap.title, 'e2e-title', 'snapshot title');
    await att.c.close();
  });

  await check('open-url spool: xdg-open in session → open-url frame to that session only', async () => {
    const fa = ca.frames.length;
    const fb = cb.frames.length;
    const out = await run(ca, 'xdg-open https://example.com/x; echo "rc=$?"');
    assert(/rc=0/.test(out), `xdg-open rc: ${out}`);
    const f = await ca.frame((x) => x.type === 'open-url', 5000, 'open-url', fa);
    eq(Object.keys(f).sort(), ['id', 'type', 'url'], 'keys');
    eq(f.url, 'https://example.com/x', 'url');
    assert(/^open-\d+-\d+$/.test(f.id), `id ${f.id}`);
    await sleep(300);
    assert(!cb.frames.slice(fb).some((x) => x.type === 'open-url'), 'B (other session) also got the open-url');
    const left = fs.readdirSync(EXPECTED_PASTE_DIR).filter((n) => /open-/.test(n));
    eq(left, [], 'spool files left behind');
  });

  await check('open-url spool: unknown session id → broadcast; non-http URL dropped', async () => {
    const fa = ca.frames.length;
    const fb = cb.frames.length;
    fs.writeFileSync(path.join(EXPECTED_PASTE_DIR, '.tmp-x'), 'no-such-session\nhttp://example.org/b\n');
    fs.renameSync(path.join(EXPECTED_PASTE_DIR, '.tmp-x'), path.join(EXPECTED_PASTE_DIR, 'open-e2e-1'));
    const f1 = await ca.frame((x) => x.type === 'open-url', 5000, 'open-url on A', fa);
    const f2 = await cb.frame((x) => x.type === 'open-url', 5000, 'open-url on B', fb);
    eq([f1.url, f2.url], ['http://example.org/b', 'http://example.org/b'], 'broadcast urls');
    eq(f1.id, f2.id, 'same id on both sockets');
    const out = await run(ca, 'xdg-open file:///etc/passwd; echo "rc=$?"');
    assert(/rc=4/.test(out), `xdg-open file:// should exit 4: ${out}`);
    fs.writeFileSync(path.join(EXPECTED_PASTE_DIR, 'open-e2e-2'), `${A}\nftp://example.org/c\n`);
    await sleep(500);
    assert(!ca.frames.slice(fa).some((x) => x.type === 'open-url' && x.url === 'ftp://example.org/c'), 'ftp url forwarded');
  });

  await check('clipboard-sync → clipboard slot only (no reply, no input)', async () => {
    const fa = ca.frames.length;
    ca.send({ type: 'clipboard-sync', mime: 'image/png', data: PNG_B64 });
    const slot = path.join(EXPECTED_PASTE_DIR, 'clipboard');
    for (let i = 0; i < 50 && !(fs.existsSync(slot) && fs.readFileSync(slot).equals(PNG)); i++) await sleep(50);
    assert(fs.readFileSync(slot).equals(PNG), 'slot bytes');
    eq(fs.readFileSync(path.join(EXPECTED_PASTE_DIR, 'clipboard.mime'), 'utf8'), 'image/png', 'slot mime');
    // the xclip shim serves it
    const out = await run(ca, 'xclip -selection clipboard -t TARGETS -o');
    assert(/image\/png/.test(out), `xclip TARGETS: ${JSON.stringify(out)}`);
    await sleep(200);
    assert(!ca.frames.slice(fa).some((x) => x.type === 'paste-result'), 'clipboard-sync produced a paste-result');
    ca.send({ type: 'clipboard-sync', mime: 'text/plain', data: 'aGk=' }); // ignored
    await sleep(100);
    eq(fs.readFileSync(path.join(EXPECTED_PASTE_DIR, 'clipboard.mime'), 'utf8'), 'image/png', 'unsupported mime ignored');
  });

  await check('paste-image → paste-result {mode:"path"} + path typed into the shell', async () => {
    const fa = ca.frames.length;
    const from = ca.mark();
    ca.send({ type: 'paste-image', mime: 'image/png', data: PNG_B64 });
    const f = await ca.frame((x) => x.type === 'paste-result', 5000, 'paste-result', fa);
    eq(Object.keys(f).sort(), ['mode', 'path', 'type'], 'keys');
    eq(f.mode, 'path', 'mode');
    eq(path.dirname(f.path), EXPECTED_PASTE_DIR, 'paste dir');
    assert(/^paste-\d+-\d+\.png$/.test(path.basename(f.path)), `name ${f.path}`);
    assert(fs.readFileSync(f.path).equals(PNG), 'file bytes');
    await ca.output(new RegExp(`'${f.path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}' `), from);
    ca.send({ type: 'input', data: '\x15' }); // ^U: drop the typed path
  });

  await check('POST /api/paste → {path}; bad mime → 400', async () => {
    const r = await request('POST', '/api/paste', { json: { mime: 'image/png', data: PNG_B64 } });
    eq(r.status, 200, 'status');
    eq(Object.keys(r.json), ['path'], 'keys');
    assert(fs.readFileSync(r.json.path).equals(PNG), 'bytes');
    const bad = await request('POST', '/api/paste', { json: { mime: 'text/plain', data: 'x' } });
    eq(bad.status, 400, 'bad status');
    eq(bad.json, { error: 'expected { mime: image/*, data: base64 }' }, 'bad body');
  });

  await check('fs/list: sort, types, symlinks, ~', async () => {
    const r = await request('GET', q('/api/fs/list', { path: dirs.fs }));
    eq(r.status, 200, 'status');
    expectCors(r, 'fs/list');
    eq(r.json.path, dirs.fs, 'path');
    eq(r.json.truncated, false, 'truncated');
    eq(r.json.entries, [
      { name: 'adir', type: 'dir' },
      { name: 'link-to-dir', type: 'dir', symlink: true },
      { name: 'Sub', type: 'dir' },
      { name: 'A.md', type: 'file' },
      { name: 'arch.zip', type: 'file' },
      { name: 'b.txt', type: 'file' },
      { name: 'blob.dat', type: 'file' },
      { name: 'broken-link', type: 'file', symlink: true },
      { name: 'fake.zip', type: 'file' },
      { name: 'img.png', type: 'file' },
      { name: 'naïve "q".txt', type: 'file' },
    ], 'entries');
    const h = await request('GET', q('/api/fs/list', { path: '~' }));
    eq(h.json.path, dirs.home, '~ resolves to HOME');
    const h2 = await request('GET', '/api/fs/list');
    eq(h2.json.path, dirs.home, 'no path → HOME');
    const miss = await request('GET', q('/api/fs/list', { path: path.join(dirs.fs, 'missing') }));
    eq([miss.status, miss.json], [400, { error: 'ENOENT' }], 'missing dir');
    const notdir = await request('GET', q('/api/fs/list', { path: path.join(dirs.fs, 'b.txt') }));
    eq([notdir.status, notdir.json], [400, { error: 'ENOTDIR' }], 'list a file');
  });

  await check('fs/preview: text, image, binary, zip, fake zip, dir, missing', async () => {
    const pv = async (n) => (await request('GET', q('/api/fs/preview', { path: path.join(dirs.fs, n) })));
    const t = await pv('b.txt');
    eq(t.status, 200, 'text status');
    const st = fs.statSync(path.join(dirs.fs, 'b.txt'));
    eq(t.json, { kind: 'text', content: 'hello text\n', truncated: false, size: 11, mtime: st.mtimeMs }, 'text');
    eq((await pv('img.png')).json.kind, 'image', 'image');
    eq(Object.keys((await pv('img.png')).json).sort(), ['kind', 'mtime', 'size'], 'image keys');
    eq((await pv('blob.dat')).json.kind, 'binary', 'binary');
    const z = (await pv('arch.zip')).json;
    eq([z.kind, z.entries, z.count, z.truncated], ['zip', [
      { name: 'docs/', size: 0, dir: true },
      { name: 'docs/hello.txt', size: 5, dir: false },
    ], 2, false], 'zip');
    eq(Object.keys(z).sort(), ['count', 'entries', 'kind', 'mtime', 'size', 'truncated'], 'zip keys');
    eq((await pv('fake.zip')).json.kind, 'text', 'fake zip falls back to text');
    eq((await pv('adir')).json.kind, 'other', 'dir is other');
    const m = await pv('missing');
    eq([m.status, m.json], [400, { error: 'ENOENT' }], 'missing');
  });

  await check('fs/watch SSE: ready, then change on create', async () => {
    const events = [];
    let resp;
    const req = http.request({ socketPath: SOCK, path: q('/api/fs/watch', { path: dirs.fs }) }, (res) => {
      resp = res;
      res.setEncoding('utf8');
      let buf = '';
      res.on('data', (d) => {
        buf += d;
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, i);
          buf = buf.slice(i + 2);
          const ev = /^event: (.*)$/m.exec(block);
          const data = /^data: (.*)$/m.exec(block);
          if (ev) events.push({ event: ev[1], data: data && JSON.parse(data[1]) });
        }
      });
    });
    req.end();
    try {
      for (let i = 0; i < 50 && !events.length; i++) await sleep(50);
      eq(resp && resp.statusCode, 200, 'status');
      eq(resp.headers['content-type'], 'text/event-stream', 'content-type');
      expectCors(resp, 'fs/watch');
      eq(events[0], { event: 'ready', data: { path: dirs.fs } }, 'ready event');
      fs.writeFileSync(path.join(dirs.fs, 'watched.txt'), 'w');
      for (let i = 0; i < 50 && events.length < 2; i++) await sleep(50);
      eq(events[1], { event: 'change', data: { path: dirs.fs } }, 'change event');
    } finally {
      req.destroy();
      fs.rmSync(path.join(dirs.fs, 'watched.txt'), { force: true });
    }
  });

  await check('fs/upload: plain, dedupe, nested path, .. rejected', async () => {
    const up = (name, body) => request('POST', q('/api/fs/upload', { dir: dirs.fs, name }), { body: Buffer.from(body) });
    let r = await up('up.txt', 'one');
    eq([r.status, r.json], [200, { name: 'up.txt' }], 'first');
    r = await up('up.txt', 'two');
    eq(r.json, { name: 'up (1).txt' }, 'dedupe');
    eq(fs.readFileSync(path.join(dirs.fs, 'up (1).txt'), 'utf8'), 'two', 'dedupe bytes');
    r = await up('nested/x/y.txt', 'three');
    eq(r.json, { name: 'nested/x/y.txt' }, 'nested');
    eq(fs.readFileSync(path.join(dirs.fs, 'nested/x/y.txt'), 'utf8'), 'three', 'nested bytes');
    r = await up('../escape.txt', 'no');
    eq([r.status, r.json], [400, { error: 'invalid name' }], 'dotdot');
    r = await request('POST', q('/api/fs/upload', { dir: dirs.fs }), { body: Buffer.from('anon') });
    eq(r.json, { name: 'file' }, 'no name → file');
  });

  await check('fs/rename and fs/delete', async () => {
    let r = await request('POST', '/api/fs/rename', { json: { path: path.join(dirs.fs, 'up.txt'), name: 'renamed.txt' } });
    eq([r.status, r.json], [200, { ok: true, name: 'renamed.txt' }], 'rename');
    r = await request('POST', '/api/fs/rename', { json: { path: path.join(dirs.fs, 'renamed.txt'), name: 'b.txt' } });
    eq([r.status, r.json], [400, { error: 'name already taken' }], 'rename taken');
    r = await request('POST', '/api/fs/rename', { json: { path: path.join(dirs.fs, 'renamed.txt'), name: 'a/b' } });
    eq([r.status, r.json], [400, { error: 'invalid name' }], 'rename slash');
    r = await request('POST', '/api/fs/delete', { json: { path: path.join(dirs.fs, 'nested') } });
    eq([r.status, r.json], [200, { ok: true }], 'delete dir');
    assert(!fs.existsSync(path.join(dirs.fs, 'nested')), 'deleted');
    r = await request('POST', '/api/fs/delete', { json: { path: '~' } });
    eq([r.status, r.json], [400, { error: 'refusing to delete that' }], 'delete HOME');
    r = await request('POST', '/api/fs/delete', { json: { path: path.join(dirs.fs, 'nope') } });
    eq([r.status, r.json], [400, { error: 'ENOENT' }], 'delete missing');
  });

  await check('fs/raw: bytes + mime, download disposition, non-file', async () => {
    let r = await request('GET', q('/api/fs/raw', { path: path.join(dirs.fs, 'img.png') }));
    eq(r.status, 200, 'status');
    expectCors(r, 'fs/raw');
    eq(r.headers['content-type'], 'image/png', 'mime');
    eq(r.headers['content-length'], String(PNG.length), 'length');
    assert(r.buf.equals(PNG), 'bytes');
    r = await request('GET', q('/api/fs/raw', { path: path.join(dirs.fs, 'blob.dat') }));
    eq(r.headers['content-type'], 'application/octet-stream', 'octet-stream');
    r = await request('GET', q('/api/fs/raw', { path: path.join(dirs.fs, 'naïve "q".txt'), download: '1' }));
    eq(r.headers['content-disposition'],
      `attachment; filename="na_ve _q_.txt"; filename*=UTF-8''${encodeURIComponent('naïve "q".txt')}`, 'disposition');
    r = await request('GET', q('/api/fs/raw', { path: dirs.fs }));
    eq([r.status, r.json], [400, { error: 'not a file' }], 'dir');
    r = await request('GET', q('/api/fs/raw', { path: path.join(dirs.fs, 'missing') }));
    eq([r.status, r.json], [400, { error: 'ENOENT' }], 'missing');
  });

  await check('exit 7 → exit frame {exitCode:7}, socket closed, session gone', async () => {
    const fa = ca.frames.length;
    ca.type('exit 7');
    const f = await ca.frame((x) => x.type === 'exit', 5000, 'exit frame', fa);
    eqRaw(f, { type: 'exit', exitCode: 7 }, 'exit frame');
    await ca.until(() => ca.closed, 5000, 'ws close');
    const r = await request('GET', '/api/sessions');
    assert(!r.json.some((s) => s.id === A), 'A still listed');
  });

  await check('attach to a missing session → error frame, then close', async () => {
    const c = new Conn('no-such-session', 'missing');
    await c.opened;
    const f = await c.frame(() => true, 5000, 'any frame');
    eqRaw(f, { type: 'error', message: 'no such session' }, 'error frame');
    await c.until(() => c.closed, 5000, 'ws close');
  });

  await check('DELETE /api/sessions/:id → 200, exit frame on B; again → 404', async () => {
    const fb = cb.frames.length;
    let r = await request('DELETE', `/api/sessions/${encodeURIComponent(B)}`);
    eq([r.status, r.json], [200, { ok: true }], 'delete');
    expectCors(r, 'DELETE');
    const f = await cb.frame((x) => x.type === 'exit', 5000, 'exit on B', fb);
    assert(typeof f.exitCode === 'number', `exitCode ${f.exitCode}`);
    await cb.until(() => cb.closed, 5000, 'ws close');
    r = await request('DELETE', `/api/sessions/${encodeURIComponent(B)}`);
    eq(r.status, 404, 'second delete');
    assert(r.json && typeof r.json.error === 'string', 'error body');
    r = await request('GET', '/api/sessions');
    eq(r.json, [], 'no sessions left');
  });
}

async function teardown() {
  const sd = shutdownArgv();
  await check(`pty host shutdown (${sd.join(' ')})`, async () => {
    const r = spawnSync(sd[0], sd.slice(1), { env: ENV, encoding: 'utf8', timeout: 10000 });
    eq(r.status, 0, `exit status (stdout ${JSON.stringify(r.stdout)} stderr ${JSON.stringify(r.stderr)})`);
    const hostSock = path.join(dirs.run, 'webmux', `${NAME}.sock`);
    for (let i = 0; i < 30 && fs.existsSync(hostSock); i++) await sleep(100);
    assert(!fs.existsSync(hostSock), 'pty host socket still present');
  });
  await check('server SIGTERM → exits, socket removed', async () => {
    if (!serverExit) server.kill('SIGTERM');
    for (let i = 0; i < 50 && !serverExit; i++) await sleep(100);
    assert(serverExit, 'server still running after 5 s');
    assert(!fs.existsSync(SOCK), 'http socket still present');
  });
  if (!serverExit) server.kill('SIGKILL');
}

(async () => {
  try {
    await main();
  } catch (err) {
    results.push({ name: 'harness', ok: false, err });
    console.log(`FAIL  harness: ${err.stack || err}`);
  }
  await teardown();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    let tail = '';
    try { tail = fs.readFileSync(serverLog, 'utf8').split('\n').slice(-30).join('\n'); } catch { /* none */ }
    console.log(`--- server log tail (${serverLog}) ---\n${tail}`);
    const hostLog = path.join(dirs.run, 'webmux', `${NAME}.log`);
    try { console.log(`--- pty host log tail (${hostLog}) ---\n${fs.readFileSync(hostLog, 'utf8').split('\n').slice(-30).join('\n')}`); } catch { /* none */ }
  }
  if (!process.env.E2E_KEEP && !failed.length) fs.rmSync(SCRATCH, { recursive: true, force: true });
  else console.log(`scratch kept: ${SCRATCH}`);
  process.exit(failed.length ? 1 : 0);
})();
