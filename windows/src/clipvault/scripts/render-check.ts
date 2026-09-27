// Offscreen render check of the ClipVault panel + Hub page (no clipboard access, no hotkeys, no network).
//
// Uses the REAL preload, panel.html/panel.js, Store and list/view code with sample data in a temp folder;
// only the IPC handlers are a small mock (so nothing touches the system clipboard). Writes PNGs.
//
//   node_modules/.bin/esbuild src/clipvault/scripts/render-check.ts --bundle --platform=node --format=cjs \
//     --external:electron --outfile=<out>/render-check.js   (+ preload.ts, ui/panel.ts, scripts/render-hub-entry.ts)
//   electron <out>/render-check.js <out>
// See README.md ("Render-Check") for the one-liner.
import { app, BrowserWindow, ipcMain, nativeImage } from 'electron';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Store } from '../core/store';
import { buildList, toView } from '../core/view';
import { imageFromNative } from '../electron/clipboardAdapter';
import { DEFAULT_SETTINGS } from '../core/settings';

const out = path.resolve(process.argv[process.argv.length - 1] ?? '.');
const dataDir = path.join(out, 'data');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function bitmap(w: number, h: number, paint: (x: number, y: number) => [number, number, number]): Buffer {
  const b = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const [r, g, bl] = paint(x, y);
    const p = (y * w + x) * 4;
    b[p] = bl; b[p + 1] = g; b[p + 2] = r; b[p + 3] = 255; // BGRA
  }
  return b;
}

function sampleImages() {
  const shot = nativeImage.createFromBitmap(bitmap(1280, 800, (x, y) => {
    const bar = y < 56 ? 34 : 0;
    const card = x > 120 && x < 700 && y > 140 && y < 520 ? 40 : 0;
    const line = card && (y - 180) % 42 < 10 && x < 620 ? -24 : 0;
    return [26 + bar + card + line, 28 + bar + card + line, 36 + bar + card * 1.3 + line];
  }), { width: 1280, height: 800 });
  const photo = nativeImage.createFromBitmap(bitmap(900, 600, (x, y) => {
    const sky = Math.max(0, 1 - y / 360);
    const hill = y > 380 + 40 * Math.sin(x / 90) ? 1 : 0;
    return hill ? [40 + x / 30, 90 + y / 12, 60] : [255 * (0.35 + 0.6 * sky), 150 + 80 * sky, 110 + 120 * sky];
  }), { width: 900, height: 600 });
  const chart = nativeImage.createFromBitmap(bitmap(640, 400, (x, y) => {
    const v = 320 - 120 * Math.sin(x / 70) - x / 5;
    return Math.abs(y - v) < 3 ? [142, 168, 255] : y > v ? [30, 36, 58] : [18, 19, 24];
  }), { width: 640, height: 400 });
  return [shot, photo, chart];
}

function wallpaper(p: string) {
  const w = 1600, h = 1000;
  const img = nativeImage.createFromBitmap(bitmap(w, h, (x, y) => {
    const a = Math.exp(-(((x - 1100) / 520) ** 2 + ((y - 380) / 380) ** 2));
    const b = Math.exp(-(((x - 350) / 420) ** 2 + ((y - 820) / 300) ** 2));
    return [18 + 110 * a + 30 * b, 30 + 80 * a + 90 * b, 70 + 160 * a + 120 * b];
  }), { width: w, height: h });
  fs.writeFileSync(p, img.toPNG());
}

function seed(store: Store, empty: boolean) {
  if (empty) return;
  const now = Date.now() / 1000;
  const add = (text: string, ago: number, source: string | null = null) => { const it = store.addText(text, source).item; it.ts = now - ago; return it; };
  const imgs = sampleImages();
  const i1 = store.addImage(imageFromNative(imgs[0]!)!, null, 'C:\\Users\\Lena\\Pictures\\Screenshots\\Screenshot 2026-09-27 204512.png').item; i1.ts = now - 60 * 3;
  i1.ocrText = 'Tessera · Belegungsplan September · 8 Einheiten';
  const i2 = store.addImage(imageFromNative(imgs[1]!)!).item; i2.ts = now - 3600 * 5;
  const i3 = store.addImage(imageFromNative(imgs[2]!)!).item; i3.ts = now - 86400 - 3600;
  add('Hallo Nico,\n\nhier die Punkte für morgen:\n– Kalender-Sync für die Ferienwohnung prüfen\n– Buchungs-Webhook testen\n– 10 Uhr Call mit Sam\n\nBis dann!', 60 * 2);
  add('https://tessera.example.app/dashboard/belegung?monat=2026-09', 60 * 9);
  add("export function fit1000(style: string): string {\n  const parts = style.split(',').map((p) => p.trim());\n  while (parts.join(', ').length > 1000) parts.pop();\n  return parts.join(', ');\n}", 60 * 25);
  add('Hauptstraße 12, 12345 Musterstadt', 3600 * 2);
  add('#8EA8FF', 3600 * 3);
  add('lena@example.com', 3600 * 4);
  add('Das ist der finale Text für den Newsletter – bitte nicht mehr ändern.', 3600 * 6, 'Diktat');
  const pin = add('IBAN-Vorlage: DE00 0000 0000 0000 0000 00 · Verwendungszweck: Rechnung {Nr}', 86400 * 3);
  store.setPinned(pin.id, true);
  const f = path.join(dataDir, '..', 'Vertrag_Final_2026.pdf');
  fs.writeFileSync(f, Buffer.alloc(248_000, 1));
  const fi = store.addFiles([f])!.item; fi.ts = now - 86400 - 7200;
  const pw = store.collections.find((c) => c.secret)!;
  const sec = add('mein-wlan-passwort-2026', 3600);
  store.setCollection(sec.id, pw.id);
  const work = store.collections.find((c) => !c.secret)!;
  const w1 = add('Angebot WDB Design – Phase 1: 1.800 $, Phase 2: 2.200 $, Phase 3: 1.500 $', 86400 * 5);
  store.setCollection(w1.id, work.id);
  store.persist();
}

