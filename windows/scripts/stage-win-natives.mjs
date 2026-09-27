#!/usr/bin/env node
// For cross-building the Windows installer on macOS/Linux: npm only installs the native packages of the
// host OS, so this fetches the win-x64 prebuilds (same versions as the lockfile) into node_modules.
// Not needed on Windows / in CI.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const lock = JSON.parse(readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
const want = ['sherpa-onnx-win-x64', '@koromix/koffi-win32-x64'];
const stage = path.join(root, '.cache', 'win-natives');
mkdirSync(stage, { recursive: true });
for (const name of want) {
  const entry = lock.packages[`node_modules/${name}`];
  if (!entry) throw new Error(`${name} missing in package-lock.json`);
  const dest = path.join(root, 'node_modules', ...name.split('/'));
  if (existsSync(path.join(dest, 'package.json'))) { console.log('✓', name, '(present)'); continue; }
  const out = execFileSync('npm', ['pack', `${name}@${entry.version}`, '--silent'], { cwd: stage, encoding: 'utf8', shell: process.platform === 'win32' }).trim().split('\n').pop();
  mkdirSync(dest, { recursive: true });
  execFileSync('tar', ['-xzf', path.join(stage, out), '-C', dest, '--strip-components=1']);
  console.log('✓', name, entry.version);
}
rmSync(path.join(stage), { recursive: true, force: true });
