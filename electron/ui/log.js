/* Connection-event reporter for the served page.

   The page has no IPC bridge (a remote server must never reach main's
   profile store), so its side of the story — session sockets opening,
   dropping, and retrying — goes to main as POST /log on the page's own
   webmux:// origin, which the bundle's protocol handler answers (never the
   tunnel). Main tags each batch with the connection the origin belongs to
   and merges it into the client-wide log that the log window shows and the
   file on disk keeps. Loaded any other way (dev forward straight to the
   server) entries only reach the console. */

const CLIENT = location.protocol === 'webmux:';
const BATCH = 50;
const FLUSH_MS = 100;

const queue = [];
let timer = null;

function flush() {
  timer = null;
  const batch = queue.splice(0, BATCH);
  fetch('/log', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(batch),
    keepalive: true, // a batch queued right before a reload still lands
  }).catch(() => { /* the bundle handler is local; nothing to do if it's gone */ });
  if (queue.length) timer = setTimeout(flush, FLUSH_MS);
}

// log('info', 'socket open', { session }) — data is optional, shallow, and
// must hold nothing secret (it lands in a file).
export function log(level, msg, data) {
  const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.log;
  fn(`[webmux] ${msg}`, data ?? '');
  if (!CLIENT) return;
  queue.push({ level, msg, data });
  if (!timer) timer = setTimeout(flush, FLUSH_MS);
}

export const logDebug = (msg, data) => log('debug', msg, data);
export const logInfo = (msg, data) => log('info', msg, data);
export const logWarn = (msg, data) => log('warn', msg, data);
export const logError = (msg, data) => log('error', msg, data);

// Ask the client to open its log window. Resolves false outside the client
// (no window exists there — the console has the same lines).
export async function openLogWindow() {
  if (!CLIENT) return false;
  try {
    const res = await fetch('/log/open', { method: 'POST' });
    return res.ok;
  } catch {
    return false;
  }
}
