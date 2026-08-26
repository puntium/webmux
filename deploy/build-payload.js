// Build the pushable server payload for the Electron client's auto-deploy
// flow: a self-contained tarball of the server (sources + production
// node_modules + multi-arch pty prebuilds) that runs on any supported target
// under the node binary the client also pushes.
//
//   node deploy/build-payload.js
//
// Output (consumed by electron/deploy.js at connect time):
//   electron/payload/payload.tar.gz   the payload
//   electron/payload/payload.json     { hash, builtAt, bytes, files }
//   electron/payload/payload-staging/ the staged tree (kept for local testing)
//
// The hash is a content hash (sorted relative paths + file bytes), stamped
// into the payload as PAYLOAD_HASH; the running server reports it back via
// its advert (~/.webmux/<name>.json), which is how the client decides on
// re-push. Rebuilding unchanged sources yields the same hash.
//
// Architecture support comes from @homebridge/node-pty-prebuilt-multiarch,
// which replaces node-pty in the payload (ptyhost.js prefers it when
// present) and ships prebuilt .node binaries for linux x64/arm64/arm/ia32 —
// no compiler needed on the target. Adding a platform whose prebuild it
// lacks (e.g. darwin) means adding a prebuild source here and a row in
// electron/platforms.js.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO = path.resolve(__dirname, '..');
const OUT_DIR = path.join(REPO, 'electron', 'payload');
const STAGING = path.join(OUT_DIR, 'payload-staging');
const TARBALL = path.join(OUT_DIR, 'payload.tar.gz');
const MANIFEST = path.join(OUT_DIR, 'payload.json');

const PTY_PREBUILT = '@homebridge/node-pty-prebuilt-multiarch';
const PTY_PREBUILT_VERSION = '^0.14.1';

// Source files/dirs copied verbatim from the repo into the payload. No
// frontend here: the UI (electron/ui + the @xterm browser packages) ships
// inside the Electron client and never crosses the wire.
const SOURCES = [
  'server.js',
  'ptyhost.js',
  'ptyhost-client.js',
  'shims',
  'deploy/remote-start.js',
];

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
// deliberately excluded — npm doesn't produce stable modes across
// platforms — except that nothing we hash depends on them at runtime beyond
// the shims, which are committed with the exec bit set.
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

function main() {
  console.log('staging payload…');
  fs.rmSync(STAGING, { recursive: true, force: true });
  fs.mkdirSync(STAGING, { recursive: true });

  // Payload package.json: the repo's production deps with node-pty swapped
  // for the prebuilt multi-arch fork.
  const pkg = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8'));
  const deps = { ...pkg.dependencies };
  delete deps['node-pty'];
  deps[PTY_PREBUILT] = PTY_PREBUILT_VERSION;
  fs.writeFileSync(path.join(STAGING, 'package.json'), JSON.stringify({
    name: 'webmux-payload',
    version: pkg.version,
    private: true,
    dependencies: deps,
  }, null, 2) + '\n');

  console.log('npm install (production deps)…');
  execFileSync('npm', ['install', '--omit=dev', '--no-audit', '--no-fund', '--no-package-lock'], {
    cwd: STAGING,
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  for (const rel of SOURCES) {
    copyRecursive(path.join(REPO, rel), path.join(STAGING, rel));
  }

  const hash = contentHash(STAGING);
  fs.writeFileSync(path.join(STAGING, 'PAYLOAD_HASH'), hash + '\n');

  console.log('tarring…');
  execFileSync('tar', ['-czf', TARBALL, '-C', STAGING, '.']);

  const bytes = fs.statSync(TARBALL).size;
  fs.writeFileSync(MANIFEST, JSON.stringify({
    hash,
    builtAt: new Date().toISOString(),
    bytes,
  }, null, 2) + '\n');

  console.log(`payload ${hash.slice(0, 12)} — ${(bytes / 1024 / 1024).toFixed(1)} MB`);
  console.log(`  ${TARBALL}`);
}

main();
