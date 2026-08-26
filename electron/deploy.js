// Auto-deploy: make a host that has nothing but sshd run webmux.
//
// On connect (for profiles with autoDeploy), before the tunnel opens:
//   1. probe   — one ssh round trip: uname, libc flavor, which node runtimes
//                and payloads ~/.webmux/dist already holds
//   2. runtime — if the right node build is missing remotely, download the
//                official tarball to a local cache (SHASUMS256-verified),
//                extract bin/node, and stream it up (gzipped) over ssh
//   3. payload — if the running/installed payload hash differs from the one
//                this client ships (electron/dist/payload.tar.gz, built by
//                deploy/build-payload.js), stream the tarball up and extract
//                it to ~/.webmux/dist/payload/<hash> (atomic: .tmp + mv)
//   4. start   — run deploy/remote-start.js under the pushed node; it
//                reuses/starts server.js and prints the advert (socket path)
//                that the tunnel then forwards to
//
// Remote requirements: sshd, a POSIX-ish sh, gzip, tar, and the coreutils
// used below (mkdir/mv/rm/ls/chmod/uname). No node, no compiler.
//
// This module is Electron-free on purpose: everything host-specific comes in
// through a ctx object, so the flow can be driven from a plain CLI
// (electron/test/deploy-cli.js) as well as from main.js.
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

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const zlib = require('zlib');
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
//   { file, gzip: bool, label } — progress is reported via ctx.status as a
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
      else reject(new Error(`ssh exited (${code ?? signal})`));
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
    if (input.gzip) src.pipe(zlib.createGzip()).pipe(child.stdin);
    else src.pipe(child.stdin);
  });
}

// ---------------------------------------------------------------------------
// Probe
// ---------------------------------------------------------------------------

const PROBE_SCRIPT = [
  'echo "@@os $(uname -s)"',
  'echo "@@cpu $(uname -m)"',
  '(ls /lib/ld-musl-* || ls /usr/lib/ld-musl-* || ls /lib/*/ld-musl-*) >/dev/null 2>&1 && echo "@@musl yes" || echo "@@musl no"',
  `for f in ${REMOTE_BASE}/node/*/bin/node; do [ -x "$f" ] && echo "@@node $f"; done`,
  `for f in ${REMOTE_BASE}/payload/*/PAYLOAD_HASH; do [ -f "$f" ] && echo "@@payload $f"; done`,
  'true',
].join('; ');

async function probeHost(ctx) {
  const out = await runSsh(ctx, shWrap(PROBE_SCRIPT));
  const probe = { os: '', cpu: '', musl: false, nodeDirs: [], payloadHashes: [] };
  for (const line of out.split('\n')) {
    const m = /^@@(\S+) (.*)$/.exec(line.trim());
    if (!m) continue; // shell-profile noise
    const [, tag, value] = m;
    if (tag === 'os') probe.os = value.trim();
    else if (tag === 'cpu') probe.cpu = value.trim();
    else if (tag === 'musl') probe.musl = value.trim() === 'yes';
    else if (tag === 'node') probe.nodeDirs.push(path.basename(path.dirname(path.dirname(value))));
    else if (tag === 'payload') probe.payloadHashes.push(path.basename(path.dirname(value)));
  }
  if (!probe.os || !probe.cpu) throw new Error('host probe failed — no uname output (unusual remote shell?)');
  return probe;
}

// ---------------------------------------------------------------------------
// Local node runtime cache (download → verify → extract bin/node)
// ---------------------------------------------------------------------------

function httpsGet(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(httpsGet(new URL(res.headers.location, url).href, redirects - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`GET ${url}: HTTP ${res.statusCode}`));
      }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    }).on('error', reject);
  });
}

function downloadFile(url, dest, onProgress, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(downloadFile(new URL(res.headers.location, url).href, dest, onProgress, redirects - 1));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`GET ${url}: HTTP ${res.statusCode}`));
      }
      const total = Number(res.headers['content-length']) || 0;
      let got = 0;
      const file = fs.createWriteStream(dest);
      res.on('data', (c) => { got += c.length; if (total) onProgress(got, total); });
      res.pipe(file);
      file.on('finish', () => file.close(() => resolve()));
      res.on('error', reject);
      file.on('error', reject);
    }).on('error', reject);
  });
}

