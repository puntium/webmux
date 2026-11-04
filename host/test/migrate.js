#!/usr/bin/env node
// webmux node → native migration test (docs/native-host.md, "Migration").
//
//   node host/test/migrate.js            # uses host/dist/webmux-host-linux-x64
//   MIG_BIN=/path/to/webmux-host node host/test/migrate.js
//
// Forward direction (instance `mig`), what the first native deploy onto a
// host running the node payload does:
//   a. node ptyhost.js + node server.js (advert ~/.webmux/mig.json, hash dev);
//      create a session, run `seq 1 50` in it;
//   b. stage a payload dir (webmux-host, shims/, PAYLOAD_HASH) and run
//      `<payload>/webmux-host start --name mig` from $HOME: action started,
//      node server gone, node pty host alive with the same pid, advert has
//      the new hash and pid;
//   c. attach through the Go server: the snapshot has the seq output;
//   d. `start` again → action reuse;
//   e. `webmux-host ptyhost --name mig shutdown` against the NODE pty host
//      exits 0 and removes its socket; SIGTERM the Go server.
// Reverse compat (instance `x`):
//   f. `webmux-host ptyhost --name x` fronted by `node server.js`: create,
//      attach, snapshot, `node ptyhost.js --name x shutdown`.
//
// Fully isolated: HOME, XDG_RUNTIME_DIR and TMPDIR live under a short
// /tmp/wm-mig-* dir (unix socket paths are capped at 108 bytes). Every
// process it started is killed on the way out. Runnable repeatedly; exit 0
// iff every check passed. Uses node built-ins + `ws` (repo root node_modules).

'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const WebSocket = require(path.join(REPO, 'node_modules', 'ws'));
const BIN = path.resolve(process.env.MIG_BIN || path.join(REPO, 'host', 'dist', 'webmux-host-linux-x64'));
const NODE = process.execPath;

const SCRATCH = fs.mkdtempSync('/tmp/wm-mig-');
const dirs = {
  home: path.join(SCRATCH, 'home'),
  run: path.join(SCRATCH, 'run'),
  tmp: path.join(SCRATCH, 'tmp'),
};
for (const d of Object.values(dirs)) fs.mkdirSync(d, { recursive: true, mode: 0o700 });
const HASH = `migtest${Date.now().toString(36)}`;
const PAYLOAD = path.join(dirs.home, '.webmux', 'dist', 'payload', HASH);

const ENV = {
  ...process.env,
  HOME: dirs.home,
  XDG_RUNTIME_DIR: dirs.run,
  TMPDIR: dirs.tmp,
  SHELL_CMD: 'sh',
  PS1: '$ ',
  ENV: '',
};
for (const k of ['WEBMUX_SOCKET', 'WEBMUX_PTYHOST', 'TMUX', 'TMUX_PANE']) delete ENV[k];
const hostSock = (name) => path.join(dirs.run, 'webmux', `${name}.sock`);
const advertPath = (name) => path.join(dirs.home, '.webmux', `${name}.json`);
const readAdvert = (name) => { try { return JSON.parse(fs.readFileSync(advertPath(name), 'utf8')); } catch { return null; } };

// ---------------------------------------------------------------------------

