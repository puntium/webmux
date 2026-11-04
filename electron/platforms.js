// Target-platform table for auto-deploy: maps what `uname` reports on the
// remote host to the per-platform payload the client ships
// (electron/payload/<key>/payload.tar.gz, built by deploy/build-payload.js
// from host/dist/webmux-host-<key>).
//
// ADDING A PLATFORM is one row here, plus the same key in build-payload.js's
// PLATFORMS list and a target in host/build.sh. Row fields:
//   key    stable identifier; also the payload key (payload.json `platforms`)
//   os     `uname -s` value ('Linux', 'Darwin', …)
//   cpus   accepted `uname -m` values
//   musl   null = libc-agnostic (the webmux-host binaries are fully static
//          musl builds, so one row serves glibc AND musl hosts); true/false
//          restricts the row to that libc (probed via ld-musl-*), for a
//          future dynamically linked build.
//
// Example of a future row:
//   { key: 'darwin-arm64', os: 'Darwin', cpus: ['arm64'], musl: null }

const PLATFORMS = [
  { key: 'linux-x64', os: 'Linux', cpus: ['x86_64', 'amd64'], musl: null },
  { key: 'linux-arm64', os: 'Linux', cpus: ['aarch64', 'arm64'], musl: null },
];

// probe: { os: 'Linux', cpu: 'x86_64', musl: false } (from electron/deploy.js).
// Returns the row plus `payloadKey` (the key into payload.json `platforms`),
// or null if unsupported.
function resolvePlatform(probe) {
  const row = PLATFORMS.find((p) => p.os === probe.os
    && p.cpus.includes(probe.cpu)
    && (p.musl === null || p.musl === Boolean(probe.musl)));
  if (!row) return null;
  return { ...row, payloadKey: row.key };
}

const supportedSummary = () => PLATFORMS
  .map((p) => `${p.os} ${p.cpus[0]}${p.musl === true ? ' (musl)' : p.musl === false ? ' (glibc)' : ''}`)
  .join(', ');

module.exports = { PLATFORMS, resolvePlatform, supportedSummary };
