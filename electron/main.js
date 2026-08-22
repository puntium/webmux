// webmux macOS client — an Electron shell around the existing web frontend,
// reaching remote servers through supervised SSH tunnels.
//
// Multi-host: each connected profile gets its own supervised tunnel and its
// own WebContentsView; a thin client-owned header strip (header.html) shows
// one pill per connection and switches which view fills the window. The
// header lives outside the served pages on purpose — a remote server must
// never see the other profiles or drive switching.
//
// Per connection, the whole app rides one forward: the page, /api/*, and /ws
// all go to http://127.0.0.1:<localPort>, which ssh forwards to the server's
// unix socket on the remote box ($XDG_RUNTIME_DIR/webmux/<name>.http.sock —
// filesystem perms there are the access control, sshd is the front door).
// The local port is chosen once per profile and reused across tunnel
// respawns, so the loaded page's own WebSocket-retry logic heals blips
// without a reload; sessions repaint from pty-host snapshots.
//
// Connection profiles are managed in connect.html (renderer, talking over
// the preload bridge) and stored in <userData>/config.json.

const {
  app, BaseWindow, WebContentsView, Menu, shell, powerMonitor, ipcMain, safeStorage,
} = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');

// ---------------------------------------------------------------------------
// Profile store: <userData>/config.json
// ---------------------------------------------------------------------------

const PROFILE_DEFAULTS = {
  name: '',
  host: '', // anything ssh accepts, ~/.ssh/config aliases included
  sshPort: 0, // 0 = ssh default (22 / per ssh_config)
  identityFile: '', // optional -i path
  // Where server.js listens on the remote box. Blank (the default) means
  // auto-discover: the server advertises its socket path in
  // ~/.webmux/<name>.http.sock.path, which the client reads over ssh before
  // opening the tunnel. A bare name discovers that named instance; an
  // absolute path skips discovery (sshd expands no ~/$VARs, so it must be
  // absolute).
  remoteSocket: '',
  localPort: 0, // 0 = auto-pick (then sticky via savedPort)
  extraOptions: '', // extra ssh args, whitespace-separated
  passwordEnc: '', // safeStorage ciphertext, base64; never leaves main
  // The auto-picked local port, persisted so the profile keeps the same
  // origin (http://127.0.0.1:<port>) across app runs — the page's
  // localStorage (layout tree, file-browser state) is keyed by it. Reused
  // while free; silently re-picked if some other program grabbed it.
  savedPort: 0,
};

const configFile = () => path.join(app.getPath('userData'), 'config.json');

let store = { profiles: [], lastProfile: null };