const results = [];
async function check(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`ok    ${name} (${Date.now() - t0} ms)`);
    return true;
  } catch (err) {
    results.push({ name, ok: false, err });
    console.log(`FAIL  ${name}: ${err && err.message ? err.message : err}`);
    return false;
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(pred, ms, what) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await pred();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timed out after ${ms} ms waiting for ${what}`);
    await sleep(100);
  }
}

// Alive and not a zombie (our own detached children are reaped by libuv,
// but be safe: a zombie answers kill(pid, 0)).
function alive(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    return stat.slice(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3) !== 'Z';
  } catch { return false; }
}

// Start a daemon the way it lives on a real host: double-forked through sh
// so it is reparented away from this process. (A direct child would linger
// as a zombie while we block in spawnSync, and the starter's liveness probe
// would then wait out its SIGTERM grace period on a dead process.)
function spawnDetached(argv, env, logName) {
  const log = path.join(SCRATCH, logName);
  const pidFile = `${log}.pid`;
  const r = spawnSync('sh', ['-c', 'log=$1; pidf=$2; shift 2; setsid "$@" </dev/null >>"$log" 2>&1 & echo $! >"$pidf"',
    'sh', log, pidFile, ...argv], { env, cwd: REPO });
  if (r.status !== 0) throw new Error(`spawn ${argv.join(' ')}: ${r.stderr}`);
  return { pid: Number(fs.readFileSync(pidFile, 'utf8').trim()) };
}

function request(sock, method, p, json) {
  return new Promise((resolve, reject) => {
    const body = json === undefined ? undefined : Buffer.from(JSON.stringify(json));
    const headers = body ? { 'Content-Type': 'application/json' } : {};
    const req = http.request({ socketPath: sock, path: p, method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks).toString('utf8');
        let parsed;
        try { parsed = JSON.parse(buf); } catch { /* not JSON */ }
        resolve({ status: res.statusCode, json: parsed, body: buf });
      });
    });
    req.on('error', reject);
    req.setTimeout(10000, () => req.destroy(new Error(`${method} ${p}: timeout`)));
    if (body) req.write(body);
    req.end();
  });
}

// Attach over the WebSocket; resolves {snap, ws, out()} once the snapshot arrived.
function attach(sock, id) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws+unix://${sock}:/ws?session=${encodeURIComponent(id)}`);
    let out = '';
    let snap = null;
    const t = setTimeout(() => { ws.terminate(); reject(new Error('no snapshot within 5 s')); }, 5000);
    ws.on('message', (raw) => {
      const f = JSON.parse(raw.toString('utf8'));
      if (f.type === 'output') out += f.data;
      if (f.type === 'snapshot' && !snap) {
        snap = f;
        clearTimeout(t);
        resolve({ snap, ws, out: () => out });
      }
      if (f.type === 'error' && !snap) { clearTimeout(t); reject(new Error(`error frame: ${f.message}`)); }
    });
    ws.on('error', (e) => { clearTimeout(t); reject(e); });
  });
}
const closeWs = (ws) => new Promise((r) => { ws.once('close', r); ws.close(); });

function stripVT(s) {
  return s
    .replace(/\x1b\][\s\S]*?(?:\x07|\x1b\\)/g, '')
    .replace(/\x1bP[\s\S]*?\x1b\\/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\x1b[()*+][0-9A-Za-z]/g, '')
    .replace(/\x1b[=>78DEHMNOZc]/g, '');
}
function snapshotHasSeq(data, n) {
  const lines = new Set(stripVT(data).split(/\r?\n/).map((l) => l.trim()));
  const missing = [];
  for (let i = 1; i <= n; i++) if (!lines.has(String(i))) missing.push(i);
  return missing;
}

// Create a session over the API, run `seq 1 n` in it, detach.
async function createWithSeq(sock, n) {
  const r = await request(sock, 'POST', '/api/sessions', { cols: 80, rows: 24 });
  assert(r.status === 201 && r.json && r.json.id, `create: ${r.status} ${r.body}`);
  const a = await attach(sock, r.json.id);
  a.ws.send(JSON.stringify({ type: 'input', data: `seq 1 ${n}; echo "do""ne"\r` }));
  await waitFor(() => /\bdone\r?\n/.test(a.out()), 5000, 'seq output');
  await closeWs(a.ws);
  return r.json.id;
}

function ping(argv) {
  const r = spawnSync(argv[0], argv.slice(1), { env: ENV, encoding: 'utf8', timeout: 5000 });
  if (r.status !== 0) return null;
  try { return JSON.parse(r.stdout.trim().split('\n').pop()); } catch { return null; }
}

// ---------------------------------------------------------------------------

