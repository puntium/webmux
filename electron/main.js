// webmux macOS client — an Electron shell around the existing web frontend,
// reaching remote servers through supervised SSH tunnels.
//
// Multi-host: each connected profile gets its own supervised tunnel and its
// own WebContentsView; a thin client-owned header strip (header.html) shows
// one pill per connection and switches which view fills the window. The
// header lives outside the served pages on purpose — a remote server must
// never see the other profiles or drive switching.
//
// Connecting IS deploying (electron/deploy.js): the client pushes a node
// runtime and the server payload to the host over ssh and (re)starts the
// server there — a host needs nothing but sshd, and there is no separate
// "server already running" mode.
//
// The frontend is served locally: each connection's view loads
// webmux://<host-slug>/?port=<localPort>, a custom scheme handled below that
// serves the UI (ui/ + the @xterm browser packages) straight from the app
// bundle. Only /api/* and /ws cross the wire, to http://127.0.0.1:<localPort>,
// which ssh forwards to the server's unix socket on the remote box
// ($XDG_RUNTIME_DIR/webmux/<name>.http.sock — filesystem perms there are the
// access control, sshd is the front door). The webmux:// origin is derived
// from the profile's host+instance, so the page's localStorage (layout tree,
// file-browser state) is keyed per host, not per forward port. The local
// port is stable within an app run, so the loaded page's own WebSocket-retry
// logic heals tunnel blips without a reload; sessions repaint from pty-host
// snapshots.
//
// Connection profiles are managed in connect.html (renderer, talking over
// the preload bridge) and stored in <userData>/config.json.

