// webmux macOS client — an Electron shell around the existing web frontend,
// reaching the remote server through a supervised SSH tunnel.
//
// The whole app rides one forward: the page, /api/*, and /ws all go to
// http://127.0.0.1:<localPort>, which ssh forwards to the server's unix
// socket on the remote box ($XDG_RUNTIME_DIR/webmux/<name>.http.sock —
// filesystem perms there are the access control, sshd is the front door).
// The local port is chosen once per profile and reused across tunnel
// respawns, so the loaded page's own WebSocket-retry logic heals blips
// without a reload; sessions repaint from pty-host snapshots.
//
// Connection profiles are managed in connect.html (renderer, talking over
// the preload bridge) and stored in <userData>/config.json. The last-used
// profile auto-connects at launch.

const { app, BrowserWindow, Menu, shell, powerMonitor, ipcMain, safeStorage } = require('electron');
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
  localPort: 0, // 0 = pick a free port per app run
  extraOptions: '', // extra ssh args, whitespace-separated
  passwordEnc: '', // safeStorage ciphertext, base64; never leaves main
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

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// ---------------------------------------------------------------------------
// Tunnel supervision
// ---------------------------------------------------------------------------

let win = null;
let active = null; // profile currently connected/connecting, or null
let localPort = 0;
const portByProfile = new Map(); // ephemeral picks, stable within this app run
let tunnel = null; // ssh tunnel child process, or null
let discovery = null; // ssh socket-discovery child process, or null
let hadConnection = false; // this connect-cycle reached 'connected' at least once
let retryDelay = 0; // ms; 0 → immediate
let retryTimer = null;
let generation = 0; // invalidates poll loops / exit handlers of dead tunnels
let stderrTail = [];
let quitting = false;
let status = { state: 'idle' };

const appUrl = () => `http://127.0.0.1:${localPort}/`;
const onAppPage = () => Boolean(win) && win.webContents.getURL().startsWith(appUrl());
const onConnectPage = () => Boolean(win) && win.webContents.getURL().includes('connect.html');

function setStatus(s) {
  status = { profile: active ? active.name : null, stderr: stderrTail.join('\n'), ...s };
  if (win && onConnectPage()) win.webContents.send('status', status);
}

// Land on the connection page — unless a live terminal page is up (its own
// WS retry handles tunnel blips). `force` is for callers that know the page
// is dead: did-fail-load still reports the failed URL as current.
function showConnectPage(force = false) {
  if (!win || (onAppPage() && !force)) return;
  if (onConnectPage()) { setStatus(status); return; }
  win.loadFile('connect.html');
}

function stopTunnel() {
  generation++; // orphan any pending retry/poll/exit handling
  clearTimeout(retryTimer);
  retryTimer = null;
  if (discovery) { discovery.kill(); discovery = null; }
  if (tunnel) { tunnel.kill(); tunnel = null; }
}

async function connectProfile(profile) {
  stopTunnel();
  hadConnection = false; // a fresh manual attempt parks on failure, no retry loop
  active = profile;
  store.lastProfile = profile.name;
  saveStore();
  localPort = profile.localPort
    || portByProfile.get(profile.name)
    || await freePort();
  portByProfile.set(profile.name, localPort);
  retryDelay = 0;
  startTunnel();
}

function startTunnel() {
  if (quitting || tunnel || discovery) return;
  clearTimeout(retryTimer);
  retryTimer = null;
  if (!active) { showConnectPage(); return; }

  const gen = ++generation;
  stderrTail = [];

  let env = process.env;
  if (active.passwordEnc) {
    try {
      env = {
        ...process.env,
        SSH_ASKPASS: askpassFile(),
        SSH_ASKPASS_REQUIRE: 'force',
        WEBMUX_SSH_PASSWORD: safeStorage.decryptString(Buffer.from(active.passwordEnc, 'base64')),
      };
    } catch (err) {
      // Keychain refused (or ciphertext from another machine). Retrying
      // won't help — park in the retry state with no timer and let the
      // user re-enter the password in the profile.
      stderrTail = [String(err.message || err)];
      setStatus({ state: 'failed', msg: 'saved password could not be decrypted — edit the profile and re-enter it' });
      showConnectPage();
      return;
    }
  }

  setStatus({ state: 'connecting', msg: `ssh ${active.host}` });

  const rs = String(active.remoteSocket || '');
  if (rs.startsWith('/')) spawnTunnel(gen, env, rs); // explicit path — no discovery
  else discoverSocket(gen, env, rs || 'default');
}

