#!/usr/bin/env node
// Zip a built (and signed) webmux.app — electron-builder's `--mac dir`
// output — into the release archive, keeping symlinks as symlinks. The
// .app is the archive's only top-level entry, so Archive Utility expands
// it straight to webmux.app rather than into a folder.
//
// electron-builder's own `--mac zip` target, when run on Linux, flattens
// every symlink into a copy. An Electron .app is full of them (each
// framework's `Versions/Current`, `Mantle -> Versions/Current/Mantle`, …),
// so the result unpacks on the Mac as frameworks with two copies of
// everything: ~60 MB bigger, and — worse — a layout codesign calls
// "ambiguous", which invalidates the frameworks' own signatures and makes
// the app impossible to re-sign. Without a valid signature macOS 26.5+/27
// can't attribute Local Network grants to the app and denies every LAN
// connection. Hence a zip writer of our own (no zip binary on the build
// host, no zip library among the client's dependencies).
//
//   node pack-mac.js <app-dir> <out.zip>
//
// Regular files are deflated; symlinks are stored with the Unix mode
// 0120777 in the external attributes and the link target as data, which is
// what Info-ZIP and macOS's Archive Utility / ditto both write and read.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const [appDir, outZip] = process.argv.slice(2);
if (!appDir || !outZip) {
  console.error('usage: node pack-mac.js <webmux.app> <out.zip>');
  process.exit(2);
}

// CRC-32 (IEEE), table-driven.
const CRC_TABLE = new Int32Array(256);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  CRC_TABLE[n] = c;
}
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

// MS-DOS date/time fields from an mtime.
function dosTime(d) {
  const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
  const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  return { time, date };
}

// Walk the tree in a stable order; directories first so extraction
// creates them before their contents.
function* walk(root, rel) {
  const entries = fs.readdirSync(path.join(root, rel), { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name));
  for (const ent of entries) {
    const r = path.posix.join(rel, ent.name);
    const st = fs.lstatSync(path.join(root, r));
    if (st.isSymbolicLink()) yield { rel: r, kind: 'link', st };
    else if (st.isDirectory()) { yield { rel: r, kind: 'dir', st }; yield* walk(root, r); }
    else yield { rel: r, kind: 'file', st };
  }
}

const out = fs.openSync(outZip, 'w');
let offset = 0;
const central = [];
const write = (buf) => { fs.writeSync(out, buf); offset += buf.length; };

function addEntry(name, data, mode, mtime, { deflate }) {
  const nameBuf = Buffer.from(name, 'utf8');
  const crc = crc32(data);
  const method = deflate ? 8 : 0;
  const payload = deflate ? zlib.deflateRawSync(data, { level: 9 }) : data;
  const { time, date } = dosTime(mtime);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4); // version needed: 2.0
  local.writeUInt16LE(0x0800, 6); // flags: UTF-8 names
  local.writeUInt16LE(method, 8);
  local.writeUInt16LE(time, 10);
  local.writeUInt16LE(date, 12);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(payload.length, 18);
  local.writeUInt32LE(data.length, 22);
  local.writeUInt16LE(nameBuf.length, 26);
  local.writeUInt16LE(0, 28);
  const headerOffset = offset;
  write(local); write(nameBuf); write(payload);

  const cd = Buffer.alloc(46);
  cd.writeUInt32LE(0x02014b50, 0);
  cd.writeUInt16LE((3 << 8) | 20, 4); // made by: Unix, 2.0
  cd.writeUInt16LE(20, 6);
  cd.writeUInt16LE(0x0800, 8);
  cd.writeUInt16LE(method, 10);
  cd.writeUInt16LE(time, 12);
  cd.writeUInt16LE(date, 14);
  cd.writeUInt32LE(crc, 16);
  cd.writeUInt32LE(payload.length, 20);
  cd.writeUInt32LE(data.length, 24);
  cd.writeUInt16LE(nameBuf.length, 28);
  cd.writeUInt16LE(0, 30); // extra
  cd.writeUInt16LE(0, 32); // comment
  cd.writeUInt16LE(0, 34); // disk
  cd.writeUInt16LE(0, 36); // internal attrs
  cd.writeUInt32LE((mode & 0xffff) * 0x10000, 38); // external attrs: Unix mode in the high half
  cd.writeUInt32LE(headerOffset, 42);
  central.push(Buffer.concat([cd, nameBuf]));
}

const appName = path.basename(appDir.replace(/\/+$/, ''));
let files = 0; let links = 0;
addEntry(appName + '/', Buffer.alloc(0), 0o40755, fs.statSync(appDir).mtime, { deflate: false });
for (const e of walk(appDir, '')) {
  const name = path.posix.join(appName, e.rel);
  const full = path.join(appDir, e.rel);
  if (e.kind === 'dir') {
    addEntry(name + '/', Buffer.alloc(0), 0o40000 | (e.st.mode & 0o7777), e.st.mtime, { deflate: false });
  } else if (e.kind === 'link') {
    addEntry(name, Buffer.from(fs.readlinkSync(full)), 0o120777, e.st.mtime, { deflate: false });
    links++;
  } else {
    addEntry(name, fs.readFileSync(full), 0o100000 | (e.st.mode & 0o7777), e.st.mtime, { deflate: true });
    files++;
  }
}
const cdStart = offset;
for (const c of central) write(c);
const cdSize = offset - cdStart;
if (central.length > 0xffff || cdStart > 0xffffffff) throw new Error('archive needs zip64; not implemented');
const eocd = Buffer.alloc(22);
eocd.writeUInt32LE(0x06054b50, 0);
eocd.writeUInt16LE(0, 4);
eocd.writeUInt16LE(0, 6);
eocd.writeUInt16LE(central.length, 8);
eocd.writeUInt16LE(central.length, 10);
eocd.writeUInt32LE(cdSize, 12);
eocd.writeUInt32LE(cdStart, 16);
eocd.writeUInt16LE(0, 20);
write(eocd);
fs.closeSync(out);
console.log(`${outZip}: ${files} files, ${links} symlinks, ${(offset / 1048576).toFixed(1)} MB`);
