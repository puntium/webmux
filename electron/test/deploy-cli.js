// Drive the auto-deploy flow from a terminal, no Electron involved:
//
//   node electron/test/deploy-cli.js <ssh-host> [instance] [-- extra ssh args]
//
// Uses the payload built by `node deploy/build-payload.js` and a node-runtime
// cache in electron/payload/node-cache (main.js uses <userData>/node-cache
// instead). Handy for testing the push path against any host you can ssh to.

const { spawn } = require('child_process');
const path = require('path');
const { deploy } = require('../deploy');

const argv = process.argv.slice(2);
const dashdash = argv.indexOf('--');
const extraSsh = dashdash >= 0 ? argv.splice(dashdash).slice(1) : [];
const [host, instance = 'default'] = argv;
if (!host) {
  console.error('usage: node deploy-cli.js <ssh-host> [instance] [-- extra ssh args]');
  process.exit(2);
}

const dist = path.join(__dirname, '..', 'payload');
let manifest;
try {
  manifest = require(path.join(dist, 'payload.json'));
} catch {
  console.error('no payload manifest — run `node deploy/build-payload.js` first');
  process.exit(2);
}

const ctx = {
  spawnSsh: (command) => spawn('ssh', [
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    ...extraSsh,
    host,
    command,
  ], { stdio: ['pipe', 'pipe', 'pipe'] }),
  status: (msg) => console.log(`[status] ${msg}`),
  stderr: (line) => console.error(`[remote] ${line}`),
  isLive: () => true,
};

deploy(ctx, {
  payloadTar: path.join(dist, 'payload.tar.gz'),
  payloadHash: manifest.hash,
  instance,
  nodeCacheDir: path.join(dist, 'node-cache'),
}).then((result) => {
  console.log(JSON.stringify(result, null, 2));
}).catch((err) => {
  console.error(`FAILED: ${err.message}`);
  process.exit(1);
});
