// Local, ssh-free test of the push-deploy flow (electron/deploy.js +
// deploy/build-payload.js + electron/platforms.js):
//
//   node electron/test/deploy-fake.js
//
// Builds per-platform payloads from stand-in `webmux-host` shell scripts
// (WEBMUX_HOST_BIN_DIR) into a scratch dir (WEBMUX_PAYLOAD_OUT_DIR, so the
// real electron/payload is untouched), then drives deploy() with a ctx whose
// spawnSsh(command) runs the command through `sh -c` locally with $HOME
// pointed at a scratch "remote home". Scratch root: $WEBMUX_TEST_SCRATCH
// (kept afterwards for inspection: fakehome/, fakebin/, payload/), or a fresh
// dir under the OS tmpdir (removed on success).

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const { deploy, probeHost } = require('../deploy');
const { resolvePlatform, supportedSummary } = require('../platforms');

const keepScratch = Boolean(process.env.WEBMUX_TEST_SCRATCH);
const scratch = keepScratch
  ? path.resolve(process.env.WEBMUX_TEST_SCRATCH)
  : fs.mkdtempSync(path.join(os.tmpdir(), 'webmux-deploy-fake-'));
const fakeHome = path.join(scratch, 'fakehome');
const binDir = path.join(scratch, 'fakebin');
const outDir = path.join(scratch, 'payload');
for (const d of [fakeHome, binDir, outDir]) fs.rmSync(d, { recursive: true, force: true });
fs.mkdirSync(fakeHome, { recursive: true });
fs.mkdirSync(binDir, { recursive: true });

// Stand-in webmux-host: logs its argv + cwd, and `start` prints chatter then
// the starter's result object as the last stdout line (exit 1 on failure,
// like the real starter).
const fakeHost = (key) => `#!/bin/sh
# fake webmux-host (${key})
dir=$(cd "$(dirname "$0")" && pwd)
echo "$0 $* cwd=$(pwd)" >> "$HOME/fake-host.log"
case "$1" in
start)
  echo "starter chatter that is not JSON"
  echo "[1, 2]"
  if [ -f "$HOME/fail-start" ]; then
    echo '{"ok":false,"error":"boom","logTail":"tail one\\ntail two"}'
    exit 1
  fi
  h=$(cat "$dir/PAYLOAD_HASH")
  echo "{\\"ok\\":true,\\"action\\":\\"started\\",\\"advert\\":{\\"socket\\":\\"/tmp/x.sock\\",\\"payloadHash\\":\\"$h\\",\\"protocol\\":1,\\"pid\\":1,\\"startedAt\\":0}}"
  ;;
*) echo "fake webmux-host: unsupported $1" >&2; exit 2 ;;
esac
`;

function buildPayload(args, extraEnv = {}) {
  return spawnSync(process.execPath, [path.join(REPO, 'deploy', 'build-payload.js'), ...args], {
    env: { ...process.env, WEBMUX_HOST_BIN_DIR: binDir, WEBMUX_PAYLOAD_OUT_DIR: outDir, ...extraEnv },
    encoding: 'utf8',
  });
}
const readManifest = () => JSON.parse(fs.readFileSync(path.join(outDir, 'payload.json'), 'utf8'));