function sha256File(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(file)
      .on('data', (c) => h.update(c))
      .on('end', () => resolve(h.digest('hex')))
      .on('error', reject);
  });
}

// Minimal tar reader: pull the single member whose path ends with `suffix`
// out of a .tar.gz. Handles ustar prefix fields and skips pax/GNU long-name
// entries (the node dist tarballs use them for deep npm paths, but bin/node
// itself always fits a plain header).
function extractFromTarGz(tarGz, suffix, dest) {
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(dest);
    let buf = Buffer.alloc(0);
    let remaining = 0; // data bytes left in current entry (incl. padding)
    let capture = 0; // real file bytes still to write when capturing
    let found = false;
    const gunzip = zlib.createGunzip();
    const src = fs.createReadStream(tarGz);

    const finish = (err) => {
      gunzip.removeAllListeners();
      gunzip.on('error', () => {});
      src.destroy();
      gunzip.destroy();
      out.end(() => (err ? reject(err) : found ? resolve() : reject(new Error(`no ${suffix} in ${path.basename(tarGz)}`))));
    };

    gunzip.on('data', (chunk) => {
      buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
      while (true) {
        if (remaining > 0) {
          const take = Math.min(remaining, buf.length);
          if (capture > 0) {
            out.write(buf.subarray(0, Math.min(capture, take)));
            capture -= Math.min(capture, take);
            if (capture === 0 && found) { finish(); return; }
          }
          remaining -= take;
          buf = buf.subarray(take);
        }
        if (remaining > 0 || buf.length < 512) return;
        const header = buf.subarray(0, 512);
        buf = buf.subarray(512);
        if (header.every((b) => b === 0)) return; // end-of-archive blocks
        const str = (start, len) => header.toString('utf8', start, start + len).replace(/\0.*$/, '');
        const size = parseInt(str(124, 12).trim() || '0', 8) || 0;
        const type = str(156, 1);
        const prefix = str(345, 155);
        const name = (prefix ? `${prefix}/` : '') + str(0, 100);
        remaining = Math.ceil(size / 512) * 512;
        if ((type === '0' || type === '') && name.endsWith(suffix)) {
          found = true;
          capture = size;
        }
      }
    });
    gunzip.on('end', () => finish());
    gunzip.on('error', finish);
    src.on('error', finish).pipe(gunzip);
  });
}

// Returns the path of the cached local copy of this platform's node binary,
// downloading and verifying it first if this client hasn't seen it yet.
async function ensureLocalNode(ctx, platform, cacheDir) {
  const bin = path.join(cacheDir, platform.nodeDirName, 'node');
  if (fs.existsSync(bin)) return bin;
  fs.mkdirSync(cacheDir, { recursive: true });

  ctx.status(`fetching ${platform.nodeDirName} checksums…`);
  const shasums = (await httpsGet(platform.shasumsUrl)).toString('utf8');
  const line = shasums.split('\n').find((l) => l.trim().endsWith(platform.tarballName));
  if (!line) throw new Error(`${platform.tarballName} not in SHASUMS256.txt at ${platform.shasumsUrl}`);
  const expected = line.trim().split(/\s+/)[0];
  assertLive(ctx);

  const tmpTar = path.join(cacheDir, `.dl-${platform.tarballName}`);
  let lastPct = -1;
  await downloadFile(platform.tarballUrl, tmpTar, (got, total) => {
    const pct = Math.floor((got / total) * 100);
    if (pct !== lastPct) { lastPct = pct; ctx.status(`downloading node runtime… ${pct}%`); }
  });
  const actual = await sha256File(tmpTar);
  if (actual !== expected) {
    fs.rmSync(tmpTar, { force: true });
    throw new Error(`checksum mismatch for ${platform.tarballName}`);
  }
  assertLive(ctx);

  ctx.status('unpacking node runtime…');
  const tmpBin = path.join(cacheDir, `.extract-${platform.nodeDirName}`);
  await extractFromTarGz(tmpTar, '/bin/node', tmpBin);
  fs.chmodSync(tmpBin, 0o755);
  fs.mkdirSync(path.dirname(bin), { recursive: true });
  fs.renameSync(tmpBin, bin);
  fs.rmSync(tmpTar, { force: true });
  return bin;
}

