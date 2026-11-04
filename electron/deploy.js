// Auto-deploy: make a host that has nothing but sshd run webmux.
//
// On every connect, before the tunnel opens:
//   1. probe   — one ssh round trip: uname, libc flavor, which payloads
//                ~/.webmux/dist already holds
//   2. payload — pick this host's platform payload from the manifest the
//                client ships (electron/payload/payload.json +
//                <key>/payload.tar.gz, built by deploy/build-payload.js);
//                if the host lacks that hash, stream the tarball up and
//                extract it to ~/.webmux/dist/payload/<hash> (atomic: .tmp + mv)
//   3. start   — run `<payload>/webmux-host start --name <instance>`; it
//                reuses/starts the server and prints the advert (socket
//                path) that the tunnel then forwards to
//
// The payload carries a static native binary (webmux-host) + shims/, so the
// remote needs: sshd, a POSIX-ish sh, gzip, tar, and the coreutils used
// below (mkdir/mv/rm/ls/uname). No node, no compiler.
//
// This module is Electron-free on purpose: everything host-specific comes in
// through a ctx object, so the flow can be driven from a plain CLI
// (electron/test/deploy-cli.js, electron/test/deploy-fake.js) as well as
// from main.js.
//
//   ctx.spawnSsh(command) → ChildProcess  ssh already parameterized for the
//                                         profile (also registers the child
//                                         for kill-on-cancel)
//   ctx.status(msg)                       progress line for the connection UI
//   ctx.stderr(line)                      diagnostic tail line
//   ctx.isLive() → bool                   false once this attempt is cancelled
//
// Composite remote commands are wrapped in `exec sh -c '…'` so a csh/fish
// login shell on the target can't misparse them; the scripts stick to POSIX
// sh, double quotes, and $HOME (no tildes, no single quotes).

const fs = require('fs');
const path = require('path');
const { resolvePlatform, supportedSummary } = require('./platforms');

const REMOTE_BASE = '$HOME/.webmux/dist';

class Cancelled extends Error {
  constructor() { super('cancelled'); this.cancelled = true; }
}
const assertLive = (ctx) => { if (!ctx.isLive()) throw new Cancelled(); };

const shWrap = (script) => `exec sh -c '${script}'`;

// ---------------------------------------------------------------------------
// ssh plumbing
// ---------------------------------------------------------------------------

// Run one remote command. `input` streams a local file to the remote's stdin:
//   { file, label } — progress is reported via ctx.status as a
// percentage of the file's raw size.
function runSsh(ctx, command, { input } = {}) {
  return new Promise((resolve, reject) => {
    const child = ctx.spawnSsh(command);
    let out = '';
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (chunk) => {
      for (const line of String(chunk).split('\n')) if (line) ctx.stderr(line);
    });
    child.on('error', (err) => reject(err)); // spawn failure (no ssh binary)
    child.on('exit', (code, signal) => {
      if (code === 0) resolve(out);
      else reject(Object.assign(new Error(`ssh exited (${code ?? signal})`), { stdout: out }));
    });

    if (!input) {
      child.stdin.end();
      return;
    }
    child.stdin.on('error', () => {}); // EPIPE if remote side fails — exit reports it
    const total = fs.statSync(input.file).size;
    let sent = 0;
    let lastPct = -1;
    const src = fs.createReadStream(input.file);
    src.on('data', (c) => {
      sent += c.length;
      const pct = Math.floor((sent / total) * 100);
      if (pct !== lastPct) {
        lastPct = pct;
        ctx.status(`${input.label}… ${pct}% of ${(total / 1024 / 1024).toFixed(1)} MB`);
      }
    });
    src.on('error', (err) => { reject(err); child.kill(); });
    src.pipe(child.stdin);
  });
}

// ---------------------------------------------------------------------------
// Probe
// ---------------------------------------------------------------------------

const PROBE_SCRIPT = [
  'echo "@@os $(uname -s)"',
  'echo "@@cpu $(uname -m)"',
  '(ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo "@@musl yes" || echo "@@musl no"',
  `for f in ${REMOTE_BASE}/payload/*/PAYLOAD_HASH; do [ -f "$f" ] && echo "@@payload $f"; done`,
  'true',
].join('; ');