const {
  app, BaseWindow, WebContentsView, Menu, shell, powerMonitor, ipcMain, safeStorage,
  protocol, net: electronNet,
} = require('electron');
const { spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const { pathToFileURL } = require('url');
const { deploy } = require('./deploy');

// The app pages load on webmux:// (served from the bundle by the handler in
// app.whenReady). standard+secure gives the scheme real origins — per-host
// localStorage — and the secure-context APIs (navigator.clipboard) the page
// relies on. Must run before app ready.
protocol.registerSchemesAsPrivileged([
  { scheme: 'webmux', privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

// ---------------------------------------------------------------------------
// Profile store: <userData>/config.json
// ---------------------------------------------------------------------------

const PROFILE_DEFAULTS = {
  name: '',
  host: '', // anything ssh accepts, ~/.ssh/config aliases included
  sshPort: 0, // 0 = ssh default (22 / per ssh_config)
  identityFile: '', // optional -i path
  // Which webmux instance to run on the host (blank = 'default'). Connecting
  // always deploys: the client pushes a node runtime + the server payload
  // over ssh (kept current under ~/.webmux/dist) and (re)starts the server
  // there — the host needs nothing but sshd. Distinct instance names get
  // independent servers and session sets on the same host.
  instance: '',
  localPort: 0, // 0 = auto-pick per app run (the page's origin no longer depends on it)
  extraOptions: '', // extra ssh args, whitespace-separated
  passwordEnc: '', // safeStorage ciphertext, base64; never leaves main
};

const configFile = () => path.join(app.getPath('userData'), 'config.json');

let store = { profiles: [], lastProfile: null, settings: null }; // settings: see below

function loadStore() {
  let raw = null;
  try {
    raw = JSON.parse(fs.readFileSync(configFile(), 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') console.error('config.json unreadable:', err.message);
  }
  if (raw && Array.isArray(raw.profiles)) {
    store = {
      // Migrate older per-profile fields: remotePort (pre-unix-socket) is
      // dropped; a bare-name remoteSocket (pre-deploy-only discovery)
      // becomes the instance name, an absolute-path one has no deploy
      // equivalent and falls back to 'default'; autoDeploy is implied now;
      // savedPort (pre-webmux:// origins) no longer means anything.
      profiles: raw.profiles.map(({ remotePort, remoteSocket, autoDeploy, savedPort, ...p }) => ({
        ...PROFILE_DEFAULTS,
        instance: remoteSocket && !String(remoteSocket).startsWith('/') ? String(remoteSocket) : '',
        ...p,
      })),
      lastProfile: raw.lastProfile || null,
    };
  } else if (raw && raw.host) {
    // migrate the pre-profiles single-host config shape
    store = {
      profiles: [{
        ...PROFILE_DEFAULTS,
        name: raw.host,
        host: raw.host,
        localPort: raw.localPort || 0,
        extraOptions: Array.isArray(raw.sshOptions) ? raw.sshOptions.join(' ') : '',
      }],
      lastProfile: raw.host,
    };
    saveStore();
  } else {
    store = { profiles: [], lastProfile: null };
  }
  store.settings = sanitizeSettings(raw && raw.settings);
}

function saveStore() {
  fs.mkdirSync(path.dirname(configFile()), { recursive: true });
  fs.writeFileSync(configFile(), JSON.stringify(store, null, 2) + '\n');
}

const findProfile = (name) => store.profiles.find((p) => p.name === name);

// Client-wide UI settings, stored beside the profiles. Each host page is its
// own webmux:// origin, so its localStorage would make these per host; the
// pages read and write them at /settings.json on that origin instead (the
// bundle's protocol handler, registerAppScheme), and a change from any page
// fans out to every other one plus the header/connect chrome
// (broadcastSettings). Main only keeps the values well-formed — the theme
// list lives in the page (ui/settings.js), which falls back to dark for an
// id it doesn't know.
const SETTINGS_DEFAULTS = Object.freeze({ theme: 'dark', unfocusedFade: 40 });

function sanitizeSettings(raw, base = SETTINGS_DEFAULTS) {
  const s = { ...base };
  if (raw && typeof raw === 'object') {
    if (typeof raw.theme === 'string' && /^[a-z0-9-]{1,32}$/.test(raw.theme)) s.theme = raw.theme;
    const fade = Number(raw.unfocusedFade);
    if (Number.isFinite(fade)) s.unfocusedFade = Math.round(Math.min(100, Math.max(0, fade)));
  }
  return s;
}

// ssh only reads passwords from a TTY or an askpass program. This helper
// echoes the env var that startTunnel decrypts the saved password into;
// SSH_ASKPASS_REQUIRE=force (OpenSSH ≥ 8.4) makes ssh use it headlessly.
// It also answers passphrase prompts for encrypted keys.
const askpassFile = () => path.join(app.getPath('userData'), 'askpass.sh');

function ensureAskpass() {
  fs.mkdirSync(path.dirname(askpassFile()), { recursive: true });
  fs.writeFileSync(askpassFile(), '#!/bin/sh\nprintf \'%s\' "$WEBMUX_SSH_PASSWORD"\n', { mode: 0o700 });
}

// Options shared by the tunnel and the deploy steps: auth, endpoint, and
// timeouts, but no forwarding.
function sshBaseArgs(p) {
  return [
    // Key-only auth unless a password is saved: BatchMode forbids prompts,
    // which would otherwise hang a headless spawn. With a saved password the
    // askpass helper answers the one permitted prompt — one, so a wrong
    // password fails fast into the retry state instead of re-prompting.
    ...(p.passwordEnc
      ? ['-o', 'NumberOfPasswordPrompts=1']
      : ['-o', 'BatchMode=yes']),
    // Never ride a ControlMaster from ~/.ssh/config: a mux client ignores
    // the keepalive options below (the master owns the transport, usually
    // with none), so a dead link would go unnoticed for hours while the
    // tunnel child sits there looking alive.
    '-o', 'ControlMaster=no',
    '-o', 'ControlPath=none',
    // Dead-link detection bound: 10s × (2+1) ≈ 30s. The in-process server
    // probe (probeLoop) usually notices sooner.
    '-o', 'ServerAliveInterval=10',
    '-o', 'ServerAliveCountMax=2',
    '-o', 'ConnectTimeout=10',
    ...(p.sshPort ? ['-p', String(p.sshPort)] : []),
    ...(p.identityFile ? ['-i', p.identityFile] : []),
    ...String(p.extraOptions || '').split(/\s+/).filter(Boolean),
  ];
}

function sshTunnelArgs(p, localPort, remoteSock) {
  return [
    '-N',
    '-o', 'ExitOnForwardFailure=yes',
    ...sshBaseArgs(p),
    '-L', `127.0.0.1:${localPort}:${remoteSock}`,
    p.host,
  ];
}

// Bind-probe: resolves with the port if it could be bound (0 = any free
// port), rejects if it's taken.
function probePort(want) {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(want, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// The local forward port for a profile: a user-pinned localPort wins;
// otherwise reuse this run's pick (a stable port lets a loaded page's WS
// retry loop heal tunnel respawns), then any fresh free port. Nothing else
// depends on the number — the page's origin is the webmux:// host slug.
async function pickPort(profile) {
  if (profile.localPort) return profile.localPort;
  return portByProfile.get(profile.name) || probePort(0);
}

// ---------------------------------------------------------------------------
// Window & views: header strip on top, one content view per connection plus
// the local connection-manager page, exactly one content view visible.
// ---------------------------------------------------------------------------

const HEADER_H = 38;

let win = null;
let headerView = null;
let connectView = null; // connect.html — profile manager + status detail
const conns = new Map(); // profile name -> connection; insertion order = pill order (drag-reorderable)
let activeName = null; // name of the connection whose view is showing; null = connect page
const portByProfile = new Map(); // ephemeral picks, stable within this app run
let quitting = false;

function makeView() {
  const view = new WebContentsView({
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'), // bridge activates on file: pages only
      // Hidden hosts must keep ticking: their pages' WS-retry timers are what
      // make a background connection resume seamlessly.
      backgroundThrottling: false,
    },
  });
  // Terminal links open in the real browser; nothing may open in-window.
  view.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  return view;
}

function layoutViews() {
  if (!win) return;
  const { width, height } = win.getContentBounds();
  headerView.setBounds({ x: 0, y: 0, width, height: HEADER_H });
  const body = { x: 0, y: HEADER_H, width, height: Math.max(0, height - HEADER_H) };
  const activeView = (activeName && conns.get(activeName)?.view) || connectView;
  for (const view of [connectView, ...[...conns.values()].map((c) => c.view)]) {
    view.setVisible(view === activeView);
    if (view === activeView) view.setBounds(body);
  }
}

// Explicit navigation (pill click, menu, connect page) also cancels any
// pending reveal-on-connect: a host that finishes connecting later must not
// yank the view away from wherever the user just went.
function userShow(name) {
  for (const conn of conns.values()) conn.reveal = false;
  show(name);
}

// Switch the visible content view: a connection by name, or null for the
// connection-manager page.
function show(name) {
  activeName = name && conns.has(name) ? name : null;
  layoutViews();
  broadcast();
}

// The window title carries the fleet summary ("webmux — 2 hosts · 7 tabs");
// per-connection tab counts come from each page titling itself
// "webmux — N tabs" (see page-title-updated in createConnection).
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

function updateTitle() {
  if (!win) return;
  const tabs = [...conns.values()].reduce((n, c) => n + (c.tabCount || 0), 0);
  win.setTitle(conns.size
    ? `webmux — ${plural(conns.size, 'host')} · ${plural(tabs, 'tab')}`
    : 'webmux');
}

function snapshot() {
  return {
    active: activeName,
    // 'degraded': ssh is up and the server answered main's probes, but the
    // page says its sockets are down — the two views disagree, show that
    // rather than a green dot over a terminal saying "disconnected".
    connections: [...conns.values()].map((c) => ({
      name: c.name,
      ...c.status,
      state: c.status.state === 'connected' && c.pageOffline ? 'degraded' : c.status.state,
    })),
  };
}

// Push connection states to the client-owned pages (header pills + connect
// page). Remote pages get nothing.
function broadcast() {
  updateTitle(); // any conn change may move the host/tab totals
  for (const view of [headerView, connectView]) {
    if (view) view.webContents.send('conns', snapshot());
  }
}

function setConnStatus(conn, s) {
  conn.status = { stderr: conn.stderrTail.join('\n'), ...s };
  broadcast();
}

// ---------------------------------------------------------------------------
// Connections: one supervised tunnel + view per profile
// ---------------------------------------------------------------------------

// The page's origin: a slug of the profile's host+instance (plus a short
// hash so sanitization can't collide two hosts). Stable across profile
// renames and forward-port changes, so the layout localStorage keyed to it
// survives both.
function appOrigin(conn) {
  const { host, instance } = conn.profile;
  const hash = crypto.createHash('sha256')
    .update(`${host}\n${String(instance || '') || 'default'}`).digest('hex').slice(0, 8);
  const base = String(host).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  return `webmux://${base ? `${base}-${hash}` : hash}/`;
}

// The page URL carries the API endpoint; a changed port means the loaded
// page (if any) is talking to a dead forward and needs a reload.
const appUrl = (conn) => `${appOrigin(conn)}?port=${conn.localPort}`;
const pageLive = (conn) => conn.localPort > 0 && conn.view.webContents.getURL() === appUrl(conn);

// A connection whose page is up rides out tunnel blips in place (the page's
// own WS retry heals it). One whose page never loaded has nothing to show —
// if it is the one on screen, fall back to the connection page and its
// status detail.
function surfaceFailure(conn) {
  if (activeName === conn.name && !pageLive(conn)) show(null);
}

function createConnection(profile) {
  const conn = {
    name: profile.name,
    profile,
    view: makeView(),
    localPort: 0,
    tunnel: null, // ssh tunnel child process, or null
    discovery: null, // current deploy-step ssh child process, or null
    hadConnection: false, // this connect-cycle reached 'connected' at least once
    reveal: false, // switch to this view when the server first answers
    retryDelay: 0, // ms; 0 → immediate
    retryTimer: null,
    generation: 0, // invalidates probe loops / exit handlers of dead tunnels
    stderrTail: [],
    status: { state: 'connecting' },
    tabCount: 0, // parsed from the page's self-title, for the window title
    pageOffline: false, // the page reports its session sockets are down (title marker)
    pageBroken: false, // main-frame load failed; force a reload on the next probe hit
  };

  const wc = conn.view.webContents;
  // The served page titles itself "webmux — N tabs[ · offline]"; harvest
  // the count so the window title can total tabs across hosts, and the
  // offline marker — the page's own verdict on its session sockets, which
  // is the only channel it has to main (remote pages get no IPC bridge).
  // Anything unparseable (blank page, error page) counts as zero tabs.
  wc.on('page-title-updated', (_ev, title) => {
    conn.tabCount = Number(/(\d+) tab/.exec(title)?.[1]) || 0;
    const offline = /· offline$/.test(title);
    if (offline !== conn.pageOffline) {
      conn.pageOffline = offline;
      broadcast(); // pill/card flip between connected and degraded
    } else {
      updateTitle();
    }
  });
  // Only this connection's own webmux:// origin may load in-window.
  wc.on('will-navigate', (ev, url) => {
    if (url.startsWith(appOrigin(conn))) return;
    ev.preventDefault();
    if (/^https?:/.test(url)) shell.openExternal(url);
  });
  // Cmd+R while the page is broken, or a load race: fall back to the
  // connection page instead of Chromium's error page. -3 is ERR_ABORTED.
  wc.on('did-fail-load', (_ev, code, _desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3 || !url.startsWith('webmux:')) return;
    conn.pageBroken = true; // the probe loop reloads it once the server answers
    if (activeName === conn.name) show(null);
  });

  win.contentView.addChildView(conn.view);
  conn.view.setVisible(false);
  conns.set(conn.name, conn);
  return conn;
}

function stopTunnel(conn) {
  conn.generation++; // orphan any pending retry/poll/exit handling
  clearTimeout(conn.retryTimer);
  conn.retryTimer = null;
  if (conn.discovery) { conn.discovery.kill(); conn.discovery = null; }
  if (conn.tunnel) { conn.tunnel.kill(); conn.tunnel = null; }
}

function disconnect(name) {
  const conn = conns.get(name);
  if (!conn) return;
  stopTunnel(conn);
  conns.delete(name);
  if (win) win.contentView.removeChildView(conn.view);
  conn.view.webContents.close();
  if (activeName === name) show(null);
  else broadcast();
}

async function connectConn(conn) {
  stopTunnel(conn);
  conn.hadConnection = false; // a fresh manual attempt parks on failure, no retry loop
  store.lastProfile = conn.name;
  conn.localPort = await pickPort(conn.profile);
  portByProfile.set(conn.name, conn.localPort);
  saveStore(); // lastProfile
  conn.retryDelay = 0;
  startTunnel(conn);
}

function startTunnel(conn) {
  if (quitting || conn.tunnel || conn.discovery || !conns.has(conn.name)) return;
  clearTimeout(conn.retryTimer);
  conn.retryTimer = null;

  const gen = ++conn.generation;
  conn.stderrTail = [];

  let env = process.env;
  if (conn.profile.passwordEnc) {
    try {
      env = {
        ...process.env,
        SSH_ASKPASS: askpassFile(),
        SSH_ASKPASS_REQUIRE: 'force',
        WEBMUX_SSH_PASSWORD: safeStorage.decryptString(Buffer.from(conn.profile.passwordEnc, 'base64')),
      };
    } catch (err) {
      // Keychain refused (or ciphertext from another machine). Retrying
      // won't help — park in the failed state with no timer and let the
      // user re-enter the password in the profile.
      conn.stderrTail = [String(err.message || err)];
      setConnStatus(conn, { state: 'failed', msg: 'saved password could not be decrypted — edit the profile and re-enter it' });
      surfaceFailure(conn);
      return;
    }
  }

  setConnStatus(conn, { state: 'connecting', msg: `ssh ${conn.profile.host}` });

  runDeploy(conn, gen, env, String(conn.profile.instance || '') || 'default');
}

// Connecting IS deploying: push the node runtime + server payload to the
// host if it doesn't have this client's versions yet, (re)start the server
// there, then tunnel to the advertised socket. Runs on every (re)connect
// attempt — the already-current case costs two quick ssh round trips
// (probe + reuse). Cancellation rides the existing machinery: every ssh
// child parks in conn.discovery (stopTunnel kills it) and each step
// rechecks the generation.
async function runDeploy(conn, gen, env, instance) {
  const ctx = {
    spawnSsh: (command) => {
      const child = spawn(
        'ssh',
        [...sshBaseArgs(conn.profile), conn.profile.host, command],
        { stdio: ['pipe', 'pipe', 'pipe'], env },
      );
      conn.discovery = child;
      child.on('exit', () => { if (conn.discovery === child) conn.discovery = null; });
      return child;
    },
    status: (msg) => {
      if (!quitting && gen === conn.generation) setConnStatus(conn, { state: 'connecting', msg });
    },
    stderr: (line) => {
      conn.stderrTail = conn.stderrTail.concat(line).slice(-8);
    },
    isLive: () => !quitting && gen === conn.generation,
  };
  try {
    let manifest;
    try {
      manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'payload', 'payload.json'), 'utf8'));
    } catch {
      throw new Error('no server payload bundled — run `node deploy/build-payload.js` and restart the app');
    }
    const result = await deploy(ctx, {
      payloadTar: path.join(__dirname, 'payload', 'payload.tar.gz'),
      payloadHash: manifest.hash,
      instance,
      nodeCacheDir: path.join(app.getPath('userData'), 'node-cache'),
    });
    if (quitting || gen !== conn.generation) return;
    spawnTunnel(conn, gen, env, result.advert.socket);
  } catch (err) {
    if (err.cancelled || quitting || gen !== conn.generation) return;
    conn.stderrTail = conn.stderrTail.concat(String(err.message || err)).slice(-8);
    onTunnelDown(conn, gen);
  }
}

function spawnTunnel(conn, gen, env, remoteSock) {
  if (quitting || gen !== conn.generation) return;
  const child = spawn('ssh', sshTunnelArgs(conn.profile, conn.localPort, remoteSock), { stdio: ['ignore', 'ignore', 'pipe'], env });
  conn.tunnel = child;

  child.stderr.on('data', (chunk) => {
    conn.stderrTail = conn.stderrTail.concat(String(chunk).split('\n')).filter(Boolean).slice(-8);
  });

  child.on('error', (err) => {
    // spawn failure (no ssh binary) — 'exit' won't always follow
    conn.stderrTail.push(String(err.message || err));
    if (conn.tunnel === child) { conn.tunnel = null; onTunnelDown(conn, gen); }
  });

  child.on('exit', (code, signal) => {
    if (conn.tunnel === child) conn.tunnel = null; // a newer tunnel may already exist
    if (quitting) return;
    onTunnelDown(conn, gen, code ?? signal);
  });

  probeLoop(conn, gen, child);
}

// A dropped tunnel is handled two ways: if this connect-cycle was ever
// connected, an interrupted session is at stake — auto-retry until it's
// back (the page, if up, stays up and self-heals when the port returns). A
// cycle that never connected (typo'd host, wrong password) parks in 'failed'
// instead of retry-looping, so the user can edit profiles in peace.
function onTunnelDown(conn, gen, exitCode) {
  if (quitting || gen !== conn.generation) return;
  if (conn.hadConnection) return scheduleRetry(conn, gen, exitCode);
  setConnStatus(conn, {
    state: 'failed',
    msg: exitCode !== undefined ? `ssh exited (${exitCode})` : 'connection failed',
  });
  surfaceFailure(conn);
}

function scheduleRetry(conn, gen, exitCode) {
  if (quitting || gen !== conn.generation || conn.retryTimer) return;
  conn.retryDelay = Math.min(Math.max(conn.retryDelay * 2, 1000), 15000);
  setConnStatus(conn, {
    state: 'retry',
    msg: exitCode !== undefined ? `ssh exited (${exitCode})` : 'connection failed',
    delay: Math.round(conn.retryDelay / 1000),
  });
  surfaceFailure(conn); // no-op while this connection's page is live
  conn.retryTimer = setTimeout(() => { conn.retryTimer = null; startTunnel(conn); }, conn.retryDelay);
}

// Probe server.js through the tunnel for as long as this tunnel child lives:
// first to learn when the server is up (→ load the app page), then as a
// liveness check. `ssh -N` only knows about its own link — it stays alive,
// and looked "connected", while the remote server was dead or restarted, or
// while a half-open link waited out the keepalives. A local connect to the
// forward always succeeds (ssh accepts it), so a dead link shows up as a
// request timeout rather than a refusal; either way, enough consecutive
// misses kill the tunnel and let the ordinary exit → retry → redeploy path
// heal things (the remote starter restarts a dead server).
const PROBE_TIMEOUT = 2000; // ms per request
const PROBE_INTERVAL = 5000; // ms between probes once connected
const PROBE_RETRY = 500; // ms between probes before the server first answers
const PROBE_MISSES = 3; // consecutive misses while connected → tunnel is dead
const PROBE_FIRST_ANSWER = 20000; // ms for a fresh tunnel to reach the server at all

function probeLoop(conn, gen, child) {
  let misses = 0;
  const started = Date.now();
  const live = () => !quitting && gen === conn.generation && conn.tunnel === child;
  const giveUp = (why) => {
    conn.stderrTail = conn.stderrTail.concat(why).slice(-8);
    conn.retryDelay = 0; // a link we declared dead should be retried at once
    child.kill(); // 'exit' → onTunnelDown decides retry vs failed
  };
  const probe = () => {
    if (!live()) return;
    const req = http.get({ host: '127.0.0.1', port: conn.localPort, path: '/', timeout: PROBE_TIMEOUT }, (res) => {
      res.resume();
      if (!live()) return;
      misses = 0;
      onServerUp(conn);
      setTimeout(probe, PROBE_INTERVAL);
    });
    req.on('timeout', () => req.destroy());
    req.on('error', () => {
      if (!live()) return;
      if (conn.status.state !== 'connected') {
        // Not up yet. remote-start just verified the socket answers, so a
        // forward that never reaches it is broken (ssh's "connect failed"
        // lines land in stderrTail for the status detail).
        if (Date.now() - started > PROBE_FIRST_ANSWER) return giveUp('server did not answer through the tunnel');
        return setTimeout(probe, PROBE_RETRY);
      }
      if (++misses >= PROBE_MISSES) return giveUp('server unreachable through the tunnel — reconnecting');
      setTimeout(probe, PROBE_INTERVAL);
    });
  };
  probe();
}

// A probe got through: mark the connection healthy (only broadcasting on an
// actual change — this runs every few seconds), load the app page into the
// view if it isn't there, and reveal it if the user asked to connect.
function onServerUp(conn) {
  conn.retryDelay = 0; // healthy — next failure retries immediately
  conn.hadConnection = true; // from here on, a drop is an interruption → auto-retry
  if (conn.status.state !== 'connected') setConnStatus(conn, { state: 'connected' });
  if (conn.pageBroken || !pageLive(conn)) {
    conn.pageBroken = false;
    conn.view.webContents.loadURL(appUrl(conn));
  }
  if (conn.reveal) { conn.reveal = false; show(conn.name); }
}

function reconnectActive() {
  const conn = activeName && conns.get(activeName);
  if (!conn) { show(null); return; }
  conn.profile = findProfile(conn.name) || conn.profile;
  connectConn(conn);
}

// ---------------------------------------------------------------------------
// IPC (header.html and connect.html via preload bridge)
// ---------------------------------------------------------------------------

function registerIpc() {
  // Ciphertext never crosses the bridge — the renderer sees hasPassword only.
  ipcMain.handle('profiles:list', () => ({
    profiles: store.profiles.map(({ passwordEnc, ...p }) => ({ ...p, hasPassword: Boolean(passwordEnc) })),
    lastProfile: store.lastProfile,
    file: configFile(),
  }));

  ipcMain.handle('profiles:save', (_ev, profile, originalName) => {
    const { password, clearPassword, ...fields } = profile;
    const p = { ...PROFILE_DEFAULTS, ...fields };
    p.name = String(p.name || '').trim();
    p.host = String(p.host || '').trim();
    p.instance = String(p.instance || '').trim();
    // The instance name is interpolated into remote shell commands, so it
    // must stay shell-inert.
    if (p.instance && !/^[A-Za-z0-9._-]+$/.test(p.instance)) {
      return { error: 'instance name must be blank (default) or letters, digits, . _ -' };
    }
    p.sshPort = Number(p.sshPort) || 0;
    p.localPort = Number(p.localPort) || 0;
    if (!p.name || !p.host) return { error: 'name and host are required' };
    // Password: blank keeps what's stored, non-blank replaces it, and the
    // explicit clear flag removes it. Stored only as safeStorage ciphertext.
    const existing = findProfile(originalName || p.name);
    p.passwordEnc = clearPassword ? '' : (existing ? existing.passwordEnc : '');
    if (password) {
      if (!safeStorage.isEncryptionAvailable()) {
        return { error: 'OS keychain encryption is unavailable — cannot store a password' };
      }
      p.passwordEnc = safeStorage.encryptString(String(password)).toString('base64');
    }
    if (p.name !== originalName && findProfile(p.name)) {
      return { error: `a profile named "${p.name}" already exists` };
    }
    const idx = store.profiles.findIndex((x) => x.name === (originalName || p.name));
    if (idx >= 0) store.profiles[idx] = p;
    else store.profiles.push(p);
    // A live connection for this profile keeps its current tunnel; the new
    // fields take effect on the next (re)connect.
    const conn = conns.get(originalName || p.name);
    if (conn) conn.profile = p;
    if (originalName && originalName !== p.name) {
      if (store.lastProfile === originalName) store.lastProfile = p.name;
      portByProfile.delete(originalName);
      if (conn) {
        conn.name = p.name;
        // Rebuild the map in place so the pill keeps its position (and its
        // Cmd+<n> shortcut) across a rename.
        const renamed = [...conns.entries()]
          .map(([k, v]) => [k === originalName ? p.name : k, v]);
        conns.clear();
        for (const [k, v] of renamed) conns.set(k, v);
        if (conn.localPort) portByProfile.set(p.name, conn.localPort);
        if (activeName === originalName) activeName = p.name;
        broadcast();
      }
    }
    saveStore();
    return { ok: true };
  });

  ipcMain.handle('profiles:delete', (_ev, name) => {
    store.profiles = store.profiles.filter((p) => p.name !== name);
    if (store.lastProfile === name) store.lastProfile = null;
    disconnect(name); // no-op if not connected
    saveStore();
    return { ok: true };
  });

  ipcMain.handle('profiles:connect', async (_ev, name) => {
    const profile = findProfile(name);
    if (!profile) return { error: 'no such profile' };
    const existing = conns.get(name);
    // Already connected and healthy → just switch to its view.
    if (existing && existing.tunnel && existing.status.state === 'connected') {
      show(name);
      return { ok: true };
    }
    const conn = existing || createConnection(profile);
    conn.profile = profile;
    conn.reveal = true;
    await connectConn(conn);
    return { ok: true };
  });

  ipcMain.handle('conns:get', () => snapshot());
  ipcMain.handle('conns:show', (_ev, name) => { userShow(name); return { ok: true }; });
  ipcMain.handle('conns:disconnect', (_ev, name) => { disconnect(name); return { ok: true }; });

  // Pills are drag-reorderable; the Map's insertion order is the pill order
  // (and the Cmd+<n> order), so rebuild it in the requested sequence. Names
  // the header doesn't know about (a connect racing the drop) keep their
  // relative order at the end.
  ipcMain.handle('conns:reorder', (_ev, names) => {
    if (!Array.isArray(names)) return { error: 'bad order' };
    const ordered = names.filter((n, i) => conns.has(n) && names.indexOf(n) === i);
    for (const n of conns.keys()) if (!ordered.includes(n)) ordered.push(n);
    const entries = ordered.map((n) => [n, conns.get(n)]);
    conns.clear();
    for (const [k, v] of entries) conns.set(k, v);
    broadcast();
    return { ok: true };
  });

  ipcMain.handle('conns:cmd', (_ev, cmd) => chromeCmd(cmd));

  ipcMain.handle('settings:get', () => store.settings);
}

// Header-strip and menu actions relayed into the visible host page as DOM
// events (app.js listens for each).
const CHROME_EVENTS = {
  'new-terminal': 'webmux-new-terminal',
  'new-files': 'webmux-new-files',
  settings: 'webmux-settings-open', // the settings panel is drawn by the page
};
function chromeCmd(cmd) {
  const event = CHROME_EVENTS[cmd];
  const conn = activeName && conns.get(activeName);
  if (!event || !conn || !pageLive(conn)) return { error: 'no active page' };
  conn.view.webContents
    .executeJavaScript(`window.dispatchEvent(new Event(${JSON.stringify(event)}))`)
    .catch(() => {});
  return { ok: true };
}

// ---------------------------------------------------------------------------
// webmux:// — the app frontend, served straight from the bundle. Each
// connection loads webmux://<host-slug>/?port=<localPort>; only API and WS
// traffic touches the tunnel. Every host slug shares this one handler — the
// URL's host part exists purely to give each remote host its own origin
// (and thus its own localStorage).
// ---------------------------------------------------------------------------

const UI_DIR = path.join(__dirname, 'ui');
const VENDOR_DIRS = {
  xterm: path.join(__dirname, 'node_modules', '@xterm', 'xterm'),
  'addon-fit': path.join(__dirname, 'node_modules', '@xterm', 'addon-fit'),
  'addon-web-links': path.join(__dirname, 'node_modules', '@xterm', 'addon-web-links'),
  marked: path.join(__dirname, 'node_modules', 'marked'), // file-browser markdown preview
};

// URL path -> file inside the bundle, or null (404). Vendor paths map into
// the client's own npm packages (@xterm, marked); everything else comes
// from ui/.
function uiFile(pathname) {
  let root = UI_DIR;
  let rel = decodeURIComponent(pathname);
  const vendor = /^\/vendor\/([^/]+)(\/.+)$/.exec(rel);
  if (vendor) {
    root = VENDOR_DIRS[vendor[1]];
    if (!root) return null;
    rel = vendor[2];
  }
  if (rel === '/') rel = '/index.html';
  const file = path.normalize(path.join(root, rel));
  return file.startsWith(root + path.sep) ? file : null; // no escaping the root
}

// The window's own background shows through while views resize; keep it
// on the theme so a light page doesn't flash dark edges.
const WINDOW_BG = { light: '#dfe1e8' };
const windowBg = () => WINDOW_BG[store.settings.theme] || '#16161e';

const jsonResponse = (obj, status = 200) => new Response(JSON.stringify(obj), {
  status,
  headers: { 'Content-Type': 'application/json' },
});

// Push the current settings everywhere they render: the local chrome over
// IPC, and each live host page as a DOM event — those pages have no bridge,
// so injection is the only way in, and this direction (client into page)
// exposes nothing to the server. The page that made the change already
// applied it; re-applying is idempotent.
function broadcastSettings() {
  const s = store.settings;
  if (win) win.setBackgroundColor(windowBg());
  for (const view of [headerView, connectView]) {
    if (view) view.webContents.send('settings', s);
  }
  const js = `window.dispatchEvent(new CustomEvent('webmux-settings', { detail: ${JSON.stringify(s)} }))`;
  for (const conn of conns.values()) {
    if (pageLive(conn)) conn.view.webContents.executeJavaScript(js).catch(() => {});
  }
}

// /settings.json on any webmux:// origin: GET reads, PUT merges (unknown or
// malformed fields keep their current value), saves, and fans out.
async function handleSettingsRequest(req) {
  if (req.method === 'GET') return jsonResponse(store.settings);
  if (req.method !== 'PUT') return new Response('method not allowed', { status: 405 });
  let body;
  try { body = await req.json(); } catch { return new Response('bad json', { status: 400 }); }
  store.settings = sanitizeSettings(body, store.settings);
  saveStore();
  broadcastSettings();
  return jsonResponse(store.settings);
}

function registerAppScheme() {
  protocol.handle('webmux', (req) => {
    const { pathname } = new URL(req.url);
    if (pathname === '/settings.json') return handleSettingsRequest(req);
    const file = uiFile(pathname);
    if (!file) return new Response('not found', { status: 404 });
    // net.fetch on a file: URL supplies mime types (and reads inside asar);
    // it rejects on a missing file rather than returning a status.
    return electronNet.fetch(pathToFileURL(file).toString())
      .catch(() => new Response('not found', { status: 404 }));
  });
}

// ---------------------------------------------------------------------------
// Window & app lifecycle
// ---------------------------------------------------------------------------

function createWindow() {
  win = new BaseWindow({
    width: 1400,
    height: 900,
    backgroundColor: windowBg(),
    title: 'webmux',
  });

  headerView = makeView();
  connectView = makeView();
  // The local pages never navigate anywhere; external links (none today)
  // would go to the real browser.
  for (const view of [headerView, connectView]) {
    view.webContents.on('will-navigate', (ev, url) => {
      if (url.startsWith('file:')) return;
      ev.preventDefault();
      if (/^https?:/.test(url)) shell.openExternal(url);
    });
  }
  win.contentView.addChildView(connectView);
  win.contentView.addChildView(headerView);
  headerView.webContents.loadFile('header.html');
  connectView.webContents.loadFile('connect.html');

  win.on('resize', layoutViews);
  win.on('closed', () => { win = null; });
  layoutViews();
}

function buildMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: 'webmux',
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { label: 'Connections…', accelerator: 'CmdOrCtrl+Shift+O', click: () => userShow(null) },
        { label: 'Reconnect', accelerator: 'CmdOrCtrl+Shift+R', click: reconnectActive },
        { label: 'Open Config File', click: () => shell.openPath(configFile()) },
        { type: 'separator' },
        // Opens the page's settings panel; needs a host page on screen.
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: () => chromeCmd('settings') },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    { role: 'editMenu' }, // Cmd+C/V/X/A clipboard roles
    {
      label: 'View',
      submenu: [
        { role: 'reload' }, // harmless: repaints from pty-host snapshots
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    // Deliberately no windowMenu role: it carries Cmd+W (close), which is
    // muscle-memory fatal while typing in a terminal.
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        { type: 'separator' },
        // Cmd+1..9 jump between connected hosts in pill order.
        ...Array.from({ length: 9 }, (_, i) => ({
          label: `Host ${i + 1}`,
          accelerator: `CmdOrCtrl+${i + 1}`,
          click: () => {
            const name = [...conns.keys()][i];
            if (name) userShow(name);
          },
        })),
      ],
    },
  ]));
}

app.whenReady().then(() => {
  loadStore();
  ensureAskpass();
  registerAppScheme();
  registerIpc();
  buildMenu();
  createWindow();

  // Lid-open: pre-sleep tunnels are dead but don't know it yet. Kill them
  // so reconnection starts now instead of after the keepalive timeout; the
  // exit handlers decide what follows (auto-retry only if ever connected).
  powerMonitor.on('resume', () => {
    for (const conn of conns.values()) {
      if (conn.tunnel) { conn.retryDelay = 0; conn.tunnel.kill(); }
    }
  });

  // Always start on the connection page — connecting is the user's call.
  show(null);
});

app.on('window-all-closed', () => app.quit());

app.on('before-quit', () => {
  quitting = true;
  for (const conn of conns.values()) stopTunnel(conn);
});
