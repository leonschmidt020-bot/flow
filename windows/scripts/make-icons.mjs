#!/usr/bin/env node
// Builds build/icon.ico (+ PNGs) from the Mac app icon. macOS only (uses `sips`); outputs are committed.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, copyFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// default: the Mac app's icon in this monorepo (mac/flow/Resources)
const src = process.argv[2] ?? path.join(root, '..', 'mac', 'flow', 'Resources', 'icon_1024.png');
const tmp = path.join(root, '.cache', 'icons');
mkdirSync(tmp, { recursive: true });
mkdirSync(path.join(root, 'build'), { recursive: true });
mkdirSync(path.join(root, 'resources'), { recursive: true });
const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
const pngs = sizes.map((s) => {
  const out = path.join(tmp, `icon_${s}.png`);
  execFileSync('sips', ['-z', String(s), String(s), src, '--out', out], { stdio: 'ignore' });
  return readFileSync(out);
});
// ICO with PNG payloads (supported since Windows Vista)
const header = Buffer.alloc(6); header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4);
const dir = Buffer.alloc(16 * sizes.length);
let offset = 6 + dir.length;
sizes.forEach((s, i) => {
  const e = i * 16;
  dir.writeUInt8(s >= 256 ? 0 : s, e); dir.writeUInt8(s >= 256 ? 0 : s, e + 1);
  dir.writeUInt8(0, e + 2); dir.writeUInt8(0, e + 3); dir.writeUInt16LE(1, e + 4); dir.writeUInt16LE(32, e + 6);
  dir.writeUInt32LE(pngs[i].length, e + 8); dir.writeUInt32LE(offset, e + 12);
  offset += pngs[i].length;
});
writeFileSync(path.join(root, 'build', 'icon.ico'), Buffer.concat([header, dir, ...pngs]));
execFileSync('sips', ['-z', '512', '512', src, '--out', path.join(root, 'build', 'icon.png')], { stdio: 'ignore' });
copyFileSync(path.join(tmp, 'icon_256.png'), path.join(root, 'resources', 'icon.png'));
copyFileSync(path.join(tmp, 'icon_32.png'), path.join(root, 'resources', 'tray.png'));
copyFileSync(path.join(tmp, 'icon_64.png'), path.join(root, 'resources', 'tray@2x.png'));
writeFileSync(path.join(root, 'resources', 'icon.ico'), readFileSync(path.join(root, 'build', 'icon.ico')));
console.log('icons ok');
