// webmux remote starter — runs ON THE TARGET HOST, under the node binary the
// Electron client pushed, from inside an extracted payload directory
// (~/.webmux/dist/payload/<hash>/deploy/remote-start.js).
//
// Idempotent "make this payload the running server" step:
//   - if the advert (~/.webmux/<name>.json) says this exact payload is
//     already running, do nothing;
//   - otherwise stop the old server (never the pty host — sessions live
//     there and survive the swap) and start server.js detached;
//   - wait for the new server's advert, then print it.
//
// Output contract: the LAST line on stdout is a single JSON object,
//   { ok: true, action: 'reuse'|'started', advert: {...} }  or
//   { ok: false, error: '...', logTail: '...' }
// The client tolerates shell-profile noise before it by parsing the last
// parseable line. Exit code 0 iff ok.

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const PAYLOAD_ROOT = path.resolve(__dirname, '..');
const WEBMUX_DIR = path.join(os.homedir(), '.webmux');

let name = 'default';
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--name') name = argv[++i];
  else if (argv[i].startsWith('--name=')) name = argv[i].slice('--name='.length);
}

const advertFile = path.join(WEBMUX_DIR, `${name}.json`);
const logFile = path.join(WEBMUX_DIR, `${name}.server.log`);

function fail(error) {
  let logTail = '';
  try {
    const log = fs.readFileSync(logFile, 'utf8');
    logTail = log.split('\n').slice(-15).join('\n');
  } catch { /* no log yet */ }
  console.log(JSON.stringify({ ok: false, error, logTail }));
  process.exit(1);
}

if (!/^[A-Za-z0-9._-]+$/.test(name)) fail(`invalid instance name '${name}'`);

let myHash = '';
try { myHash = fs.readFileSync(path.join(PAYLOAD_ROOT, 'PAYLOAD_HASH'), 'utf8').trim(); } catch { /* checked below */ }
if (!myHash) fail('payload is missing PAYLOAD_HASH — not a built payload?');

function readAdvert() {
  try { return JSON.parse(fs.readFileSync(advertFile, 'utf8')); } catch { return null; }
}

const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

// Guard against pid reuse before killing anything: on Linux, only treat the
// advertised pid as ours if its cmdline mentions server.js. Where /proc
// doesn't exist (future macOS targets), liveness is the best we can do.
function pidIsWebmuxServer(pid) {
  if (!pidAlive(pid)) return false;
  try {
    const cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').replace(/\0/g, ' ');
    return /server\.js/.test(cmdline);
  } catch {
    return true; // no /proc — trust the advert
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function stopOldServer(advert) {
  if (!advert || !advert.pid || !pidIsWebmuxServer(advert.pid)) return;
  await stopPid(advert.pid);
}

function socketAnswers(sockPath) {
  return new Promise((resolve) => {
    const sock = net.connect(sockPath);
    const done = (ok) => { sock.destroy(); resolve(ok); };
    sock.once('connect', () => done(true));
    sock.once('error', () => done(false));
    setTimeout(() => done(false), 2000);
  });
}

// The socket server.js listens on for this instance when WEBMUX_SOCKET is
// not set — mirrors runDir()/HTTP_SOCK in ptyhost-client.js and server.js.
function canonicalSocket() {
  const dir = process.env.XDG_RUNTIME_DIR
    ? path.join(process.env.XDG_RUNTIME_DIR, 'webmux')
    : path.join(os.tmpdir(), `webmux-${os.userInfo().username}`);
  return path.join(dir, `${name}.http.sock`);
}

// Pids of live server.js processes (ours) whose WEBMUX_PTYHOST is this
// instance — found through /proc, so Linux only; elsewhere the advert is the
// only source of truth. Covers the case where the advert points at a server
// that is gone (or at a dev run on another socket) while an older deployed
// server still holds the canonical socket: starting a new one would hit
// EADDRINUSE and exit, and the connect would fail forever.
function serversForInstance() {
  const pids = [];
  let entries;
  try { entries = fs.readdirSync('/proc'); } catch { return pids; }
  for (const ent of entries) {
    if (!/^\d+$/.test(ent)) continue;
    const pid = Number(ent);
    if (pid === process.pid) continue;
    try {
      const cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').replace(/\0/g, ' ');
      if (!/server\.js/.test(cmdline) || !/webmux/.test(cmdline)) continue;
      const env = fs.readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0');
      const inst = (env.find((e) => e.startsWith('WEBMUX_PTYHOST=')) || 'WEBMUX_PTYHOST=default').slice('WEBMUX_PTYHOST='.length);
      if ((inst || 'default') !== name) continue;
      if (env.some((e) => e.startsWith('WEBMUX_SOCKET='))) continue; // dev run on its own socket
      pids.push(pid);
    } catch { /* not ours to read, or gone */ }
  }
  return pids;
}

async function stopPid(pid) {
  try { process.kill(pid, 'SIGTERM'); } catch { return; }
  for (let i = 0; i < 30 && pidAlive(pid); i++) await sleep(100);
  if (pidAlive(pid)) {
    try { process.kill(pid, 'SIGKILL'); } catch { /* raced */ }
    for (let i = 0; i < 10 && pidAlive(pid); i++) await sleep(100);
  }
}

async function main() {
  const advert = readAdvert();
  if (advert && advert.payloadHash === myHash && pidIsWebmuxServer(advert.pid)
      && await socketAnswers(advert.socket)) {
    console.log(JSON.stringify({ ok: true, action: 'reuse', advert }));
    return;
  }

  await stopOldServer(advert);

  // Whatever the advert said, nothing of ours may be left holding the
  // canonical socket — the new server has to bind it.
  if (await socketAnswers(canonicalSocket())) {
    for (const pid of serversForInstance()) await stopPid(pid);
    if (await socketAnswers(canonicalSocket())) {
      fail(`another process is listening on ${canonicalSocket()} and could not be identified as a webmux server`);
    }
  }

  fs.mkdirSync(WEBMUX_DIR, { recursive: true, mode: 0o700 });
  const log = fs.openSync(logFile, 'a');
  fs.writeSync(log, `\n--- remote-start ${new Date().toISOString()} payload ${myHash.slice(0, 12)} ---\n`);
  const child = spawn(process.execPath, [path.join(PAYLOAD_ROOT, 'server.js')], {
    detached: true,
    cwd: PAYLOAD_ROOT,
    env: { ...process.env, WEBMUX_PTYHOST: name },
    stdio: ['ignore', log, log],
  });
  child.unref();
  fs.closeSync(log);

  // The server writes its advert once it is listening (and it first has to
  // spawn/adopt the pty host, which can take a few seconds on a slow board).
  for (let i = 0; i < 200; i++) {
    await sleep(150);
    const a = readAdvert();
    if (a && a.payloadHash === myHash && pidAlive(a.pid) && await socketAnswers(a.socket)) {
      console.log(JSON.stringify({ ok: true, action: 'started', advert: a }));
      return;
    }
    if (!pidAlive(child.pid) && !(readAdvert()?.payloadHash === myHash)) {
      return fail('server exited during startup');
    }
  }
  fail('server did not come up within 30s');
}

main().catch((err) => fail(String(err.message || err)));
