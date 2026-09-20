// Unit tests for electron/lan.js: target parsing, the local-address
// classifier, the pre-ssh probe, and the denial signature. Network-free
// except for a loopback listener and one lookup of `localhost`.
const assert = require('assert');
const net = require('net');
const lan = require('../lan');

(async () => {
  // -- sshTarget ----------------------------------------------------------
  assert.deepStrictEqual(lan.sshTarget({ host: 'user@bento.local' }), { host: 'bento.local', port: 22 });
  assert.deepStrictEqual(lan.sshTarget({ host: '192.168.11.20', sshPort: '2222' }), { host: '192.168.11.20', port: 2222 });
  assert.deepStrictEqual(lan.sshTarget({ host: ' me@box ' }), { host: 'box', port: 22 });
  assert.strictEqual(lan.sshTarget({ host: 'me@box', extraOptions: '-o ProxyJump=bastion' }), null, 'ProxyJump: the jump host is the hop');
  assert.strictEqual(lan.sshTarget({ host: 'me@box', extraOptions: '-J bastion' }), null);
  assert.strictEqual(lan.sshTarget({ host: '' }), null);
  assert.strictEqual(lan.sshTarget({ host: 'me@' }), null);
  console.log('sshTarget ok');

  // -- isLocalAddress -----------------------------------------------------
  for (const ip of ['10.0.0.1', '172.16.0.1', '172.31.255.254', '192.168.11.20', '169.254.1.1', 'fe80::1', 'fd12::1', 'fc00::1', '::ffff:192.168.1.1']) {
    assert.ok(lan.isLocalAddress(ip), `${ip} is local`);
  }
  for (const ip of ['8.8.8.8', '172.32.0.1', '172.15.0.1', '127.0.0.1', '::1', '2001:db8::1', 'not-an-ip', '']) {
    assert.ok(!lan.isLocalAddress(ip), `${ip} is not local`);
  }
  console.log('isLocalAddress ok');

  // -- isLocalTarget ------------------------------------------------------
  assert.strictEqual(await lan.isLocalTarget('bento.local'), true, '.local without resolving');
  assert.strictEqual(await lan.isLocalTarget('Bento.LOCAL.'), true, 'case and trailing dot');
  assert.strictEqual(await lan.isLocalTarget('192.168.11.20'), true);
  assert.strictEqual(await lan.isLocalTarget('1.1.1.1'), false);
  assert.strictEqual(await lan.isLocalTarget('localhost'), false, 'loopback is not gated');
  assert.strictEqual(await lan.isLocalTarget('webmux-test.invalid'), false, 'unresolvable → not local');
  console.log('isLocalTarget ok');

  // -- probe --------------------------------------------------------------
  const srv = net.createServer((s) => s.destroy());
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const { port } = srv.address();
  let r = await lan.probe('127.0.0.1', port);
  assert.strictEqual(r.ok, true, 'connects to a listener');
  srv.close();
  await new Promise((res) => srv.once('close', res));
  r = await lan.probe('127.0.0.1', port);
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.code, 'ECONNREFUSED', `closed port refuses (got ${r.code})`);
  r = await lan.probe('webmux-test.invalid', 22);
  assert.strictEqual(r.ok, false);
  assert.ok(/ENOTFOUND|EAI_AGAIN/.test(r.code), `unresolvable never rejects (got ${r.code})`);
  // A black hole: the timeout fires and the socket is torn down.
  r = await lan.probe('192.0.2.1', 22, 300); // TEST-NET-1, unrouted
  assert.strictEqual(r.ok, false);
  assert.ok(r.ms < 2000, `bounded by the timeout (took ${r.ms}ms, code ${r.code})`);
  console.log('probe ok');

  // -- grantPending -------------------------------------------------------
  assert.ok(lan.grantPending({ ok: false, code: 'EHOSTUNREACH' }, '192.168.1.5'), 'denial, any host');
  assert.ok(lan.grantPending({ ok: false, code: 'ENOTFOUND' }, 'bento.local'), 'gated mDNS lookup');
  assert.ok(lan.grantPending({ ok: false, code: 'EAI_AGAIN' }, 'Bento.LOCAL.'));
  assert.ok(!lan.grantPending({ ok: false, code: 'ENOTFOUND' }, 'box.example.com'), 'a plain DNS miss is a verdict');
  assert.ok(!lan.grantPending({ ok: false, code: 'ECONNREFUSED' }, 'bento.local'), 'refused means reachable');
  assert.ok(!lan.grantPending({ ok: false, code: 'ETIMEDOUT' }, '10.0.0.9'), 'timeout is the host, not the grant');
  assert.ok(!lan.grantPending({ ok: true }, 'bento.local'));
  console.log('grantPending ok');

  // -- looksDenied --------------------------------------------------------
  assert.ok(lan.looksDenied(['ssh: connect to host bento.local port 22: No route to host']));
  assert.ok(lan.looksDenied(['Warning: Permanently added', 'read: Undefined error: 0']));
  assert.ok(!lan.looksDenied(['ssh: connect to host x port 22: Connection refused']));
  assert.ok(!lan.looksDenied([]));
  console.log('looksDenied ok');
})().catch((err) => { console.error(err); process.exit(1); });