async function main() {
  app.dock?.hide();
  app.on('window-all-closed', () => { /* keep running between the panel and the hub capture */ });
  await app.whenReady();
  fs.mkdirSync(out, { recursive: true });
  fs.rmSync(dataDir, { recursive: true, force: true });
  const wp = path.join(out, 'wallpaper.png');
  wallpaper(wp);
  const hubHtml = path.join(out, 'hub.html');
  fs.writeFileSync(hubHtml, `<!doctype html><html><head><meta charset="utf-8">
<style>:root{--bg:#0f1014;--panel:rgba(22,23,29,.9);--panel-2:rgba(255,255,255,.04);--line:rgba(255,255,255,.08);--text:#f2f2f5;--text-dim:rgba(235,235,245,.58);
--accent:#8ea8ff;--accent-2:#6f8cff;--danger:#ff6b6b;--radius:14px;--radius-sm:9px;--font:"Segoe UI Variable Text","Segoe UI",-apple-system,system-ui,sans-serif}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text)} .shell{display:flex;height:100%} .nav{width:64px;border-right:1px solid var(--line);background:#0b0c0f}
#hub{flex:1;height:100%}</style></head><body><div class="shell"><div class="nav"></div><div id="hub"></div></div><script src="hub.js"></script></body></html>`);

  let store = new Store(dataDir, { locale: 'de' });
  store.load();
  seed(store, false);
  let settings = { ...DEFAULT_SETTINGS, sync: { enabled: true, name: 'Lena' } };
  let win: BrowserWindow | null = null;
  const h: Record<string, (...a: any[]) => unknown> = { // eslint-disable-line @typescript-eslint/no-explicit-any
    list: (q: { query?: string; type?: never; collection?: string | null } = {}) => q.collection === '__shared__'
      ? { ...buildList(store, { locale: 'de' }), sections: [{ key: 'shared', items: [] }] } : buildList(store, { ...q, locale: 'de' }),
    item: (id: string, reveal: boolean) => { const it = store.item(id); return it ? toView(it, store, { full: true, revealSecrets: reveal, locale: 'de' }) : null; },
    image: (id: string) => { const it = store.item(id); const p = it && store.imagePath(it); if (!p) return null; const img = nativeImage.createFromPath(p); return { url: img.toDataURL(), w: img.getSize().width, h: img.getSize().height }; },
    settings: () => ({ ...settings, dpapiAvailable: true, platform: 'win32', readOnly: false, recovery: 'none' }),
    setSettings: (p: Record<string, unknown>) => { settings = { ...settings, ...p } as typeof settings; return h.settings!(); },
    syncStatus: () => ({ state: 'connected', paired: true, queue: 0, url: 'https://clipvault-sync.example.workers.dev', host: 'clipvault-sync.example.workers.dev' }),
    copy: () => true, paste: () => true, pin: (id: string, on: boolean) => store.setPinned(id, on), delete: () => true, hide: () => true,
    viewer: async (on: boolean) => {
      if (!win) return;
      win.setContentSize(on ? 1240 : 900, on ? 820 : 640);
      await win.webContents.insertCSS(on ? '#cv-root{width:1120px!important;height:700px!important}' : '#cv-root{width:780px!important;height:520px!important}');
    },
  };
  for (const [n, fn] of Object.entries(h)) ipcMain.handle('clipvault:' + n, (_e, ...a) => fn(...a));

  const preload = path.join(out, 'preload.js');
  const js = (w: BrowserWindow, code: string) => w.webContents.executeJavaScript(code);
  const inRoot = (code: string) => `(() => { const host = document.getElementById('cv-root') || document.getElementById('hub'); const r = host.shadowRoot; const cv = r.querySelector('.cv'); ${code} })()`;
  const until = async (w: BrowserWindow, cond: string, ms = 5000) => {
    const t0 = Date.now();
    while (!(await js(w, inRoot(`return !!(${cond});`)))) { if (Date.now() - t0 > ms) throw new Error('timeout: ' + cond); await sleep(50); }
  };
  const key = (w: BrowserWindow, k: string, extra = '') => js(w, inRoot(`const t = r.activeElement || cv; t.dispatchEvent(new KeyboardEvent('keydown', { key: '${k}', bubbles: true, composed: true ${extra} }));`));
  const shot = async (w: BrowserWindow, name: string) => {
    await sleep(350);
    const img = await w.webContents.capturePage();
    fs.writeFileSync(path.join(out, name + '.png'), img.toPNG());
    console.log('wrote', name + '.png', img.getSize());
  };

  // ---------------- panel
  const panelHtml = path.join(out, 'ui', 'panel.html');
  win = new BrowserWindow({ width: 900, height: 640, show: false, useContentSize: true, webPreferences: { offscreen: true, preload, contextIsolation: true, sandbox: false } });
  await win.loadFile(panelHtml, { query: { locale: 'de', material: 'acrylic' } });
  await win.webContents.insertCSS(`html{background:url("${'file://' + wp.replace(/\\/g, '/')}") center/cover !important}
    #cv-root{position:absolute;left:60px;top:56px;width:780px;height:520px;border-radius:12px;backdrop-filter:blur(40px) saturate(1.35);box-shadow:0 30px 90px rgba(0,0,0,.55),0 0 0 1px rgba(0,0,0,.4)}`);
  await until(win, `r.querySelector('.row')`);
  await key(win, 'ArrowDown');
  await until(win, `r.querySelector('.pbody .prose')`);
  await shot(win, '01-panel-text');
  for (let i = 0; i < 2; i++) await key(win, 'ArrowDown');
  await sleep(200);
  await shot(win, '02-panel-code-or-link');
  await js(win, inRoot(`r.querySelector('.row[data-id] .tile img').closest('.row').click();`));
  await until(win, `r.querySelector('.pbody.img img')`);
  await shot(win, '03-panel-image');
  await key(win, ' ');
  await until(win, `r.querySelector('.viewer img')`);
  await sleep(500);
  await shot(win, '04-panel-viewer');
  await key(win, 'ArrowRight');
  await key(win, '+');
  await key(win, '+');
  await shot(win, '05-panel-viewer-next-zoom');
  await key(win, 'Escape');
  await sleep(300);
  await js(win, inRoot(`[...r.querySelectorAll('.chip')].find((c) => c.textContent.includes('Passw')).click();`));
  await until(win, `r.querySelector('.tile.t-lock')`);
  await shot(win, '06-panel-secret');
  await js(win, inRoot(`[...r.querySelectorAll('.chip')][0].click();`));
  await until(win, `r.querySelectorAll('.row').length > 5`);
  await js(win, inRoot(`r.querySelector('[data-act=more]').click();`));
  await until(win, `r.querySelector('.menu')`);
  await shot(win, '07-panel-menu');
  await key(win, 'Escape');
  await js(win, inRoot(`r.querySelector('.menu')?.remove(); const q = r.querySelector('input.q'); q.focus(); q.value = 'zzzz nichts'; q.dispatchEvent(new Event('input', { bubbles: true }));`));
  await until(win, `r.querySelector('.empty')`);
  await shot(win, '08-panel-no-results');

  // empty store
  store = new Store(path.join(out, 'data-empty'), { locale: 'de' });
  fs.rmSync(store.dir, { recursive: true, force: true });
  fs.mkdirSync(store.dir, { recursive: true });
  store.load();
  await js(win, inRoot(`const q = r.querySelector('input.q'); q.value = ''; q.dispatchEvent(new Event('input', { bubbles: true }));`));
  await until(win, `r.querySelector('.empty h3')`);
  await shot(win, '09-panel-empty');
  win.destroy();
  await sleep(300);

  // ---------------- hub
  store = new Store(dataDir, { locale: 'de' });
  store.load();
  const hub = new BrowserWindow({ width: 1180, height: 760, show: false, webPreferences: { offscreen: true, preload, contextIsolation: true, sandbox: false } });
  await hub.loadFile(hubHtml, { query: { locale: 'de' } });
  await until(hub, `r.querySelector('.row')`);
  await js(hub, inRoot(`r.querySelector('.row[data-id] .tile img').closest('.row').click();`));
  await sleep(300);
  await shot(hub, '10-hub-list-image');
  await js(hub, inRoot(`r.querySelector('[data-act=settingsPage]').click();`));
  await until(hub, `r.querySelector('.settings .card')`);
  await shot(hub, '11-hub-settings');
  await js(hub, inRoot(`const s = r.querySelector('.settings'); s.scrollTop = s.scrollHeight;`));
  await shot(hub, '12-hub-settings-sync');
  hub.destroy();
  app.quit();
}

main().catch((e) => { console.error(e); app.exit(1); });
