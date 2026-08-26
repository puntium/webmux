// Target-platform table for auto-deploy: maps what `uname` reports on the
// remote host to a node runtime the client can download, cache, and push.
//
// ADDING A PLATFORM is one row here (plus, if the pty prebuild for it is not
// already shipped by @homebridge/node-pty-prebuilt-multiarch, a prebuild
// source in deploy/build-payload.js — the payload currently carries
// linux x64/arm64/arm/ia32 prebuilds). Row fields:
//   key       stable identifier, also the suffix of the cached runtime dir
//   os        `uname -s` value ('Linux', 'Darwin', …)
//   cpus      accepted `uname -m` values
//   musl      whether this row is for musl-libc hosts (probed via ld-musl-*)
//   nodeArch  arch part of the official tarball name (node-v<V>-<nodeArch>.tar.gz)
// Optional per-row overrides, for platforms official builds don't cover:
//   nodeVersion  pin a different node version than NODE_VERSION
//   distBase     alternate download root, e.g. unofficial-builds:
//                'https://unofficial-builds.nodejs.org/download/release'
//                (layout mirrors nodejs.org/dist: <base>/v<V>/<file> + SHASUMS256.txt)
//
// Examples of future rows:
//   { key: 'darwin-arm64', os: 'Darwin', cpus: ['arm64'], musl: false, nodeArch: 'darwin-arm64' }
//   { key: 'linux-armv6l', os: 'Linux', cpus: ['armv6l'], musl: false, nodeArch: 'linux-armv6l',
//     distBase: 'https://unofficial-builds.nodejs.org/download/release' }
//   { key: 'linux-x64-musl', os: 'Linux', cpus: ['x86_64'], musl: true, nodeArch: 'linux-x64-musl',
//     distBase: 'https://unofficial-builds.nodejs.org/download/release' }

const NODE_VERSION = '22.12.0';
const NODE_DIST_BASE = 'https://nodejs.org/dist';

const PLATFORMS = [
  { key: 'linux-x64', os: 'Linux', cpus: ['x86_64', 'amd64'], musl: false, nodeArch: 'linux-x64' },
  { key: 'linux-arm64', os: 'Linux', cpus: ['aarch64', 'arm64'], musl: false, nodeArch: 'linux-arm64' },
];

// probe: { os: 'Linux', cpu: 'x86_64', musl: false } (from electron/deploy.js).
// Returns the row plus derived download coordinates, or null if unsupported.
function resolvePlatform(probe) {
  const row = PLATFORMS.find((p) => p.os === probe.os
    && p.cpus.includes(probe.cpu)
    && p.musl === Boolean(probe.musl));
  if (!row) return null;
  const version = row.nodeVersion || NODE_VERSION;
  const distBase = row.distBase || NODE_DIST_BASE;
  const nodeDirName = `node-v${version}-${row.nodeArch}`;
  return {
    ...row,
    nodeVersion: version,
    nodeDirName, // cache dir name locally AND under ~/.webmux/dist/node/ remotely
    tarballName: `${nodeDirName}.tar.gz`,
    tarballUrl: `${distBase}/v${version}/${nodeDirName}.tar.gz`,
    shasumsUrl: `${distBase}/v${version}/SHASUMS256.txt`,
  };
}

const supportedSummary = () => PLATFORMS
  .map((p) => `${p.os} ${p.cpus[0]}${p.musl ? ' (musl)' : ''}`)
  .join(', ');

module.exports = { NODE_VERSION, PLATFORMS, resolvePlatform, supportedSummary };