// Read the server's advertised socket path over ssh before opening the
// tunnel: `cat .webmux/<name>.http.sock.path`, relying on sshd giving remote
// commands the home dir as cwd. Runs on every (re)connect attempt, so a
// server restarted onto a different path just works.
function discoverSocket(gen, env, name) {
  const child = spawn(
    'ssh',
    [...sshBaseArgs(active), active.host, `cat .webmux/${name}.http.sock.path`],
    { stdio: ['ignore', 'pipe', 'pipe'], env },
  );
  discovery = child;
  let out = '';

  child.stdout.on('data', (chunk) => { out += chunk; });
  child.stderr.on('data', (chunk) => {
    stderrTail = stderrTail.concat(String(chunk).split('\n')).filter(Boolean).slice(-8);
  });

  child.on('error', (err) => {
    // spawn failure (no ssh binary) — 'exit' won't always follow
    stderrTail.push(String(err.message || err));
    if (discovery === child) { discovery = null; onTunnelDown(gen); }
  });

  child.on('exit', (code, signal) => {
    if (discovery === child) discovery = null;
    if (quitting || gen !== generation) return;
    // Take the last absolute-path line so shell-profile noise on stdout
    // can't break discovery.
    const sockPath = out.split('\n').map((s) => s.trim()).filter((s) => s.startsWith('/')).pop();
    if (code === 0 && sockPath) return spawnTunnel(gen, env, sockPath);
    stderrTail.push(`could not read .webmux/${name}.http.sock.path — is webmux running on the host?`);
    onTunnelDown(gen, code ?? signal);
  });
}

function spawnTunnel(gen, env, remoteSock) {
  if (quitting || gen !== generation) return;
  const child = spawn('ssh', sshTunnelArgs(active, localPort, remoteSock), { stdio: ['ignore', 'ignore', 'pipe'], env });
  tunnel = child;

  child.stderr.on('data', (chunk) => {
    stderrTail = stderrTail.concat(String(chunk).split('\n')).filter(Boolean).slice(-8);
  });

  child.on('error', (err) => {
    // spawn failure (no ssh binary) — 'exit' won't always follow
    stderrTail.push(String(err.message || err));
    if (tunnel === child) { tunnel = null; onTunnelDown(gen); }
  });

  child.on('exit', (code, signal) => {
    if (tunnel === child) tunnel = null; // a newer tunnel may already exist
    if (quitting) return;
    onTunnelDown(gen, code ?? signal);
  });

  pollServer(gen);
}

// A dropped tunnel is handled two ways: if this connect-cycle was ever
// connected, an interrupted session is at stake — auto-retry until it's
// back (the terminal page, if up, stays up and self-heals when the port
// returns). A cycle that never connected (typo'd host, wrong password)
// parks in 'failed' instead of retry-looping, so the connection page stays
// quiet while the user edits profiles.
function onTunnelDown(gen, exitCode) {
  if (quitting || gen !== generation) return;
  if (hadConnection) return scheduleRetry(gen, exitCode);
  setStatus({
    state: 'failed',
    msg: exitCode !== undefined ? `ssh exited (${exitCode})` : 'connection failed',
  });
  showConnectPage();
}

function scheduleRetry(gen, exitCode) {
  if (quitting || gen !== generation || retryTimer) return;
  retryDelay = Math.min(Math.max(retryDelay * 2, 1000), 15000);
  setStatus({
    state: 'retry',
    msg: exitCode !== undefined ? `ssh exited (${exitCode})` : 'connection failed',
    delay: Math.round(retryDelay / 1000),
  });
  showConnectPage(); // no-op while the terminal page is live
  retryTimer = setTimeout(() => { retryTimer = null; startTunnel(); }, retryDelay);
}

