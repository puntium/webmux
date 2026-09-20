// macOS Local Network privacy, seen from a process that spawns ssh.
//
// Since macOS 15 (and, more aggressively, 26.5+/27) a connection to a host
// on the LAN — RFC 1918 / link-local addresses, `.local` names — is gated
// behind a per-app grant in System Settings › Privacy & Security › Local
// Network. A denied connect fails instantly with EHOSTUNREACH, which ssh
// prints as "No route to host": indistinguishable from a real routing
// failure except by timing (a real one waits out ARP for seconds).
//
// The grant is attributed to a "responsible process". For an Electron app
// that is supposed to be the main process, but macOS regularly records the
// prompt against a helper (each helper gets its own entry) and the ssh
// children — spawned by main — stay denied no matter what the toggle says.
// Both of the workarounds shipped by other ssh-spawning apps live here:
//
//   probe()   — main opens (and immediately closes) a TCP connection to the
//               target from its own process before spawning ssh. The prompt
//               then lands on the process that owns the ssh children.
//   looksDenied() / HINT — when ssh still reports "No route to host", say
//               what it almost certainly means and where the toggle is,
//               instead of a generic "connection failed".
//
// Electron-free so electron/test/lan.js can exercise it directly.

const dns = require('dns');
const net = require('net');

const PROBE_TIMEOUT = 3000; // ms; the prompt appears on connect(), not on completion

const HINT = 'macOS blocked local network access for webmux — allow it under '
  + 'System Settings › Privacy & Security › Local Network; webmux reconnects by itself once it is allowed. '
  + 'If it is already allowed, toggle it off and on (or launch webmux from Terminal once).';

// The direct ssh hop for a profile: { host, port }, or null when ssh won't
// connect to the profile's host itself (a ProxyJump goes via the jump host,
// and macOS attributes that connection to the jump, not to us).
function sshTarget(profile) {
  const extra = String(profile.extraOptions || '');
  if (/ProxyJump=|ProxyCommand=|(^|\s)-J(\s|$)/.test(extra)) return null;
  let host = String(profile.host || '').trim();
  const at = host.lastIndexOf('@');
  if (at !== -1) host = host.slice(at + 1);
  if (!host) return null;
  return { host, port: Number(profile.sshPort) || 22 };
}

// IPv4/IPv6 literal in a range macOS treats as "local network".
function isLocalAddress(ip) {
  const v = net.isIP(ip);
  if (v === 4) {
    const [a, b] = ip.split('.').map(Number);
    return a === 10
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || (a === 169 && b === 254);
  }
  if (v === 6) {
    const lower = ip.toLowerCase();
    if (lower.startsWith('::ffff:')) return isLocalAddress(lower.slice(7));
    const first = parseInt(lower.split(':')[0] || '0', 16);
    return (first & 0xffc0) === 0xfe80 // fe80::/10 link-local
      || (first & 0xfe00) === 0xfc00; // fc00::/7 unique-local
  }
  return false;
}

// Whether a connection to `host` would be subject to the Local Network
// grant. `.local` names count without resolving them: mDNS resolution is
// itself gated, so a lookup from a denied process just fails.
async function isLocalTarget(host) {
  const h = String(host).replace(/\.$/, '').toLowerCase();
  if (h.endsWith('.local')) return true;
  if (net.isIP(h)) return isLocalAddress(h);
  try {
    const addrs = await dns.promises.lookup(h, { all: true });
    return addrs.some((a) => isLocalAddress(a.address));
  } catch {
    return false;
  }
}

// One TCP connect to host:port from this process, torn down as soon as it
// resolves either way. Never rejects: { ok, code, ms }. `code` is the
// socket error code ('EHOSTUNREACH' is the denial signature), or 'ETIMEDOUT'.
function probe(host, port, timeout = PROBE_TIMEOUT) {
  return new Promise((resolve) => {
    const started = Date.now();
    const sock = net.connect({ host, port });
    const done = (ok, code) => {
      sock.destroy();
      resolve({ ok, code, ms: Date.now() - started });
    };
    sock.setTimeout(timeout, () => done(false, 'ETIMEDOUT'));
    sock.once('connect', () => done(true));
    sock.once('error', (err) => done(false, err.code || String(err)));
  });
}

// A probe outcome that means "the grant isn't there (yet)": the denial
// itself, or — for a `.local` name — a failed lookup, since mDNS resolution
// is gated by the same permission and fails first while the prompt is up.
// Anything else (connected, refused, timed out, a non-.local resolve
// failure) is a verdict on the host, not on the grant.
function grantPending(result, host) {
  if (result.ok) return false;
  if (result.code === 'EHOSTUNREACH') return true;
  return /\.local\.?$/i.test(String(host)) && /^(ENOTFOUND|EAI_AGAIN|EAI_NONAME|EAI_NODATA)$/.test(result.code);
}

// ssh stderr that reads like a Local Network denial. "Undefined error: 0"
// is what some tools print for the same condition.
const looksDenied = (lines) => lines.some((l) => /No route to host|Undefined error: 0/.test(l));

module.exports = { HINT, PROBE_TIMEOUT, sshTarget, isLocalAddress, isLocalTarget, probe, grantPending, looksDenied };
