// Headless test harness: stub the electron module, load main.js, drive the
// IPC handlers, and assert on the persisted store + per-connection status
// transitions.
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const appDir = path.join(__dirname, '..');
process.env.WEBMUX_LAN_PROBE = '1'; // exercise the macOS Local Network probe + hint on any platform
process.env.WEBMUX_LAN_GRANT_WAIT_MS = '1500'; // nobody answers a prompt here
const scratch = path.join(os.tmpdir(), `webmux-client-test-${process.pid}`);
fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));

// Seed a legacy (pre-profiles) config to test migration.
fs.writeFileSync(path.join(scratch, 'config.json'), JSON.stringify({
  host: 'me@oldbox', remotePort: 5001, sshOptions: ['-o', 'ProxyJump=bastion'],
}));

const handlers = {};
const sent = [];
const revealed = [];
const loads = [];
let appScheme = null; // the webmux:// protocol handler
let willDownload = null; // main's will-download hook
let menu = null; // the application menu template main built
const focused = []; // every webContents.focus() call, in order

class FakeWebContents {
  constructor() { this.url = ''; }
  getURL() { return this.url; }
  focus() { focused.push(this); }
  isDestroyed() { return false; }
  loadFile(f) { loads.push(['file', f]); this.url = 'file://' + f; }
  loadURL(u) { loads.push(['url', u]); this.url = u; }
  send(ch, payload) { sent.push({ ch, payload }); }
  on() {}
  close() {}
  setWindowOpenHandler() {}
}
class FakeWebContentsView {
  constructor() { this.webContents = new FakeWebContents(); FakeWebContentsView.last = this; }
  setBounds() {}
  setVisible() {}
}
class FakeBaseWindow {
  constructor() {
    this.contentView = { addChildView: () => {}, removeChildView: () => {} };
    FakeBaseWindow.last = this;
  }
  getContentBounds() { return { x: 0, y: 0, width: 1400, height: 900 }; }
  setTitle(t) { this.title = t; }
  setBackgroundColor(c) { this.bg = c; }
  on() {}
}
// The log window: a plain BrowserWindow whose 'closed' handler we can fire.
class FakeBrowserWindow {
  constructor() {
    this.webContents = new FakeWebContents();
    this.webContents.isDestroyed = () => false;
    this.handlers = {};
    this.focused = 0;
    FakeBrowserWindow.last = this;
    FakeBrowserWindow.count = (FakeBrowserWindow.count || 0) + 1;
  }
  on(ev, fn) { this.handlers[ev] = fn; }
  focus() { this.focused++; }
  loadFile(f) { this.webContents.loadFile(f); }
  close() { this.handlers.closed?.(); }
}

const stub = {
  app: {
    getPath: () => scratch,
    getVersion: () => '0.0.0-test',
    whenReady: () => Promise.resolve(),
    on: () => {},
  },
  BaseWindow: FakeBaseWindow,
  BrowserWindow: FakeBrowserWindow,
  WebContentsView: FakeWebContentsView,
  Menu: { setApplicationMenu: () => {}, buildFromTemplate: (t) => { menu = t; return t; } },
  shell: { openExternal: () => {}, openPath: () => {}, showItemInFolder: (p) => { revealed.push(p); } },
  powerMonitor: { on: () => {} },
  session: { defaultSession: { on: (ev, fn) => { if (ev === 'will-download') willDownload = fn; } } },
  ipcMain: { handle: (ch, fn) => { handlers[ch] = fn; } },
  protocol: { registerSchemesAsPrivileged: () => {}, handle: (_scheme, fn) => { appScheme = fn; } },
  net: { fetch: () => Promise.reject(new Error('no net in tests')) },
  safeStorage: {
    isEncryptionAvailable: () => true,
    encryptString: (s) => Buffer.from('ENC:' + s),
    decryptString: (b) => {
      const s = b.toString();
      if (!s.startsWith('ENC:')) throw new Error('bad ciphertext');
      return s.slice(4);
    },
  },
};

const electronId = require.resolve('electron', { paths: [appDir] });
require.cache[electronId] = { id: electronId, filename: electronId, loaded: true, exports: stub };

require(path.join(appDir, 'main.js'));