async function probeHost(ctx) {
  const out = await runSsh(ctx, shWrap(PROBE_SCRIPT));
  const probe = { os: '', cpu: '', musl: false, payloadHashes: [] };
  for (const line of out.split('\n')) {
    const m = /^@@(\S+) (.*)$/.exec(line.trim());
    if (!m) continue; // shell-profile noise
    const [, tag, value] = m;
    if (tag === 'os') probe.os = value.trim();
    else if (tag === 'cpu') probe.cpu = value.trim();
    else if (tag === 'musl') probe.musl = value.trim() === 'yes';
    else if (tag === 'payload') probe.payloadHashes.push(path.basename(path.dirname(value)));
  }
  if (!probe.os || !probe.cpu) throw new Error('host probe failed — no uname output (unusual remote shell?)');
  return probe;
}

// ---------------------------------------------------------------------------
// Pushes (atomic on the remote: stream to a dot-tmp path, mv into place —
// the probe only believes in fully materialized dirs)
// ---------------------------------------------------------------------------

function pushPayload(ctx, tarball, hash) {
  const base = `${REMOTE_BASE}/payload`;
  const tmp = `${base}/.tmp-${hash}`;
  const script = `rm -rf ${tmp} && mkdir -p ${tmp} && tar xzf - -C ${tmp} && rm -rf ${base}/${hash} && mv ${tmp} ${base}/${hash}`;
  return runSsh(ctx, shWrap(script), {
    input: { file: tarball, label: 'pushing webmux' },
  });
}

// ---------------------------------------------------------------------------
// Start + orchestration
// ---------------------------------------------------------------------------

const lastJsonLine = (out) => {
  for (const line of out.split('\n').reverse()) {
    try {
      const v = JSON.parse(line);
      if (v && typeof v === 'object') return v;
    } catch { /* keep looking */ }
  }
  return null;
};

async function remoteStart(ctx, hash, instance) {
  const bin = `${REMOTE_BASE}/payload/${hash}/webmux-host`;
  // The starter exits 1 on failure but still prints its { ok: false, error,
  // logTail } line — prefer that over the bare exit code.
  let out;
  let exitErr = null;
  try {
    out = await runSsh(ctx, shWrap(`exec ${bin} start --name ${instance}`));
  } catch (err) {
    if (err.stdout === undefined) throw new Error(`server start failed: ${err.message}`);
    exitErr = err;
    out = err.stdout;
  }
  const result = lastJsonLine(out);
  if (!result) {
    if (exitErr) throw new Error(`server start failed: ${exitErr.message}`);
    throw new Error('webmux-host start produced no result — see diagnostics');
  }
  if (!result.ok) {
    for (const line of String(result.logTail || '').split('\n')) if (line) ctx.stderr(line);
    throw new Error(`server start failed: ${result.error}`);
  }
  if (exitErr) throw new Error(`server start failed: ${exitErr.message}`);
  return result; // { ok, action: 'reuse'|'started', advert }
}

// The whole flow. Resolves with the start result ({ advert.socket } is what
// the tunnel needs); throws Cancelled quietly if ctx went dead.
//
//   payloadDir  dir holding <key>/payload.tar.gz (electron/payload)
//   manifest    parsed payload.json: { platforms: { <key>: { hash, bytes } }, builtAt }
//   instance    instance name (already validated by the caller)
async function deploy(ctx, { payloadDir, manifest, instance }) {
  ctx.status('probing host…');
  const probe = await probeHost(ctx);
  assertLive(ctx);

  const platform = resolvePlatform(probe);
  if (!platform) {
    throw new Error(`unsupported host platform '${probe.os} ${probe.cpu}${probe.musl ? ' (musl)' : ''}'`
      + ` — supported targets: ${supportedSummary()}`);
  }
  const entry = manifest?.platforms?.[platform.payloadKey];
  if (!entry || !/^[a-f0-9]{64}$/.test(String(entry.hash))) {
    throw new Error(`this client build has no ${platform.payloadKey} payload`
      + ' — run `node deploy/build-payload.js` (needs host/dist/webmux-host-'
      + `${platform.payloadKey}) and restart the app`);
  }
  const { hash } = entry;

  if (!probe.payloadHashes.includes(hash)) {
    const tarball = path.join(payloadDir, platform.payloadKey, 'payload.tar.gz');
    if (!fs.existsSync(tarball)) throw new Error(`payload tarball missing: ${tarball}`);
    await pushPayload(ctx, tarball, hash);
    assertLive(ctx);
  }

  ctx.status('starting server…');
  const result = await remoteStart(ctx, hash, instance);
  assertLive(ctx);
  return { ...result, platform: platform.key, payloadHash: hash };
}

module.exports = { deploy, probeHost, Cancelled };
