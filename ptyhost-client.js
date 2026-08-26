// Shared helpers for talking to a webmux pty host (ptyhost.js): socket
// naming, newline-delimited JSON framing, one-shot control commands, and
// spawn-on-demand. Deliberately free of node-pty/@xterm imports so the web
// server never loads pty machinery into its own process.

const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const DEFAULT_NAME = 'default';

// Version of the pty-host control protocol (the newline-JSON exchange above
// this comment block). Bump it on incompatible changes: the version is baked
// into the socket name (for versions > 1), so a newly deployed server that
// speaks a newer protocol spawns a fresh pty host beside an old one instead
// of corrupting it — old sessions stay alive on the old host. Version 1 keeps
// the historical unversioned socket name for compatibility with running
// hosts.
const PROTOCOL = 1;

// Sockets live under the user's runtime dir (private, survives independent
// of any particular checkout), one socket per named host.
function runDir() {
  const dir = process.env.XDG_RUNTIME_DIR
    ? path.join(process.env.XDG_RUNTIME_DIR, 'webmux')
    : path.join(os.tmpdir(), `webmux-${os.userInfo().username}`);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

function socketPath(name) {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) {
    throw new Error(`invalid pty host name '${name}' (allowed: letters, digits, . _ -)`);
  }
  const suffix = PROTOCOL > 1 ? `.v${PROTOCOL}` : '';
  return path.join(runDir(), `${name}${suffix}.sock`);
}

function logPath(name) {
  return path.join(runDir(), `${name}.log`);
}

// Split a socket's byte stream into newline-delimited frames.
function readLines(sock, onLine) {
  let buf = '';
  sock.setEncoding('utf8');
  sock.on('data', (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (line) onLine(line);
    }
  });
}

function connect(name) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(socketPath(name));
    sock.once('connect', () => resolve(sock));
    sock.once('error', reject);
  });
}

// One-shot request/response: connect, send one command line, resolve with
// the single JSON reply line.
async function control(name, msg, { timeout = 5000 } = {}) {
  const sock = await connect(name);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`pty host '${name}': timed out waiting for reply`));
    }, timeout);
    readLines(sock, (line) => {
      clearTimeout(timer);
      sock.end();
      try { resolve(JSON.parse(line)); } catch (err) { reject(err); }
    });
    sock.on('error', (err) => { clearTimeout(timer); reject(err); });
    sock.write(JSON.stringify(msg) + '\n');
  });
}

// Ping the named host, spawning the daemon if it isn't running. The daemon
// is started detached in its own process group with output going to a log
// file in the runtime dir, so it survives this process's death; only an
// explicit `node ptyhost.js shutdown` (or kill) stops it.
async function ensureHost(name) {
  try { return await control(name, { cmd: 'ping' }); } catch { /* not running */ }
  fs.rmSync(socketPath(name), { force: true }); // stale socket from a dead host
  const log = fs.openSync(logPath(name), 'a');
  const child = spawn(process.execPath, [path.join(__dirname, 'ptyhost.js'), '--name', name], {
    detached: true,
    stdio: ['ignore', log, log],
  });
  child.unref();
  fs.closeSync(log);
  for (let i = 0; i < 50; i++) {
    await new Promise((r) => setTimeout(r, 100));
    try { return await control(name, { cmd: 'ping' }); } catch { /* still starting */ }
  }
  throw new Error(`pty host '${name}' failed to start — see ${logPath(name)}`);
}

module.exports = { DEFAULT_NAME, PROTOCOL, runDir, socketPath, logPath, readLines, connect, control, ensureHost };
