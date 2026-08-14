// Headless test harness: stub the electron module, load main.js, drive the
// IPC handlers, and assert on the persisted store + status transitions.
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
const loads = [];

class FakeWebContents {
  getURL() { return this.url || ''; }
  send(ch, payload) { sent.push({ ch, payload }); }
  on() {}
  setWindowOpenHandler() {}
}
class FakeBrowserWindow {
  constructor() { this.webContents = new FakeWebContents(); FakeBrowserWindow.last = this; }
  loadFile(f) { loads.push(['file', f]); this.webContents.url = 'file://' + f; }
  loadURL(u) { loads.push(['url', u]); this.webContents.url = u; }
  on() {}
}

const stub = {
  app: {
    getPath: () => scratch,
    whenReady: () => Promise.resolve(),
    on: () => {},
  },
  BrowserWindow: FakeBrowserWindow,
  Menu: { setApplicationMenu: () => {}, buildFromTemplate: (t) => t },
  shell: { openExternal: () => {}, openPath: () => {} },
  powerMonitor: { on: () => {} },
  ipcMain: { handle: (ch, fn) => { handlers[ch] = fn; } },
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

(async () => {
  await sleep(50); // let whenReady handlers run

  // -- migration --------------------------------------------------------
  let r = await handlers['profiles:list']();
  assert.strictEqual(r.profiles.length, 1, 'migrated one profile');
  assert.strictEqual(r.profiles[0].name, 'me@oldbox');
  assert.strictEqual(r.profiles[0].remotePort, 5001);
  assert.strictEqual(r.profiles[0].extraOptions, '-o ProxyJump=bastion');
  assert.strictEqual(r.lastProfile, 'me@oldbox');
  console.log('migration ok');

  // migration set lastProfile → startup auto-connected → ssh to a real-ish
  // host name will fail (BatchMode) and schedule a retry; don't assert on
  // timing here, just that connect.html was landed first.
  assert.deepStrictEqual(loads[0], ['file', 'connect.html'], 'lands connect page first');

  // -- save / validation ------------------------------------------------
  r = await handlers['profiles:save'](null, { name: '', host: 'x' });
  assert.ok(r.error, 'rejects empty name');
  r = await handlers['profiles:save'](null, { name: 'dev', host: 'me@devbox', remotePort: '5000', sshPort: '2222' });
  assert.ok(r.ok);
  r = await handlers['profiles:save'](null, { name: 'me@oldbox', host: 'y' });
  assert.ok(r.error, 'rejects duplicate name');
  assert.strictEqual(readStore().profiles.length, 2);
  assert.strictEqual(readStore().profiles[1].sshPort, 2222, 'coerces ports to numbers');
  console.log('save/validation ok');

  // -- rename -----------------------------------------------------------
  r = await handlers['profiles:save'](null, { name: 'devbox', host: 'me@devbox', remotePort: 5000 }, 'dev');
  assert.ok(r.ok);
  assert.ok(readStore().profiles.some((p) => p.name === 'devbox'), 'renamed');
  assert.ok(!readStore().profiles.some((p) => p.name === 'dev'), 'old name gone');

  // rename the active (auto-connected) profile: lastProfile must follow
  r = await handlers['profiles:save'](null, { name: 'oldbox', host: 'me@oldbox', remotePort: 5001 }, 'me@oldbox');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, 'oldbox', 'lastProfile follows rename');
  console.log('rename ok');

  // -- passwords --------------------------------------------------------
  r = await handlers['profiles:save'](null, { name: 'pw', host: 'me@pwbox', remotePort: 5000, password: 's3cret' });
  assert.ok(r.ok);
  let stored = readStore().profiles.find((p) => p.name === 'pw');
  assert.strictEqual(Buffer.from(stored.passwordEnc, 'base64').toString(), 'ENC:s3cret', 'stored encrypted');
  r = await handlers['profiles:list']();
  let listed = r.profiles.find((p) => p.name === 'pw');
  assert.strictEqual(listed.hasPassword, true);
  assert.ok(!('passwordEnc' in listed), 'ciphertext never crosses the bridge');

  // blank password on edit keeps the stored one
  r = await handlers['profiles:save'](null, { name: 'pw', host: 'me@pwbox', remotePort: 5000, password: '' }, 'pw');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw');
  assert.strictEqual(Buffer.from(stored.passwordEnc, 'base64').toString(), 'ENC:s3cret', 'blank keeps password');

  // rename keeps it too
  r = await handlers['profiles:save'](null, { name: 'pw2', host: 'me@pwbox', remotePort: 5000 }, 'pw');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw2');
  assert.ok(stored.passwordEnc, 'rename keeps password');

  // clear flag removes it
  r = await handlers['profiles:save'](null, { name: 'pw2', host: 'me@pwbox', remotePort: 5000, clearPassword: true }, 'pw2');
  assert.ok(r.ok);
  stored = readStore().profiles.find((p) => p.name === 'pw2');
  assert.strictEqual(stored.passwordEnc, '', 'clear removes password');
  await handlers['profiles:delete'](null, 'pw2');

  console.log('passwords ok');

  // -- failed first connect parks (no auto-retry) -----------------------
  // (with a password, so the decrypt + askpass-env spawn path runs too)
  r = await handlers['profiles:save'](null, { name: 'bad', host: 'nobody@webmux-test.invalid', remotePort: 5000, password: 'pw' });
  assert.ok(r.ok);
  r = await handlers['profiles:connect'](null, 'bad');
  assert.ok(r.ok);
  assert.strictEqual(readStore().lastProfile, 'bad', 'connect updates lastProfile');
  let st = await handlers['status:get']();
  assert.strictEqual(st.state, 'connecting');
  assert.strictEqual(st.profile, 'bad');
  await sleep(2500); // ssh fails fast on .invalid
  st = await handlers['status:get']();
  assert.strictEqual(st.state, 'failed', `expected failed, got ${st.state}`);
  assert.ok(st.stderr.length, 'ssh stderr captured');
  await sleep(2000); // an auto-retry would flip state back to connecting
  st = await handlers['status:get']();
  assert.strictEqual(st.state, 'failed', 'no auto-retry after a never-connected failure');
  console.log('failed-parks ok  (stderr: ' + st.stderr.split('\n')[0] + ')');

  // -- delete active profile stops everything ---------------------------
  r = await handlers['profiles:delete'](null, 'bad');
  assert.ok(r.ok);
  st = await handlers['status:get']();
  assert.strictEqual(st.state, 'idle', 'delete of active profile → idle');
  assert.strictEqual(readStore().lastProfile, null);
  console.log('delete/stop ok');

  console.log('ALL PASS');
  process.exit(0);
})().catch((err) => { console.error(err); process.exit(1); });
