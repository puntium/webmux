// Build the pushable per-platform payloads for the Electron client's
// auto-deploy flow. Each payload is the native `webmux-host` binary for one
// platform plus the shell shims — no node, no node_modules, no npm install.
//
//   node deploy/build-payload.js                 # every platform in PLATFORMS
//   node deploy/build-payload.js --only linux-x64
//
// Inputs: host/dist/webmux-host-<key>, built by host/build.sh (`make host`).
// WEBMUX_HOST_BIN_DIR=<dir> sources webmux-host-<key> from <dir> instead,
// and WEBMUX_PAYLOAD_OUT_DIR=<dir> writes the output there instead of
// electron/payload (both used by electron/test/deploy-fake.js with a
// stand-in script).
//
// Output (consumed by electron/deploy.js at connect time):
//   electron/payload/<key>/payload.tar.gz   the payload for that platform
//   electron/payload/<key>/staging/         the staged tree (kept for local testing)
//   electron/payload/payload.json           { platforms: { <key>: { hash, bytes } }, builtAt }
//
// Payload tree: webmux-host (0755), shims/ (exec bits kept), PAYLOAD_HASH.
// The hash is a content hash (sorted relative paths + file bytes, excluding
// PAYLOAD_HASH), stamped into the payload as PAYLOAD_HASH; the running
// server reports it back via its advert (~/.webmux/<name>.json), which is
// how the client decides on re-push. Rebuilding unchanged inputs yields the
// same hash. Platforms get distinct hashes (their binaries differ), so they
// coexist under ~/.webmux/dist/payload/ on a shared $HOME.
//
// --only writes a manifest containing just the platforms built in this run;
// a previous build's other platforms are kept in payload.json only if their
// tarball is still on disk.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO = path.resolve(__dirname, '..');
const OUT_DIR = process.env.WEBMUX_PAYLOAD_OUT_DIR
  ? path.resolve(process.env.WEBMUX_PAYLOAD_OUT_DIR)
  : path.join(REPO, 'electron', 'payload');
const MANIFEST = path.join(OUT_DIR, 'payload.json');
const BIN_DIR = process.env.WEBMUX_HOST_BIN_DIR
  ? path.resolve(process.env.WEBMUX_HOST_BIN_DIR)
  : path.join(REPO, 'host', 'dist');

// Payload keys; must match `key` in electron/platforms.js.
const PLATFORMS = ['linux-x64', 'linux-arm64'];

function copyRecursive(src, dest) {
  const st = fs.lstatSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const name of fs.readdirSync(src)) {
      copyRecursive(path.join(src, name), path.join(dest, name));
    }
  } else if (st.isSymbolicLink()) {
    fs.symlinkSync(fs.readlinkSync(src), dest);
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
    fs.chmodSync(dest, st.mode & 0o777); // shims keep their exec bit
  }
}

// Deterministic content hash of the staged tree (excluding PAYLOAD_HASH
// itself): sha256 over sorted "relpath\0filehash\n" lines. File modes are
// excluded; the binary is chmodded 0755 here and the shims are committed
// with the exec bit set.
function contentHash(root) {
  const files = [];
  (function walk(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name);
      const st = fs.lstatSync(p);
      if (st.isDirectory()) walk(p);
      else files.push(p);
    }
  })(root);
  const h = crypto.createHash('sha256');
  for (const p of files) {
    const rel = path.relative(root, p);
    if (rel === 'PAYLOAD_HASH') continue;
    const st = fs.lstatSync(p);
    const body = st.isSymbolicLink()
      ? Buffer.from(`link:${fs.readlinkSync(p)}`)
      : fs.readFileSync(p);
    h.update(`${rel}\0${crypto.createHash('sha256').update(body).digest('hex')}\n`);
  }
  return h.digest('hex');
}

function parseArgs(argv) {
  let only = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--only') only = argv[++i];
    else if (argv[i].startsWith('--only=')) only = argv[i].slice(7);
    else fail(`unknown argument '${argv[i]}' (usage: build-payload.js [--only <key>])`);
  }
  if (only !== null && !PLATFORMS.includes(only)) {
    fail(`--only: unknown platform '${only}' (known: ${PLATFORMS.join(', ')})`);
  }
  return { keys: only ? [only] : PLATFORMS };
}

function fail(msg) {
  console.error(`build-payload: ${msg}`);
  process.exit(1);
}

function buildOne(key) {
  const bin = path.join(BIN_DIR, `webmux-host-${key}`);
  if (!fs.existsSync(bin)) {
    fail(`missing ${bin} — build it with host/build.sh (\`make host\`, or`
      + ` \`nix develop ./host -c ./build.sh\` in host/), or pass --only <key> for`
      + ' the platforms you have');
  }
  const outDir = path.join(OUT_DIR, key);
  const staging = path.join(outDir, 'staging');
  const tarball = path.join(outDir, 'payload.tar.gz');

  fs.rmSync(staging, { recursive: true, force: true });
  fs.mkdirSync(staging, { recursive: true });
  fs.copyFileSync(bin, path.join(staging, 'webmux-host'));
  fs.chmodSync(path.join(staging, 'webmux-host'), 0o755);
  copyRecursive(path.join(REPO, 'shims'), path.join(staging, 'shims'));

  const hash = contentHash(staging);
  fs.writeFileSync(path.join(staging, 'PAYLOAD_HASH'), hash + '\n');

  execFileSync('tar', ['-czf', tarball, '-C', staging, '.']);
  const bytes = fs.statSync(tarball).size;
  console.log(`payload ${key} ${hash.slice(0, 12)} — ${(bytes / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  ${tarball}`);
  return { hash, bytes };
}

function main() {
  const { keys } = parseArgs(process.argv.slice(2));
  fs.mkdirSync(OUT_DIR, { recursive: true });
  // Leftovers of the old single-payload layout would otherwise sit in the dir.
  for (const stale of ['payload.tar.gz', 'payload-staging']) {
    fs.rmSync(path.join(OUT_DIR, stale), { recursive: true, force: true });
  }

  let previous = {};
  try {
    previous = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')).platforms || {};
  } catch { /* first build, or old-format manifest */ }

  const platforms = {};
  for (const key of PLATFORMS) {
    if (keys.includes(key)) platforms[key] = buildOne(key);
    else if (previous[key] && fs.existsSync(path.join(OUT_DIR, key, 'payload.tar.gz'))) {
      platforms[key] = previous[key];
    }
  }
  fs.writeFileSync(MANIFEST, JSON.stringify({
    platforms,
    builtAt: new Date().toISOString(),
  }, null, 2) + '\n');
  console.log(`  ${MANIFEST} (${Object.keys(platforms).join(', ')})`);
}

main();
