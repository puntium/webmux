// Client-side connection log: what the tunnel supervisor, the deploy steps,
// and the served pages say about connection setup, teardown, and recovery.
//
// Two sinks: a bounded in-memory ring that the log window (logs.html)
// renders and tails live, and an append-only file under <userData>/logs
// (rotated once, at LOG_FILE_MAX) for when the client itself is the thing
// being diagnosed. Entries are plain objects; the file gets one formatted
// line each. Nothing here may ever see a secret — callers log ssh argument
// lists (no passwords ride there; the saved one travels in the child's env)
// and never the spawn env.
const fs = require('fs');
const path = require('path');

const LEVELS = ['debug', 'info', 'warn', 'error'];
const MAX_ENTRIES = 3000; // ring size the log window can ask for
const LOG_FILE_MAX = 1024 * 1024; // bytes before webmux.log rolls to webmux.log.1
const MAX_MSG = 500; // page-supplied messages are clipped to this
const MAX_DATA_STRING = 300;

let dir = null;
let file = null;
let fileSize = 0;
let seq = 0;
const entries = [];
const listeners = new Set();

// Point the file sink at a directory (created if missing). Until called,
// entries only accumulate in memory — the harness runs that way.
function init(logDir) {
  dir = logDir;
  file = path.join(dir, 'webmux.log');
  try {
    fs.mkdirSync(dir, { recursive: true });
    fileSize = fs.statSync(file).size;
  } catch {
    fileSize = 0;
  }
}

const logFile = () => file;

// Small values inline as key=value; anything else is JSON. Strings with
// whitespace get quoted so the line stays parseable by eye.
function fmtValue(v) {
  if (v === undefined) return '-';
  if (typeof v === 'number' || typeof v === 'boolean' || v === null) return String(v);
  if (typeof v === 'string') return /^[\w./:@~-]+$/.test(v) ? v : JSON.stringify(v);
  try { return JSON.stringify(v); } catch { return String(v); }
}

function formatLine(e) {
  const data = e.data && Object.keys(e.data).length
    ? ' ' + Object.entries(e.data).map(([k, v]) => `${k}=${fmtValue(v)}`).join(' ')
    : '';
  const where = (e.conn ? `[${e.conn}] ` : '') + (e.src === 'page' ? 'page: ' : '');
  return `${e.t} ${e.level.toUpperCase().padEnd(5)} ${where}${e.msg}${data}`;
}

function appendFile(line) {
  if (!file) return;
  try {
    if (fileSize > LOG_FILE_MAX) {
      fs.renameSync(file, `${file}.1`);
      fileSize = 0;
    }
    const buf = line + '\n';
    fs.appendFileSync(file, buf);
    fileSize += Buffer.byteLength(buf);
  } catch {
    // A full or read-only disk must never take the client down; the ring
    // and the window still work.
  }
}

// Untrusted-ish input (the page reports over HTTP): keep only plain keys
// and clipped scalar/JSON values, bounded in number.
function sanitizeData(raw) {
  if (!raw || typeof raw !== 'object') return undefined;
  const out = {};
  for (const [k, v] of Object.entries(raw).slice(0, 12)) {
    if (!/^[A-Za-z_][\w]{0,31}$/.test(k)) continue;
    if (typeof v === 'string') out[k] = v.length > MAX_DATA_STRING ? v.slice(0, MAX_DATA_STRING) + '…' : v;
    else if (typeof v === 'number' || typeof v === 'boolean' || v === null) out[k] = v;
    else {
      let s;
      try { s = JSON.stringify(v); } catch { continue; }
      if (s !== undefined) out[k] = s.length > MAX_DATA_STRING ? s.slice(0, MAX_DATA_STRING) + '…' : s;
    }
  }
  return Object.keys(out).length ? out : undefined;
}

// The one write path. `conn` is the profile name (null for app-wide
// events); `src` is 'main' or 'page' (a served host page reporting in).
function push({ level, conn, msg, data, src = 'main', t }) {
  const entry = {
    seq: ++seq,
    t: t || new Date().toISOString(),
    level: LEVELS.includes(level) ? level : 'info',
    src: src === 'page' ? 'page' : 'main',
    conn: conn ? String(conn).slice(0, 80) : null,
    msg: String(msg ?? '').slice(0, MAX_MSG),
    data: sanitizeData(data),
  };
  entries.push(entry);
  if (entries.length > MAX_ENTRIES) entries.splice(0, entries.length - MAX_ENTRIES);
  appendFile(formatLine(entry));
  for (const fn of listeners) {
    try { fn(entry); } catch { /* a broken listener must not block logging */ }
  }
  return entry;
}

// log.info(conn, msg, data) etc. — conn may be null.
const byLevel = Object.fromEntries(LEVELS.map((level) => [
  level, (conn, msg, data) => push({ level, conn, msg, data }),
]));

// Entry plus its file-format line, for the log window (its copy buttons
// hand out exactly what the file holds).
const withLine = (e) => ({ ...e, line: formatLine(e) });

// Since a sequence number (exclusive), or everything the ring holds.
const since = (afterSeq = 0) => entries.filter((e) => e.seq > afterSeq).map(withLine);

function clear() {
  entries.length = 0;
  push({ level: 'info', conn: null, msg: 'log cleared (file untouched)' });
}

// Live subscription for the log window; returns an unsubscribe.
function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

// Everything currently in memory as the same text the file holds.
const text = (list = entries) => list.map(formatLine).join('\n');

module.exports = {
  init, logFile, push, since, clear, subscribe, formatLine, withLine, text,
  LEVELS, MAX_ENTRIES, LOG_FILE_MAX,
  ...byLevel,
};