const readStore = () => JSON.parse(fs.readFileSync(path.join(scratch, 'config.json'), 'utf8'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const connState = async (name) =>
  (await handlers['conns:get']()).connections.find((c) => c.name === name);

(async () => {
  await sleep(50); // let whenReady handlers run

  // -- migration --------------------------------------------------------
  let r = await handlers['profiles:list']();
  assert.strictEqual(r.profiles.length, 1, 'migrated one profile');
  assert.strictEqual(r.profiles[0].name, 'me@oldbox');
  // pre-unix-socket remotePort is dropped; blank instance = 'default'
  assert.ok(!('remotePort' in r.profiles[0]), 'legacy remotePort dropped');
  assert.ok(!('remoteSocket' in r.profiles[0]), 'legacy remoteSocket dropped');
  assert.strictEqual(r.profiles[0].instance, '', 'defaults to the default instance');
  assert.strictEqual(r.profiles[0].extraOptions, '-o ProxyJump=bastion');
  assert.strictEqual(r.lastProfile, 'me@oldbox');
  console.log('migration ok');

  // -- startup: local chrome loads, no auto-connect ----------------------
  assert.ok(loads.some(([kind, f]) => kind === 'file' && f === 'header.html'), 'header strip loaded');
  assert.ok(loads.some(([kind, f]) => kind === 'file' && f === 'connect.html'), 'connect page loaded');
  let snap = await handlers['conns:get']();
  assert.strictEqual(snap.active, null, 'starts on the connection page');
  assert.strictEqual(snap.connections.length, 0, 'no auto-connect at startup');

  // -- client-wide settings: /settings.json on the app scheme -------------
  const settingsReq = (method, body) => appScheme(new Request('webmux://host-abcd1234/settings.json', {
    method, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }));
  let res = await settingsReq('GET');
  assert.deepStrictEqual(await res.json(), { theme: 'dark', unfocusedFade: 40, minCols: 90, maxCols: 200 }, 'default settings');
  assert.deepStrictEqual(await handlers['settings:get'](), { theme: 'dark', unfocusedFade: 40, minCols: 90, maxCols: 200 }, 'IPC reads the same');
  sent.length = 0;
  res = await settingsReq('PUT', { theme: 'light', unfocusedFade: '72.4', minCols: '100', junk: 1 });
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 72, minCols: 100, maxCols: 200 }, 'PUT sanitizes and echoes');
  assert.deepStrictEqual(readStore().settings, { theme: 'light', unfocusedFade: 72, minCols: 100, maxCols: 200 }, 'settings persisted');
  assert.strictEqual(sent.filter((m) => m.ch === 'settings').length, 2, 'pushed to header + connect pages');
  assert.strictEqual(FakeBaseWindow.last.bg, '#dfe1e8', 'window background follows the theme');
  res = await settingsReq('PUT', { theme: 'Bad Theme!', unfocusedFade: 500, minCols: 5, maxCols: 900 });
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 100, minCols: 40, maxCols: 400 }, 'bad theme kept, fade and widths clamped');
  res = await settingsReq('PUT', { maxCols: 30 });
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 100, minCols: 40, maxCols: 40 }, 'maximum never below the minimum');
  res = await settingsReq('PUT', { minCols: 150 });
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 100, minCols: 150, maxCols: 150 }, 'raising the minimum lifts the maximum with it');
  res = await appScheme(new Request('webmux://host-abcd1234/settings.json', { method: 'PUT', body: '{nope' }));
  assert.strictEqual(res.status, 400, 'malformed body rejected');
  res = await settingsReq('POST', {});
  assert.strictEqual(res.status, 405, 'only GET/PUT');
  res = await settingsReq('PUT', { theme: 'dark', unfocusedFade: 40, minCols: 90, maxCols: 200 });
  assert.deepStrictEqual(readStore().settings, { theme: 'dark', unfocusedFade: 40, minCols: 90, maxCols: 200 });
  res = await appScheme(new Request('webmux://host-abcd1234/nope.js'));
  assert.strictEqual(res.status, 404, 'unknown paths still 404');
  console.log('settings ok');

  // -- save / validation ------------------------------------------------
  r = await handlers['profiles:save'](null, { name: '', host: 'x' });
  assert.ok(r.error, 'rejects empty name');
  r = await handlers['profiles:save'](null, { name: 'dev', host: 'me@devbox', instance: '  work ', sshPort: '2222' });
  assert.ok(r.ok);
  r = await handlers['profiles:save'](null, { name: 'me@oldbox', host: 'y' });
  assert.ok(r.error, 'rejects duplicate name');
  r = await handlers['profiles:save'](null, { name: 'inj', host: 'x', instance: 'name; rm -rf /' });
  assert.ok(r.error, 'rejects shell metacharacters in instance name');
  r = await handlers['profiles:save'](null, { name: 'inj', host: 'x', instance: '/abs/path.sock' });
  assert.ok(r.error, 'rejects a path as an instance name');
  assert.strictEqual(readStore().profiles.length, 2);
  assert.strictEqual(readStore().profiles[1].sshPort, 2222, 'coerces ports to numbers');
  assert.strictEqual(readStore().profiles[1].instance, 'work', 'trims instance name');
  console.log('save/validation ok');

  // -- rename -----------------------------------------------------------
  r = await handlers['profiles:save'](null, { name: 'devbox', host: 'me@devbox' }, 'dev');
  assert.ok(r.ok);
  assert.ok(readStore().profiles.some((p) => p.name === 'devbox'), 'renamed');
  assert.ok(!readStore().profiles.some((p) => p.name === 'dev'), 'old name gone');
  assert.strictEqual(readStore().profiles.find((p) => p.name === 'devbox').instance,
    '', 'blank instance stays blank (default)');
  console.log('rename ok');

  // -- passwords --------------------------------------------------------
  r = await handlers['profiles:save'](null, { name: 'pw', host: 'me@pwbox', password: 's3cret' });
  assert.ok(r.ok);
  let stored = readStore().profiles.find((p) => p.name === 'pw');
  assert.strictEqual(Buffer.from(stored.passwordEnc, 'base64').toString(), 'ENC:s3cret', 'stored encrypted');
  r = await handlers['profiles:list']();
  let listed = r.profiles.find((p) => p.name === 'pw');
  assert.strictEqual(listed.hasPassword, true);
  assert.ok(!('passwordEnc' in listed), 'ciphertext never crosses the bridge');

  // blank password on edit keeps the stored one
  r = await handlers['profiles:save'](null, { name: 'pw', host: 'me@pwbox', password: '' }, 'pw');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw');
  assert.strictEqual(Buffer.from(stored.passwordEnc, 'base64').toString(), 'ENC:s3cret', 'blank keeps password');

  // rename keeps it too
  r = await handlers['profiles:save'](null, { name: 'pw2', host: 'me@pwbox' }, 'pw');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw2');
  assert.ok(stored.passwordEnc, 'rename keeps password');

  // clear flag removes it
  r = await handlers['profiles:save'](null, { name: 'pw2', host: 'me@pwbox', clearPassword: true }, 'pw2');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw2');
  assert.strictEqual(stored.passwordEnc, '', 'clear removes password');
  await handlers['profiles:delete'](null, 'pw2');

  console.log('passwords ok');

  // -- failed first connect parks (no auto-retry) -----------------------
  // (with a password, so the decrypt + askpass-env spawn path runs too)
  r = await handlers['profiles:save'](null, { name: 'bad', host: 'nobody@webmux-test.invalid', password: 'pw' });
  assert.ok(r.ok);
  r = await handlers['profiles:connect'](null, 'bad');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, 'bad', 'connect updates lastProfile');
  let st = await connState('bad');
  assert.strictEqual(st.state, 'connecting');
  await sleep(2500); // ssh fails fast on .invalid
  st = await connState('bad');
  assert.strictEqual(st.state, 'failed', `expected failed, got ${st.state}`);
  assert.ok(st.stderr.length, 'ssh stderr captured');
  await sleep(2000); // an auto-retry would flip state back to connecting
  st = await connState('bad');
  assert.strictEqual(st.state, 'failed', 'no auto-retry after a never-connected failure');
  console.log('failed-parks ok  (stderr: ' + st.stderr.split('\n')[0] + ')');

  // -- downloads remember their folder per profile -------------------------
  // The 'bad' profile has a live (failed) connection with a view; a download
  // from that view's page seeds the save dialog with the profile's last
  // folder and records where the file actually landed.
  {
    const wc = FakeWebContentsView.last.webContents;
    const fakeItem = (savePath) => {
      const it = { opts: null, doneFn: null };
      it.getFilename = () => path.basename(savePath);
      it.getTotalBytes = () => 12;
      it.getSavePath = () => savePath;
      it.setSaveDialogOptions = (o) => { it.opts = o; };
      it.once = (ev, fn) => { if (ev === 'done') it.doneFn = fn; };
      return it;
    };
    assert.strictEqual(readStore().profiles.find((p) => p.name === 'bad').downloadDir, '', 'no folder remembered yet');
    const dlDir = path.join(scratch, 'downloads');
    fs.mkdirSync(dlDir, { recursive: true });
    let it = fakeItem(path.join(dlDir, 'a.txt'));
    willDownload(null, it, wc);
    assert.strictEqual(it.opts, null, 'first download: no default path');
    it.doneFn(null, 'completed');
    assert.strictEqual(readStore().profiles.find((p) => p.name === 'bad').downloadDir, dlDir, 'completed download records its folder');
    it = fakeItem(path.join(scratch, 'elsewhere', 'b.txt'));
    willDownload(null, it, wc);
    assert.deepStrictEqual(it.opts, { defaultPath: path.join(dlDir, 'b.txt') }, 'next download opens in the remembered folder');
    it.doneFn(null, 'cancelled');
    assert.strictEqual(readStore().profiles.find((p) => p.name === 'bad').downloadDir, dlDir, 'a cancelled download changes nothing');
    fs.rmSync(dlDir, { recursive: true });
    it = fakeItem(path.join(scratch, 'c.txt'));
    willDownload(null, it, wc);
    assert.strictEqual(it.opts, null, 'a remembered folder that no longer exists is not offered');
    // profiles:save from the connect form (which never sends downloadDir) keeps it
    r = await handlers['profiles:save'](null, { name: 'bad', host: 'nobody@webmux-test.invalid' }, 'bad');
    assert.ok(r.ok);
    assert.strictEqual(readStore().profiles.find((p) => p.name === 'bad').downloadDir, dlDir, 'editing the profile keeps the remembered folder');
    // a download from an unknown page (no connection) is logged but remembers nothing
    it = fakeItem(path.join(scratch, 'd.txt'));
    willDownload(null, it, new FakeWebContents());
    it.doneFn(null, 'completed');
    assert.strictEqual(readStore().profiles.find((p) => p.name === 'bad').downloadDir, dlDir, 'unattributed download leaves profiles alone');
    console.log('download-dir ok');
  }

  // -- connection log: main's own events ---------------------------------
  let lg = await handlers['log:get'](null, 0);
  assert.strictEqual(lg.file, path.join(scratch, 'logs', 'webmux.log'), 'log file lives under userData/logs');
  const msgs = (name) => lg.entries.filter((e) => e.conn === name).map((e) => e.msg);
  assert.ok(lg.entries[0].msg === 'client started' && lg.entries[0].conn === null, 'startup entry first');
  assert.ok(msgs('bad').some((m) => m === 'connect requested'), 'connect logged');
  assert.ok(msgs('bad').some((m) => /^state connecting → failed$/.test(m)), 'state transition logged');
  assert.ok(msgs('bad').some((m) => m === 'deploy failed'), 'deploy failure logged');
  const req = lg.entries.find((e) => e.conn === 'bad' && e.msg === 'connect requested');
  assert.strictEqual(req.data.auth, 'password', 'auth mode logged, never the password');
  assert.ok(!JSON.stringify(lg.entries).includes('"pw"'), 'password never appears in the log');
  assert.ok(lg.entries.every((e) => typeof e.line === 'string' && e.line.includes(e.msg)), 'entries carry their file line');
  const fileText = fs.readFileSync(lg.file, 'utf8');
  assert.ok(fileText.includes('[bad] state connecting → failed'), 'file mirrors the ring');
  assert.strictEqual(fileText.trim().split('\n').length, lg.entries.length, 'one file line per entry');

  // -- connection log: the page reports over POST /log on its origin -------
  // Use a live connection's own origin so the batch is tagged with its name.
  const crypto = require('crypto');
  const slugOf = (host, instance) => {
    const hash = crypto.createHash('sha256').update(`${host}\n${instance || 'default'}`).digest('hex').slice(0, 8);
    const base = host.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
    return `${base}-${hash}`;
  };
  const badOrigin = `webmux://${slugOf('nobody@webmux-test.invalid', '')}`;
  const before = lg.entries.length;
  res = await appScheme(new Request(`${badOrigin}/log`, {
    method: 'POST',
    body: JSON.stringify([
      { level: 'warn', msg: 'session socket dropped — retrying', data: { session: 's1', code: 1006, retryInMs: 1000, nested: { a: 1 } } },
      { level: 'bogus', msg: 'x'.repeat(2000), data: { 'bad key!': 1, ok: 'y' } },
      'not an object',
    ]),
  }));
  assert.strictEqual(res.status, 200, 'page log accepted');
  lg = await handlers['log:get'](null, 0);
  assert.strictEqual(lg.entries.length, before + 2, 'two well-formed entries taken, junk skipped');
  const pageEntry = lg.entries[before];
  assert.strictEqual(pageEntry.conn, 'bad', 'tagged with the connection owning that origin');
  assert.strictEqual(pageEntry.src, 'page');
  assert.strictEqual(pageEntry.level, 'warn');
  assert.strictEqual(pageEntry.data.nested, '{"a":1}', 'nested data flattened to JSON');
  assert.ok(pageEntry.line.includes('[bad] page: session socket dropped'), 'file line marks page origin');
  const clipped = lg.entries[before + 1];
  assert.strictEqual(clipped.level, 'info', 'unknown level falls back to info');
  assert.strictEqual(clipped.msg.length, 500, 'message clipped');
  assert.deepStrictEqual(Object.keys(clipped.data), ['ok'], 'bad data keys dropped');
  res = await appScheme(new Request('webmux://unknown-host/log', { method: 'POST', body: '[{"msg":"hi"}]' }));
  assert.strictEqual((await handlers['log:get'](null, 0)).entries.at(-1).conn, 'unknown-host', 'unknown origin keeps its slug');
  res = await appScheme(new Request(`${badOrigin}/log`, { method: 'GET' }));
  assert.strictEqual(res.status, 405, 'log is write-only for pages');
  res = await appScheme(new Request(`${badOrigin}/log`, { method: 'POST', body: '{nope' }));
  assert.strictEqual(res.status, 400, 'malformed batch rejected');

  // incremental fetch + log window lifecycle
  const afterSeq = lg.entries.at(-1).seq;
  res = await appScheme(new Request(`${badOrigin}/log/open`, { method: 'POST' }));
  assert.strictEqual(res.status, 200, 'page can ask for the log window');
  assert.strictEqual(FakeBrowserWindow.count, 1, 'log window created');
  assert.ok(loads.some(([kind, f]) => kind === 'file' && f === 'logs.html'), 'log window loads logs.html');
  await handlers['log:open']();
  assert.strictEqual(FakeBrowserWindow.count, 1, 'second open focuses the existing window');
  assert.strictEqual(FakeBrowserWindow.last.focused, 1);
  sent.length = 0;
  await settingsReq('PUT', { theme: 'light' });
  assert.ok(sent.some((m) => m.ch === 'settings'), 'log window gets settings pushes too');
  await handlers['conns:disconnect'](null, 'bad');
  const pushed = sent.filter((m) => m.ch === 'log').map((m) => m.payload);
  assert.ok(pushed.some((e) => e.conn === 'bad' && e.msg === 'disconnecting (user)' && e.line), 'live entries stream to the log window');
  lg = await handlers['log:get'](null, afterSeq);
  assert.ok(lg.entries.length > 0 && lg.entries.every((e) => e.seq > afterSeq), 'log:get is incremental');
  await handlers['log:reveal']();
  assert.deepStrictEqual(revealed, [lg.file], 'reveal shows the file');
  await handlers['log:clear']();
  lg = await handlers['log:get'](null, 0);
  assert.strictEqual(lg.entries.length, 1, 'clear empties the ring…');
  assert.ok(lg.entries[0].msg.startsWith('log cleared'), '…leaving a marker');
  assert.ok(fs.readFileSync(lg.file, 'utf8').includes('connect requested'), 'clear leaves the file alone');
  FakeBrowserWindow.last.close();
  await handlers['log:open']();
  assert.strictEqual(FakeBrowserWindow.count, 2, 'closing the window lets a new one open');
  FakeBrowserWindow.last.close();
  // reconnect the parked profile so the remaining tests see the same state as before
  r = await handlers['profiles:connect'](null, 'bad');
  await sleep(2500);
  console.log('log ok');

  // -- no port bookkeeping in the store ----------------------------------
  // The page's origin is the webmux:// host slug now, so the auto-picked
  // forward port is ephemeral: nothing persists it (legacy savedPort fields
  // are dropped on load).
  assert.ok(!('savedPort' in readStore().profiles.find((p) => p.name === 'bad')),
    'no savedPort persisted for an auto-picked port');
  r = await handlers['profiles:connect'](null, 'bad'); // retry the parked profile
  assert.ok(r.ok);
  await sleep(2500); // let the retried connect park again before moving on
  console.log('ephemeral-port ok');

  // -- concurrent connections are independent ----------------------------
  r = await handlers['profiles:save'](null, { name: 'bad2', host: 'nobody@webmux-test2.invalid' });
  assert.ok(r.ok);
  r = await handlers['profiles:connect'](null, 'bad2');
  assert.ok(r.ok);
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.connections.length, 2, 'two connections coexist');
  assert.strictEqual(FakeBaseWindow.last.title, 'webmux — 2 hosts · 0 panes',
    'window title summarizes hosts and panes');
  r = await handlers['conns:cmd'](null, 'new-terminal');
  assert.ok(r.error, 'chrome cmd without a live active page errors');
  assert.strictEqual((await connState('bad')).state, 'failed', 'first connection untouched by second');
  assert.strictEqual((await connState('bad2')).state, 'connecting');
  await sleep(2500);
  assert.strictEqual((await connState('bad2')).state, 'failed', 'second connection fails independently');

  // pills reorder in place: the snapshot (and so Cmd+<n>) follow the drag order
  r = await handlers['conns:reorder'](null, ['bad2', 'bad']);
  assert.ok(r.ok);
  snap = await handlers['conns:get']();
  assert.deepStrictEqual(snap.connections.map((c) => c.name), ['bad2', 'bad'], 'reorder moves the pill');
  r = await handlers['conns:reorder'](null, ['nope', 'bad', 'bad']);
  assert.ok(r.ok);
  snap = await handlers['conns:get']();
  assert.deepStrictEqual(snap.connections.map((c) => c.name), ['bad', 'bad2'],
    'unknown/duplicate names dropped; omitted connections keep their place at the end');
  assert.ok((await handlers['conns:reorder'](null, 'bad')).error, 'non-array order rejected');

  // switching views never touches tunnels; the revealed view takes the keys
  await handlers['conns:show'](null, 'bad');
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.active, 'bad', 'show switches the active view');
  assert.ok(!focused.at(-1).url.startsWith('file:'), 'show focuses the host page, not the chrome');
  await handlers['conns:show'](null, null);
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.active, null, 'show(null) returns to the connection page');
  assert.ok(focused.at(-1).url.endsWith('connect.html'), 'show(null) focuses the connection page');

  // ⌘⇧[ / ⌘⇧] walk the pill order and wrap; the connection page counts as
  // "before the first" going forward and "after the last" going back
  const menuItem = (label) => menu.flatMap((m) => m.submenu || []).find((i) => i.label === label);
  const active = async () => (await handlers['conns:get']()).active;
  menuItem('Next Host').click();
  assert.strictEqual(await active(), 'bad', 'next from the connection page → first host');
  menuItem('Next Host').click();
  assert.strictEqual(await active(), 'bad2', 'next → following pill');
  menuItem('Next Host').click();
  assert.strictEqual(await active(), 'bad', 'next wraps to the first pill');
  menuItem('Previous Host').click();
  assert.strictEqual(await active(), 'bad2', 'previous wraps to the last pill');
  await handlers['conns:show'](null, null);
  menuItem('Previous Host').click();
  assert.strictEqual(await active(), 'bad2', 'previous from the connection page → last host');
  await handlers['conns:show'](null, null);

  // disconnect removes just that connection
  await handlers['conns:disconnect'](null, 'bad2');
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.connections.length, 1, 'disconnect removes the connection');
  assert.strictEqual(snap.connections[0].name, 'bad');
  console.log('multi-connection ok');

  // -- rename of a live connection follows in the snapshot ---------------
  assert.strictEqual(readStore().lastProfile, 'bad2', 'lastProfile tracks most recent connect');
  r = await handlers['profiles:save'](null, { name: 'bad-renamed', host: 'nobody@webmux-test.invalid' }, 'bad');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, 'bad2', 'rename of another profile leaves lastProfile alone');
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.connections[0].name, 'bad-renamed', 'connection renamed in place');
  r = await handlers['profiles:save'](null, { name: 'bad2-renamed', host: 'nobody@webmux-test2.invalid' }, 'bad2');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, 'bad2-renamed', 'lastProfile follows rename');

  // -- restart sessions (remote pty-host shutdown over one-off ssh) ------
  r = await handlers['profiles:restart-sessions'](null, 'nope');
  assert.deepStrictEqual(r, { error: 'no such profile' });
  // Unresolvable host: the ssh spawn itself works, the connection fails, and
  // the failure surfaces as an error result instead of hanging or throwing.
  // (Shell-hostile instance names are already rejected at save time above.)
  r = await handlers['profiles:restart-sessions'](null, 'bad-renamed');
  assert.ok(r.error && /ssh exited/.test(r.error), `restart against a dead host errors (got ${JSON.stringify(r)})`);
  console.log('restart-sessions ok  (stderr above is the expected resolve failure)');

  // -- macOS Local Network denial: probe runs first, hint replaces the msg --
  // A `.local` host is a LAN target, so the pre-ssh probe from this process
  // runs. The probe itself is stubbed (main.js calls it through the module
  // object) to answer like a denied macOS socket — what the resolver on the
  // test box does with a .local name is beside the point — so the short
  // wait window elapses first. Then a fake ssh on PATH fails the same way:
  // instant "No route to host", exit 255. The failure surfaces as the Local
  // Network hint rather than a bare exit code, with ssh's own line kept in
  // the stderr tail; once the stubbed probe starts succeeding (the user
  // flipped the toggle), the parked connection reconnects on its own.
  {
    const lan = require(path.join(appDir, 'lan.js'));
    const realProbe = lan.probe;
    let probeResult = { ok: false, code: 'EHOSTUNREACH', ms: 12 };
    lan.probe = async () => probeResult;
    const fakeBin = path.join(scratch, 'fakebin');
    fs.mkdirSync(fakeBin, { recursive: true });
    fs.writeFileSync(path.join(fakeBin, 'ssh'),
      '#!/bin/sh\necho "ssh: connect to host webmux-test.local port 22: No route to host" >&2\nexit 255\n',
      { mode: 0o755 });
    const realPath = process.env.PATH;
    process.env.PATH = fakeBin + path.delimiter + realPath;
    r = await handlers['profiles:save'](null, { name: 'lan', host: 'me@webmux-test.local' });
    assert.ok(r.ok);
    r = await handlers['profiles:connect'](null, 'lan');
    assert.ok(r.ok);
    // The first probe's lookup of a .local name can take a few seconds on a
    // resolver without mDNS; watch the status until the wait message shows.
    const deadline = Date.now() + 12000;
    let sawWait = false;
    while (Date.now() < deadline) {
      st = await connState('lan');
      if (/waiting for macOS Local Network permission/.test(st.msg)) sawWait = true;
      if (st.state === 'failed') break;
      await sleep(50);
    }
    assert.ok(sawWait, `waits for the grant before spawning ssh (last: ${st.state} ${st.msg})`);
    process.env.PATH = realPath;
    st = await connState('lan');
    assert.strictEqual(st.state, 'failed', `expected failed, got ${st.state} (${st.msg})`);
    assert.strictEqual(st.msg, lan.HINT, `Local Network hint shown (got: ${st.msg})`);
    assert.ok(/No route to host/.test(st.stderr), 'ssh line kept in the tail');
    // Grant lands: the parked connection notices and starts a new attempt.
    probeResult = { ok: true, ms: 3 };
    const until = Date.now() + 6000;
    while ((await connState('lan')).state === 'failed' && Date.now() < until) await sleep(50);
    st = await connState('lan');
    assert.notStrictEqual(st.state, 'failed', 'reconnects by itself once the probe goes through');
    lan.probe = realProbe;
    await handlers['profiles:delete'](null, 'lan');
    console.log('local-network-hint ok');
  }

  // -- delete of a connected profile disconnects it ----------------------
  r = await handlers['profiles:delete'](null, 'bad-renamed');
  assert.ok(r.ok);
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.connections.length, 0, 'delete disconnects');
  r = await handlers['profiles:delete'](null, 'bad2-renamed');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, null);
  assert.strictEqual(FakeBaseWindow.last.title, 'webmux', 'title resets with no hosts');
  console.log('delete/stop ok');

  console.log('ALL PASS');
  process.exit(0);
})().catch((err) => { console.error(err); process.exit(1); });