function loadStore() {
  let raw = null;
  try {
    raw = JSON.parse(fs.readFileSync(configFile(), 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') console.error('config.json unreadable:', err.message);
  }
  if (raw && Array.isArray(raw.profiles)) {
    store = {
      // Drop the pre-unix-socket remotePort field; such profiles fall back
      // to the default remoteSocket and need a one-time edit if it differs.
      profiles: raw.profiles.map(({ remotePort, ...p }) => ({ ...PROFILE_DEFAULTS, ...p })),
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
}

function saveStore() {
  fs.mkdirSync(path.dirname(configFile()), { recursive: true });
  fs.writeFileSync(configFile(), JSON.stringify(store, null, 2) + '\n');
}

const findProfile = (name) => store.profiles.find((p) => p.name === name);

// ssh only reads passwords from a TTY or an askpass program. This helper
// echoes the env var that startTunnel decrypts the saved password into;
// SSH_ASKPASS_REQUIRE=force (OpenSSH ≥ 8.4) makes ssh use it headlessly.
// It also answers passphrase prompts for encrypted keys.
const askpassFile = () => path.join(app.getPath('userData'), 'askpass.sh');

function ensureAskpass() {
  fs.mkdirSync(path.dirname(askpassFile()), { recursive: true });
  fs.writeFileSync(askpassFile(), '#!/bin/sh\nprintf \'%s\' "$WEBMUX_SSH_PASSWORD"\n', { mode: 0o700 });
}

// Options shared by the tunnel and the discovery run: auth, endpoint, and
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
    '-o', 'ServerAliveInterval=15',
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

// The local forward port for a profile, sticky across app runs: a
// user-pinned localPort wins; otherwise reuse this run's pick, then the
// persisted savedPort (if still free — losing it to another program costs
// the origin-keyed layout, so prefer it), then a fresh free port.
async function pickPort(profile) {
  if (profile.localPort) return profile.localPort;
  const cached = portByProfile.get(profile.name);
  if (cached) return cached;
  if (profile.savedPort) {
    try { return await probePort(profile.savedPort); } catch { /* taken — re-pick */ }
  }
  return probePort(0);
}

// ---------------------------------------------------------------------------
// Window & views: header strip on top, one content view per connection plus
// the local connection-manager page, exactly one content view visible.
// ---------------------------------------------------------------------------

const HEADER_H = 38;

let win = null;
let headerView = null;
let connectView = null; // connect.html — profile manager + status detail
const conns = new Map(); // profile name -> connection; insertion order = pill order
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
  if (win) win.setTitle(activeName ? `webmux — ${activeName}` : 'webmux');
  layoutViews();
  broadcast();
}

function snapshot() {
  return {
    active: activeName,
    connections: [...conns.values()].map((c) => ({ name: c.name, ...c.status })),
  };
}

// Push connection states to the client-owned pages (header pills + connect
// page). Remote pages get nothing.
function broadcast() {
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

const appUrl = (conn) => `http://127.0.0.1:${conn.localPort}/`;
const pageLive = (conn) => conn.localPort > 0 && conn.view.webContents.getURL().startsWith(appUrl(conn));

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
    discovery: null, // ssh socket-discovery child process, or null
    hadConnection: false, // this connect-cycle reached 'connected' at least once
    reveal: false, // switch to this view when the server first answers
    retryDelay: 0, // ms; 0 → immediate
    retryTimer: null,
    generation: 0, // invalidates poll loops / exit handlers of dead tunnels
    stderrTail: [],
    status: { state: 'connecting' },
  };

  const wc = conn.view.webContents;
  // Only this connection's tunnel origin may load in-window.
  wc.on('will-navigate', (ev, url) => {
    if (url.startsWith(appUrl(conn))) return;
    ev.preventDefault();
    if (/^https?:/.test(url)) shell.openExternal(url);
  });
  // Cmd+R while the tunnel is down, or a load race: fall back to the
  // connection page instead of Chromium's error page. -3 is ERR_ABORTED.
  wc.on('did-fail-load', (_ev, code, _desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3 || !url.startsWith('http')) return;
    if (activeName === conn.name) show(null);
    if (conn.tunnel) pollServer(conn, conn.generation);
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
  // Persist the pick so the next app run lands on the same origin and finds
  // this profile's localStorage (layout tree, file-browser state) again.
  const stored = findProfile(conn.name);
  if (stored && !stored.localPort && stored.savedPort !== conn.localPort) {
    stored.savedPort = conn.localPort;
  }
  saveStore();
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

  const rs = String(conn.profile.remoteSocket || '');
  if (rs.startsWith('/')) spawnTunnel(conn, gen, env, rs); // explicit path — no discovery
  else discoverSocket(conn, gen, env, rs || 'default');
}

// Read the server's advertised socket path over ssh before opening the
// tunnel: `cat .webmux/<name>.http.sock.path`, relying on sshd giving remote
// commands the home dir as cwd. Runs on every (re)connect attempt, so a
// server restarted onto a different path just works.
function discoverSocket(conn, gen, env, name) {
  const child = spawn(
    'ssh',
    [...sshBaseArgs(conn.profile), conn.profile.host, `cat .webmux/${name}.http.sock.path`],
    { stdio: ['ignore', 'pipe', 'pipe'], env },
  );
  conn.discovery = child;
  let out = '';

  child.stdout.on('data', (chunk) => { out += chunk; });
  child.stderr.on('data', (chunk) => {
    conn.stderrTail = conn.stderrTail.concat(String(chunk).split('\n')).filter(Boolean).slice(-8);
  });

  child.on('error', (err) => {
    // spawn failure (no ssh binary) — 'exit' won't always follow
    conn.stderrTail.push(String(err.message || err));
    if (conn.discovery === child) { conn.discovery = null; onTunnelDown(conn, gen); }
  });

  child.on('exit', (code, signal) => {
    if (conn.discovery === child) conn.discovery = null;
    if (quitting || gen !== conn.generation) return;
    // Take the last absolute-path line so shell-profile noise on stdout
    // can't break discovery.
    const sockPath = out.split('\n').map((s) => s.trim()).filter((s) => s.startsWith('/')).pop();
    if (code === 0 && sockPath) return spawnTunnel(conn, gen, env, sockPath);
    conn.stderrTail.push(`could not read .webmux/${name}.http.sock.path — is webmux running on the host?`);
    onTunnelDown(conn, gen, code ?? signal);
  });
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

  pollServer(conn, gen);
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

// Poll through the tunnel until server.js answers, then load the app page
// into this connection's view (and reveal it if the user asked to connect).
function pollServer(conn, gen) {
  if (quitting || gen !== conn.generation || !conn.tunnel) return;
  const req = http.get({ host: '127.0.0.1', port: conn.localPort, path: '/', timeout: 2000 }, (res) => {
    res.resume();
    if (gen !== conn.generation) return;
    conn.retryDelay = 0; // healthy — next failure retries immediately
    conn.hadConnection = true; // from here on, a drop is an interruption → auto-retry
    setConnStatus(conn, { state: 'connected' });
    if (!pageLive(conn)) conn.view.webContents.loadURL(appUrl(conn));
    if (conn.reveal) { conn.reveal = false; show(conn.name); }
  });
  req.on('timeout', () => req.destroy());
  req.on('error', () => setTimeout(() => pollServer(conn, gen), 500));
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
    p.remoteSocket = String(p.remoteSocket || '').trim();
    // A bare instance name is interpolated into the remote discovery
    // command, so it must stay shell-inert.
    if (p.remoteSocket && !p.remoteSocket.startsWith('/') && !/^[A-Za-z0-9._-]+$/.test(p.remoteSocket)) {
      return { error: 'server socket must be blank (auto), an absolute path, or an instance name (letters, digits, . _ -)' };
    }
    p.sshPort = Number(p.sshPort) || 0;
    p.localPort = Number(p.localPort) || 0;
    if (!p.name || !p.host) return { error: 'name and host are required' };
    // Password: blank keeps what's stored, non-blank replaces it, and the
    // explicit clear flag removes it. Stored only as safeStorage ciphertext.
    const existing = findProfile(originalName || p.name);
    p.passwordEnc = clearPassword ? '' : (existing ? existing.passwordEnc : '');
    // savedPort is main's bookkeeping, not a form field — carry it through
    // edits so the profile keeps its origin (and thus its saved layout).
    p.savedPort = existing ? existing.savedPort : 0;
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
}

// ---------------------------------------------------------------------------
// Window & app lifecycle
// ---------------------------------------------------------------------------

function createWindow() {
  win = new BaseWindow({
    width: 1400,
    height: 900,
    backgroundColor: '#16161e',
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
