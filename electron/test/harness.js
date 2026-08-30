// Headless test harness: stub the electron module, load main.js, drive the
// IPC handlers, and assert on the persisted store + per-connection status
// transitions.
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const appDir = path.join(__dirname, '..');
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

class FakeWebContents {
  constructor() { this.url = ''; }
  getURL() { return this.url; }
  loadFile(f) { loads.push(['file', f]); this.url = 'file://' + f; }
  loadURL(u) { loads.push(['url', u]); this.url = u; }
  send(ch, payload) { sent.push({ ch, payload }); }
  on() {}
  close() {}
  setWindowOpenHandler() {}
}
class FakeWebContentsView {
  constructor() { this.webContents = new FakeWebContents(); }
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
  Menu: { setApplicationMenu: () => {}, buildFromTemplate: (t) => t },
  shell: { openExternal: () => {}, openPath: () => {}, showItemInFolder: (p) => { revealed.push(p); } },
  powerMonitor: { on: () => {} },
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
  assert.deepStrictEqual(await res.json(), { theme: 'dark', unfocusedFade: 40 }, 'default settings');
  assert.deepStrictEqual(await handlers['settings:get'](), { theme: 'dark', unfocusedFade: 40 }, 'IPC reads the same');
  sent.length = 0;
  res = await settingsReq('PUT', { theme: 'light', unfocusedFade: '72.4', junk: 1 });
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 72 }, 'PUT sanitizes and echoes');
  assert.deepStrictEqual(readStore().settings, { theme: 'light', unfocusedFade: 72 }, 'settings persisted');
  assert.strictEqual(sent.filter((m) => m.ch === 'settings').length, 2, 'pushed to header + connect pages');
  assert.strictEqual(FakeBaseWindow.last.bg, '#dfe1e8', 'window background follows the theme');
  res = await settingsReq('PUT', { theme: 'Bad Theme!', unfocusedFade: 500 });
  assert.deepStrictEqual(await res.json(), { theme: 'light', unfocusedFade: 100 }, 'bad theme kept, fade clamped');
  res = await appScheme(new Request('webmux://host-abcd1234/settings.json', { method: 'PUT', body: '{nope' }));
  assert.strictEqual(res.status, 400, 'malformed body rejected');
  res = await settingsReq('POST', {});
  assert.strictEqual(res.status, 405, 'only GET/PUT');
  res = await settingsReq('PUT', { theme: 'dark', unfocusedFade: 40 });
  assert.deepStrictEqual(readStore().settings, { theme: 'dark', unfocusedFade: 40 });
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
  assert.strictEqual(FakeBaseWindow.last.title, 'webmux — 2 hosts · 0 tabs',
    'window title summarizes hosts and tabs');
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

  // switching views never touches tunnels
  await handlers['conns:show'](null, 'bad');
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.active, 'bad', 'show switches the active view');
  await handlers['conns:show'](null, null);
  snap = await handlers['conns:get']();
  assert.strictEqual(snap.active, null, 'show(null) returns to the connection page');

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