// ---------------------------------------------------------------------------
// Pushes (atomic on the remote: stream to a dot-tmp path, mv into place —
// the probe only believes in fully materialized dirs)
// ---------------------------------------------------------------------------

function pushNode(ctx, platform, localBin) {
  const base = `${REMOTE_BASE}/node`;
  const dir = `${base}/${platform.nodeDirName}`;
  const tmp = `${base}/.tmp-${platform.nodeDirName}`;
  const script = `mkdir -p ${base} && gzip -dc > ${tmp} && chmod 755 ${tmp} && mkdir -p ${dir}/bin && mv ${tmp} ${dir}/bin/node`;
  return runSsh(ctx, shWrap(script), {
    input: { file: localBin, gzip: true, label: 'pushing node runtime' },
  });
}

function pushPayload(ctx, tarball, hash) {
  const base = `${REMOTE_BASE}/payload`;
  const tmp = `${base}/.tmp-${hash}`;
  const script = `rm -rf ${tmp} && mkdir -p ${tmp} && tar xzf - -C ${tmp} && rm -rf ${base}/${hash} && mv ${tmp} ${base}/${hash}`;
  return runSsh(ctx, shWrap(script), {
    input: { file: tarball, gzip: false, label: 'pushing webmux' },
  });
}

// ---------------------------------------------------------------------------
// Start + orchestration
// ---------------------------------------------------------------------------

const lastJsonLine = (out) => {
  for (const line of out.split('\n').reverse()) {
    try { return JSON.parse(line); } catch { /* keep looking */ }
  }
  return null;
};

async function remoteStart(ctx, platform, hash, instance) {
  const node = `${REMOTE_BASE}/node/${platform.nodeDirName}/bin/node`;
  const starter = `${REMOTE_BASE}/payload/${hash}/deploy/remote-start.js`;
  const out = await runSsh(ctx, shWrap(`exec ${node} ${starter} --name ${instance}`))
    .catch((err) => { throw new Error(`server start failed: ${err.message}`); });
  const result = lastJsonLine(out);
  if (!result) throw new Error('remote-start produced no result — see diagnostics');
  if (!result.ok) {
    for (const line of String(result.logTail || '').split('\n')) if (line) ctx.stderr(line);
    throw new Error(`server start failed: ${result.error}`);
  }
  return result; // { ok, action: 'reuse'|'started', advert }
}

// The whole flow. Resolves with the remote-start result ({ advert.socket } is
// what the tunnel needs); throws Cancelled quietly if ctx went dead.
async function deploy(ctx, { payloadTar, payloadHash, instance, nodeCacheDir }) {
  ctx.status('probing host…');
  const probe = await probeHost(ctx);
  assertLive(ctx);

  const platform = resolvePlatform(probe);
  if (!platform) {
    throw new Error(`unsupported host platform '${probe.os} ${probe.cpu}${probe.musl ? ' (musl)' : ''}'`
      + ` — auto-deploy supports: ${supportedSummary()}`);
  }

  if (!probe.nodeDirs.includes(platform.nodeDirName)) {
    const bin = await ensureLocalNode(ctx, platform, nodeCacheDir);
    assertLive(ctx);
    await pushNode(ctx, platform, bin);
    assertLive(ctx);
  }

  if (!probe.payloadHashes.includes(payloadHash)) {
    await pushPayload(ctx, payloadTar, payloadHash);
    assertLive(ctx);
  }

  ctx.status('starting server…');
  const result = await remoteStart(ctx, platform, payloadHash, instance);
  assertLive(ctx);
  return result;
}

module.exports = { deploy, probeHost, ensureLocalNode, extractFromTarGz, Cancelled };