async function forward() {
  const NAME = 'mig';
  const nodePing = [NODE, path.join(REPO, 'ptyhost.js'), '--name', NAME, 'ping'];
  let nodeHostPid;
  let nodeServerPid;
  let goServerPid;
  let sid;
  let sock;

  const okA = await check('a. node pty host + node server up; session with seq 1 50', async () => {
    spawnDetached([NODE, path.join(REPO, 'ptyhost.js'), '--name', NAME], ENV, 'node-ptyhost-mig.log');
    const pong = await waitFor(() => ping(nodePing), 10000, 'node pty host ping');
    nodeHostPid = pong.pid;
    assert(nodeHostPid > 0, `ping pid ${JSON.stringify(pong)}`);
    const srv = spawnDetached([NODE, path.join(REPO, 'server.js')], { ...ENV, WEBMUX_PTYHOST: NAME }, 'node-server-mig.log');
    const adv = await waitFor(() => { const a = readAdvert(NAME); return a && a.pid === srv.pid && a; }, 10000, 'node advert');
    nodeServerPid = adv.pid;
    assert(adv.payloadHash === 'dev', `node advert hash ${adv.payloadHash}`);
    sock = adv.socket;
    sid = await createWithSeq(sock, 50);
  });
  if (!okA) return;

  let start1;
  const okB = await check('b. webmux-host start replaces the node server, keeps the node pty host', async () => {
    fs.mkdirSync(PAYLOAD, { recursive: true });
    fs.copyFileSync(BIN, path.join(PAYLOAD, 'webmux-host'));
    fs.chmodSync(path.join(PAYLOAD, 'webmux-host'), 0o755);
    fs.cpSync(path.join(REPO, 'shims'), path.join(PAYLOAD, 'shims'), { recursive: true });
    fs.writeFileSync(path.join(PAYLOAD, 'PAYLOAD_HASH'), `${HASH}\n`);
    const r = spawnSync(path.join(PAYLOAD, 'webmux-host'), ['start', '--name', NAME],
      { env: ENV, cwd: dirs.home, encoding: 'utf8', timeout: 60000 });
    const last = r.stdout.trim().split('\n').pop();
    start1 = JSON.parse(last);
    assert(r.status === 0, `start exit ${r.status}: ${last} ${r.stderr}`);
    assert(start1.ok === true && start1.action === 'started', `start result ${last}`);
    assert(start1.advert && start1.advert.payloadHash === HASH, `result advert ${last}`);
    await waitFor(() => !alive(nodeServerPid), 5000, `node server ${nodeServerPid} to exit`);
    assert(alive(nodeHostPid), `node pty host ${nodeHostPid} died`);
    const pong = ping(nodePing);
    assert(pong && pong.pid === nodeHostPid, `pty host pid changed: ${JSON.stringify(pong)}`);
    const adv = readAdvert(NAME);
    assert(adv.payloadHash === HASH, `advert hash ${adv.payloadHash}`);
    assert(adv.pid !== nodeServerPid && alive(adv.pid), `advert pid ${adv.pid}`);
    assert(adv.pid === start1.advert.pid, 'advert pid matches start result');
    const cmd = fs.readFileSync(`/proc/${adv.pid}/cmdline`, 'utf8').split('\0');
    assert(cmd[0] === path.join(PAYLOAD, 'webmux-host') && cmd[1] === 'serve', `new server cmdline ${cmd.join(' ')}`);
    goServerPid = adv.pid;
    sock = adv.socket;
  });
  if (!okB) return goServerPid;

  await check('c. attach through the Go server: snapshot carries seq 1..50', async () => {
    const h = await request(sock, 'GET', '/');
    assert(h.json && h.json.payloadHash === HASH && h.json.ptyhost === NAME, `identity ${h.body}`);
    const l = await request(sock, 'GET', '/api/sessions');
    assert(Array.isArray(l.json) && l.json.some((s) => s.id === sid), `session ${sid} not listed: ${l.body}`);
    const a = await attach(sock, sid);
    const missing = snapshotHasSeq(a.snap.data, 50);
    assert(!missing.length, `snapshot lacks ${missing.length} numbers (first ${missing.slice(0, 5)})`);
    // and it is live: input goes through the Go server to the node pty host
    a.ws.send(JSON.stringify({ type: 'input', data: 'echo "li""ve"\r' }));
    await waitFor(() => /\blive\r?\n/.test(a.out()), 5000, 'live echo');
    await closeWs(a.ws);
  });

  await check('d. webmux-host start again → reuse', async () => {
    const r = spawnSync(path.join(PAYLOAD, 'webmux-host'), ['start', '--name', NAME],
      { env: ENV, cwd: dirs.home, encoding: 'utf8', timeout: 30000 });
    const last = r.stdout.trim().split('\n').pop();
    const res = JSON.parse(last);
    assert(r.status === 0 && res.ok === true && res.action === 'reuse', `start result ${last}`);
    assert(res.advert.pid === goServerPid && alive(goServerPid), 'server pid changed');
  });

  await check('e. webmux-host ptyhost shutdown stops the NODE pty host; SIGTERM the Go server', async () => {
    const r = spawnSync(BIN, ['ptyhost', '--name', NAME, 'shutdown'], { env: ENV, encoding: 'utf8', timeout: 10000 });
    assert(r.status === 0, `shutdown exit ${r.status}: ${r.stdout} ${r.stderr}`);
    await waitFor(() => !fs.existsSync(hostSock(NAME)), 5000, 'pty host socket removal');
    await waitFor(() => !alive(nodeHostPid), 5000, 'node pty host exit');
    process.kill(goServerPid, 'SIGTERM');
    await waitFor(() => !alive(goServerPid), 5000, 'Go server exit');
    assert(!fs.existsSync(sock), 'http socket left behind');
  });
  return goServerPid;
}