// Poll through the tunnel until server.js answers, then land the app page.
function pollServer(gen) {
  if (quitting || gen !== generation || !tunnel) return;
  const req = http.get({ host: '127.0.0.1', port: localPort, path: '/', timeout: 2000 }, (res) => {
    res.resume();
    if (gen !== generation) return;
    retryDelay = 0; // healthy — next failure retries immediately
    hadConnection = true; // from here on, a drop is an interruption → auto-retry
    setStatus({ state: 'connected' });
    if (!onAppPage() && win) win.loadURL(appUrl());
  });
  req.on('timeout', () => req.destroy());
  req.on('error', () => setTimeout(() => pollServer(gen), 500));
}

function reconnectNow() {
  if (!active) { showConnectPage(); return; }
  const profile = findProfile(active.name) || active;
  connectProfile(profile);
}

// ---------------------------------------------------------------------------
// IPC (connect.html via preload bridge)
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
    if (originalName && originalName !== p.name) {
      if (store.lastProfile === originalName) store.lastProfile = p.name;
      if (active && active.name === originalName) active = p;
      portByProfile.delete(originalName);
    }
    saveStore();
    return { ok: true };
  });

  ipcMain.handle('profiles:delete', (_ev, name) => {
    store.profiles = store.profiles.filter((p) => p.name !== name);
    if (store.lastProfile === name) store.lastProfile = null;
    if (active && active.name === name) { stopTunnel(); active = null; setStatus({ state: 'idle' }); }
    saveStore();
    return { ok: true };
  });

  ipcMain.handle('profiles:connect', async (_ev, name) => {
    const profile = findProfile(name);
    if (!profile) return { error: 'no such profile' };
    // Same profile, healthy tunnel → just go back to the terminal page.
    if (active && active.name === name && tunnel) {
      if (win) win.loadURL(appUrl());
      return { ok: true };
    }
    await connectProfile(profile);
    return { ok: true };
  });

  ipcMain.handle('status:get', () => status);
}

// ---------------------------------------------------------------------------
// Window & app lifecycle
// ---------------------------------------------------------------------------

function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 900,
    backgroundColor: '#1e1e1e',
    title: 'webmux',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  // Terminal links open in the real browser; only the tunnel origin and the
  // local connection page may load in-window.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (ev, url) => {
    if (url.startsWith(appUrl()) || url.startsWith('file:')) return;
    ev.preventDefault();
    if (/^https?:/.test(url)) shell.openExternal(url);
  });

  // Cmd+R while the tunnel is down, or a load race: fall back to the
  // connection page instead of Chromium's error page. -3 is ERR_ABORTED.
  win.webContents.on('did-fail-load', (_ev, code, _desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3 || !url.startsWith('http')) return;
    showConnectPage(true);
    if (tunnel) pollServer(generation);
  });

  win.on('closed', () => { win = null; });
}

function buildMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: 'webmux',
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        { label: 'Connections…', accelerator: 'CmdOrCtrl+Shift+O', click: () => showConnectPage(true) },
        { label: 'Reconnect', accelerator: 'CmdOrCtrl+Shift+R', click: reconnectNow },
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
    { label: 'Window', submenu: [{ role: 'minimize' }, { role: 'zoom' }] },
  ]));
}

app.whenReady().then(() => {
  loadStore();
  ensureAskpass();
  registerIpc();
  buildMenu();
  createWindow();

  // Lid-open: the pre-sleep tunnel is dead but doesn't know it yet. Kill it
  // so reconnection starts now instead of after the keepalive timeout; the
  // exit handler decides what follows (auto-retry only if it was connected).
  powerMonitor.on('resume', () => {
    if (tunnel) { retryDelay = 0; tunnel.kill(); }
  });

  // Always start on the connection page — connecting is the user's call.
  showConnectPage();
});

app.on('window-all-closed', () => app.quit());

app.on('before-quit', () => {
  quitting = true;
  stopTunnel();
});