// A ctx that runs "ssh" commands locally. `noise` mimics a chatty login shell.
function makeCtx({ live = () => true } = {}) {
  const ctx = {
    commands: [],
    statuses: [],
    stderrLines: [],
    spawnSsh: (command) => {
      ctx.commands.push(command);
      return spawn('sh', ['-c', `echo "motd: welcome"; ${command}`], {
        cwd: fakeHome, // ssh lands in $HOME
        env: { ...process.env, HOME: fakeHome },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    },
    status: (msg) => ctx.statuses.push(msg),
    stderr: (line) => ctx.stderrLines.push(line),
    isLive: () => live(ctx),
  };
  return ctx;
}

async function main() {
  // -- platform resolution ------------------------------------------------
  const x64 = resolvePlatform({ os: 'Linux', cpu: 'x86_64', musl: false });
  assert.strictEqual(x64?.key, 'linux-x64', 'glibc x86_64 → linux-x64');
  assert.strictEqual(x64.payloadKey, 'linux-x64', 'payloadKey mirrors key');
  assert.ok(!('nodeArch' in x64) && !('tarballUrl' in x64), 'no node fields left');
  assert.strictEqual(resolvePlatform({ os: 'Linux', cpu: 'x86_64', musl: true })?.key, 'linux-x64', 'musl x86_64 → linux-x64 (static binary)');
  assert.strictEqual(resolvePlatform({ os: 'Linux', cpu: 'amd64', musl: false })?.key, 'linux-x64');
  assert.strictEqual(resolvePlatform({ os: 'Linux', cpu: 'aarch64', musl: false })?.key, 'linux-arm64');
  assert.strictEqual(resolvePlatform({ os: 'Linux', cpu: 'aarch64', musl: true })?.key, 'linux-arm64', 'musl aarch64 → linux-arm64');
  assert.strictEqual(resolvePlatform({ os: 'Linux', cpu: 'armv7l', musl: false }), null, 'armv7l unsupported');
  assert.strictEqual(resolvePlatform({ os: 'Darwin', cpu: 'arm64', musl: false }), null, 'darwin unsupported');
  assert.ok(/Linux x86_64/.test(supportedSummary()) && /Linux aarch64/.test(supportedSummary()));
  console.log('platforms ok');

  // -- build-payload ------------------------------------------------------
  let r = buildPayload([]);
  assert.notStrictEqual(r.status, 0, 'missing binaries fail the build');
  assert.ok(/host\/build\.sh/.test(r.stderr), `missing-binary error names host/build.sh (got ${r.stderr})`);
  r = buildPayload(['--only', 'linux-x99']);
  assert.notStrictEqual(r.status, 0, 'unknown --only key fails');

  for (const key of ['linux-x64', 'linux-arm64']) {
    fs.writeFileSync(path.join(binDir, `webmux-host-${key}`), fakeHost(key), { mode: 0o644 }); // build sets 0755
  }
  r = buildPayload(['--only', 'linux-x64']);
  assert.strictEqual(r.status, 0, `--only build: ${r.stderr}`);
  let m = readManifest();
  assert.deepStrictEqual(Object.keys(m.platforms), ['linux-x64'], '--only builds one platform');
  assert.ok(!fs.existsSync(path.join(outDir, 'linux-arm64')), 'no arm64 output for --only linux-x64');

  r = buildPayload([]);
  assert.strictEqual(r.status, 0, `full build: ${r.stderr}`);
  m = readManifest();
  assert.deepStrictEqual(Object.keys(m.platforms).sort(), ['linux-arm64', 'linux-x64']);
  assert.ok(typeof m.builtAt === 'string');
  for (const [key, entry] of Object.entries(m.platforms)) {
    assert.ok(/^[a-f0-9]{64}$/.test(entry.hash), `${key} hash`);
    const tar = path.join(outDir, key, 'payload.tar.gz');
    assert.strictEqual(fs.statSync(tar).size, entry.bytes, `${key} bytes`);
    const staging = path.join(outDir, key, 'staging');
    assert.strictEqual(fs.readFileSync(path.join(staging, 'PAYLOAD_HASH'), 'utf8').trim(), entry.hash);
    assert.strictEqual(fs.statSync(path.join(staging, 'webmux-host')).mode & 0o777, 0o755, 'binary is 0755');
    for (const shim of fs.readdirSync(path.join(REPO, 'shims'))) {
      const mode = fs.statSync(path.join(staging, 'shims', shim)).mode & 0o777;
      assert.strictEqual(mode, fs.statSync(path.join(REPO, 'shims', shim)).mode & 0o777, `shim ${shim} keeps its mode`);
    }
    const listing = spawnSync('tar', ['-tzf', tar], { encoding: 'utf8' }).stdout.split('\n')
      .filter(Boolean).map((l) => l.replace(/^\.\//, '').replace(/\/$/, '')).filter(Boolean).sort();
    assert.ok(listing.includes('webmux-host') && listing.includes('PAYLOAD_HASH') && listing.includes('shims'), `${key} tarball layout: ${listing}`);
    assert.ok(!listing.some((l) => /node_modules|server\.js|ptyhost/.test(l)), 'no node payload remnants');
  }
  assert.notStrictEqual(m.platforms['linux-x64'].hash, m.platforms['linux-arm64'].hash, 'platform hashes differ');
  const firstHashes = m.platforms;
  r = buildPayload(['--only', 'linux-arm64']);
  assert.strictEqual(r.status, 0);
  m = readManifest();
  assert.deepStrictEqual(m.platforms, firstHashes, 'rebuild is deterministic; --only keeps the other platform');
  console.log('build-payload ok');

  // -- probe parsing ------------------------------------------------------
  // canned remote output: `cat` echoes what we write before runSsh ends stdin
  const cannedProbe = (out) => probeHost({
    spawnSsh: () => {
      const child = spawn('cat', [], { stdio: ['pipe', 'pipe', 'pipe'] });
      child.stdin.write(out);
      return child;
    },
    status() {}, stderr() {}, isLive: () => true,
  });
  let probe = await cannedProbe('Last login: yesterday\n@@os Linux\n@@cpu aarch64\n@@musl yes\n'
    + '@@payload /home/u/.webmux/dist/payload/abc123/PAYLOAD_HASH\nnoise @@os Darwin\n');
  assert.deepStrictEqual(probe, { os: 'Linux', cpu: 'aarch64', musl: true, payloadHashes: ['abc123'] }, 'canned musl/aarch64 probe');
  assert.strictEqual(resolvePlatform(probe).key, 'linux-arm64');
  await assert.rejects(cannedProbe('just noise\n'), /host probe failed/);

  const ctx0 = makeCtx();
  probe = await probeHost(ctx0);
  assert.strictEqual(probe.os, os.type(), 'real local probe: os');
  assert.strictEqual(probe.cpu, spawnSync('uname', ['-m'], { encoding: 'utf8' }).stdout.trim(), 'real local probe: cpu');
  assert.deepStrictEqual(probe.payloadHashes, [], 'empty fake home has no payloads');
  assert.ok(!ctx0.commands[0].includes('@@node'), 'probe no longer lists node runtimes');
  console.log('probe ok');

  // -- full deploy against the fake remote home --------------------------
  const localPlatform = resolvePlatform(probe);
  assert.ok(localPlatform, `this machine (${probe.os} ${probe.cpu}) must be a supported platform for the e2e part`);
  const hash = m.platforms[localPlatform.key].hash;
  const remoteDir = path.join(fakeHome, '.webmux', 'dist', 'payload', hash);
  // a leftover tmp dir from an interrupted push is replaced
  fs.mkdirSync(path.join(fakeHome, '.webmux', 'dist', 'payload', `.tmp-${hash}`, 'junk'), { recursive: true });

  const ctx1 = makeCtx();
  let result = await deploy(ctx1, { payloadDir: outDir, manifest: m, instance: 'inst1' });
  assert.strictEqual(ctx1.commands.length, 3, 'probe + push + start');
  assert.ok(ctx1.statuses.some((s) => /^pushing webmux/.test(s)), 'push progress reported');
  assert.strictEqual(fs.statSync(path.join(remoteDir, 'webmux-host')).mode & 0o777, 0o755, 'remote binary executable');
  assert.ok(fs.statSync(path.join(remoteDir, 'shims')).isDirectory(), 'remote shims/');
  assert.ok(fs.statSync(path.join(remoteDir, 'shims', 'xdg-open')).mode & 0o100, 'remote shim executable');
  assert.strictEqual(fs.readFileSync(path.join(remoteDir, 'PAYLOAD_HASH'), 'utf8').trim(), hash, 'remote PAYLOAD_HASH');
  assert.ok(!fs.existsSync(path.join(fakeHome, '.webmux', 'dist', 'payload', `.tmp-${hash}`)), 'tmp dir moved into place');
  assert.strictEqual(result.ok, true);
  assert.strictEqual(result.action, 'started');
  assert.strictEqual(result.advert.socket, '/tmp/x.sock');
  assert.strictEqual(result.advert.payloadHash, hash, 'start result parsed from the last JSON line');
  assert.strictEqual(result.platform, localPlatform.key);
  assert.strictEqual(result.payloadHash, hash);
  const log = fs.readFileSync(path.join(fakeHome, 'fake-host.log'), 'utf8').trim().split('\n');
  assert.strictEqual(log.length, 1);
  assert.strictEqual(log[0], `${remoteDir}/webmux-host start --name inst1 cwd=${fakeHome}`, 'exact start command line');
  console.log('deploy (fresh host) ok');

  const ctx2 = makeCtx();
  result = await deploy(ctx2, { payloadDir: outDir, manifest: m, instance: 'inst1' });
  assert.strictEqual(ctx2.commands.length, 2, 'probe + start only: push skipped when the hash is present');
  assert.ok(!ctx2.statuses.some((s) => /^pushing/.test(s)), 'no push status');
  assert.strictEqual(result.advert.payloadHash, hash);
  console.log('deploy (hash present, push skipped) ok');

  // starter failure: exit 1 + { ok:false } line → its error and logTail surface
  fs.writeFileSync(path.join(fakeHome, 'fail-start'), '');
  const ctx3 = makeCtx();
  await assert.rejects(deploy(ctx3, { payloadDir: outDir, manifest: m, instance: 'inst1' }), /server start failed: boom/);
  assert.deepStrictEqual(ctx3.stderrLines.slice(-2), ['tail one', 'tail two'], 'logTail forwarded');
  fs.rmSync(path.join(fakeHome, 'fail-start'));
  console.log('deploy (start failure) ok');

  // manifest without this platform → clear error, no push
  const other = localPlatform.key === 'linux-x64' ? 'linux-arm64' : 'linux-x64';
  const ctx4 = makeCtx();
  await assert.rejects(
    deploy(ctx4, { payloadDir: outDir, manifest: { platforms: { [other]: m.platforms[other] } }, instance: 'i' }),
    new RegExp(`no ${localPlatform.key} payload`),
  );
  assert.strictEqual(ctx4.commands.length, 1, 'only the probe ran');

  // cancellation after the probe
  const ctx5 = makeCtx({ live: (c) => c.commands.length < 1 });
  await assert.rejects(deploy(ctx5, { payloadDir: outDir, manifest: m, instance: 'i' }), (e) => e.cancelled === true);
  assert.strictEqual(ctx5.commands.length, 1, 'nothing after cancel');
  console.log('deploy (missing platform, cancel) ok');

  if (keepScratch) console.log(`deploy-fake: all ok (scratch kept: ${scratch})`);
  else {
    fs.rmSync(scratch, { recursive: true, force: true });
    console.log('deploy-fake: all ok');
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
