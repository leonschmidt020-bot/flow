#!/usr/bin/env node
// Build: esbuild bundles main, preloads, renderers (+ the ClipVault module) into dist/.
//   node scripts/build.mjs               full app build
//   node scripts/build.mjs --scripts-only  only dist-scripts/ (test-asr etc.)
import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const r = (...p) => path.join(root, ...p);
const pkg = JSON.parse(readFileSync(r('package.json'), 'utf8'));
const external = ['electron', ...Object.keys(pkg.dependencies ?? {}), ...Object.keys(pkg.optionalDependencies ?? {})];
const scriptsOnly = process.argv.includes('--scripts-only');
const watch = process.argv.includes('--watch');

const common = { bundle: true, sourcemap: 'linked', logLevel: 'warning', target: 'es2022', legalComments: 'none', charset: 'utf8' };
const node = { ...common, platform: 'node', format: 'cjs', target: 'node22', external };
const browser = { ...common, platform: 'browser', format: 'iife', target: 'chrome130' };

async function scripts() {
  mkdirSync(r('dist-scripts'), { recursive: true });
  await build({ ...node, entryPoints: [r('scripts/test-asr.ts')], outfile: r('dist-scripts/test-asr.js') });
}

function copyStatic(fromDir, toDir, exts) {
  if (!existsSync(fromDir)) return;
  for (const name of readdirSync(fromDir)) {
    const f = path.join(fromDir, name);
    if (statSync(f).isDirectory()) { copyStatic(f, path.join(toDir, name), exts); continue; }
    if (exts.some((e) => name.endsWith(e))) { mkdirSync(toDir, { recursive: true }); cpSync(f, path.join(toDir, name)); }
  }
}

async function app() {
  rmSync(r('dist'), { recursive: true, force: true });
  mkdirSync(r('dist'), { recursive: true });
  const define = { __FLOW_VERSION__: JSON.stringify(pkg.version) };
  const jobs = [
    build({ ...node, entryPoints: [r('src/main/index.ts')], outfile: r('dist/main.js'), define }),
    build({ ...node, entryPoints: [r('src/preload/pill.ts')], outfile: r('dist/preload/pill.js') }),
    build({ ...node, entryPoints: [r('src/preload/hub.ts')], outfile: r('dist/preload/hub.js') }),
    build({ ...node, entryPoints: [r('src/preload/mic.ts')], outfile: r('dist/preload/mic.js') }),
    build({ ...browser, entryPoints: [r('src/renderer/pill/pill.ts')], outfile: r('dist/renderer/pill/pill.js') }),
    build({ ...browser, entryPoints: [r('src/renderer/hub/hub.ts')], outfile: r('dist/renderer/hub/hub.js') }),
    build({ ...browser, entryPoints: [r('src/renderer/mic/mic.ts')], outfile: r('dist/renderer/mic/mic.js') }),
    build({ ...browser, format: 'esm', entryPoints: [r('src/renderer/mic/worklet.ts')], outfile: r('dist/renderer/mic/worklet.js') }),
  ];
  // ClipVault module (other agent) – optional entries
  if (existsSync(r('src/clipvault/preload.ts'))) jobs.push(build({ ...node, entryPoints: [r('src/clipvault/preload.ts')], outfile: r('dist/clipvault/preload.js') }));
  if (existsSync(r('src/clipvault/ui/panel.ts'))) jobs.push(build({ ...browser, entryPoints: [r('src/clipvault/ui/panel.ts')], outfile: r('dist/clipvault/ui/panel.js') }));
  await Promise.all(jobs);
  copyStatic(r('src/renderer'), r('dist/renderer'), ['.html', '.css', '.svg', '.png', '.woff2', '.ttf']);
  copyStatic(r('src/clipvault/ui'), r('dist/clipvault/ui'), ['.html', '.css', '.svg', '.png', '.woff2']);
  if (existsSync(r('src/clipvault/assets'))) cpSync(r('src/clipvault/assets'), r('dist/clipvault/assets'), { recursive: true });
  mkdirSync(r('dist/clipvault/assets'), { recursive: true });
  copyStatic(r('resources'), r('dist/assets'), ['.png', '.ico', '.svg']);
  await scripts();
  console.log('build ok →', path.relative(process.cwd(), r('dist')) || 'dist');
}

if (scriptsOnly) await scripts(); else await app();
if (watch) console.log('(watch not implemented – rerun npm run build)');