async function reverse() {
  const NAME = 'x';
  const SOCK = path.join(SCRATCH, 'x.http.sock');
  let goHostPid;
  let srv;
  await check('f. Go pty host fronted by node server.js: create, attach, snapshot, shutdown', async () => {
    spawnDetached([BIN, 'ptyhost', '--name', NAME], ENV, 'go-ptyhost-x.log');
    const pong = await waitFor(() => ping([BIN, 'ptyhost', '--name', NAME, 'ping']), 10000, 'Go pty host ping');
    goHostPid = pong.pid;
    const cmd = fs.readFileSync(`/proc/${goHostPid}/cmdline`, 'utf8').split('\0');
    assert(cmd[0] === BIN && cmd[1] === 'ptyhost', `pty host cmdline ${cmd.join(' ')}`);
    // The node client sees the Go host the same way
    const np = ping([NODE, path.join(REPO, 'ptyhost.js'), '--name', NAME, 'ping']);
    assert(np && np.pid === goHostPid, `node ping of Go host: ${JSON.stringify(np)}`);
    srv = spawnDetached([NODE, path.join(REPO, 'server.js')], { ...ENV, WEBMUX_PTYHOST: NAME, WEBMUX_SOCKET: SOCK }, 'node-server-x.log');
    await waitFor(async () => { try { return (await request(SOCK, 'GET', '/')).status === 200; } catch { return false; } }, 10000, 'node server');
    const sid = await createWithSeq(SOCK, 40);
    const a = await attach(SOCK, sid);
    const missing = snapshotHasSeq(a.snap.data, 40);
    assert(!missing.length, `snapshot lacks ${missing.length} numbers (first ${missing.slice(0, 5)})`);
    assert(a.snap.pid > 0 && a.snap.cols === 80 && a.snap.rows === 24, `snapshot header ${JSON.stringify({ ...a.snap, data: undefined })}`);
    await closeWs(a.ws);
    assert(alive(goHostPid), 'Go pty host died');
    const r = spawnSync(NODE, [path.join(REPO, 'ptyhost.js'), '--name', NAME, 'shutdown'], { env: ENV, encoding: 'utf8', timeout: 10000 });
    assert(r.status === 0, `node shutdown exit ${r.status}: ${r.stdout} ${r.stderr}`);
    await waitFor(() => !fs.existsSync(hostSock(NAME)) && !alive(goHostPid), 5000, 'Go pty host exit');
  });
  if (srv && alive(srv.pid)) {
    process.kill(srv.pid, 'SIGTERM');
    await waitFor(() => !alive(srv.pid), 5000, 'node server exit').catch(() => {});
  }
}

// Kill anything still running with our scratch HOME (any test that failed
// midway leaves detached daemons behind otherwise).
function reapStragglers() {
  const mark = `HOME=${dirs.home}`;
  let n = 0;
  for (const ent of fs.readdirSync('/proc')) {
    const pid = Number(ent);
    if (!pid || pid === process.pid) continue;
    try {
      const env = fs.readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0');
      if (env.includes(mark)) { process.kill(pid, 'SIGKILL'); n++; }
    } catch { /* gone or not ours */ }
  }
  return n;
}

(async () => {
  console.log(`binary:  ${BIN}`);
  console.log(`scratch: ${SCRATCH}  payload hash: ${HASH}`);
  try {
    await forward();
    await reverse();
  } catch (err) {
    results.push({ name: 'harness', ok: false, err });
    console.log(`FAIL  harness: ${err.stack || err}`);
  }
  await sleep(200);
  const left = reapStragglers();
  if (left) {
    results.push({ name: 'no stragglers', ok: false });
    console.log(`FAIL  ${left} process(es) were still running under the scratch HOME (killed)`);
  }
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    for (const f of fs.readdirSync(SCRATCH).filter((n) => n.endsWith('.log'))) {
      console.log(`--- ${f} ---\n${fs.readFileSync(path.join(SCRATCH, f), 'utf8').split('\n').slice(-15).join('\n')}`);
    }
    const sl = path.join(dirs.home, '.webmux', 'mig.server.log');
    try { console.log(`--- mig.server.log ---\n${fs.readFileSync(sl, 'utf8').split('\n').slice(-15).join('\n')}`); } catch { /* none */ }
  }
  if (!process.env.MIG_KEEP && !failed.length) fs.rmSync(SCRATCH, { recursive: true, force: true });
  else console.log(`scratch kept: ${SCRATCH}`);
  process.exit(failed.length ? 1 : 0);
})();
