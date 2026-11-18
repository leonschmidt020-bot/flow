// ClipVault sync – end-to-end test against a LOCAL worker (wrangler dev), never a real vault.
//
//   npm run test:sync                         three Windows (TypeScript) clients
//   npm run test:sync -- --mac-cv <binary>    device A is the Mac ClipVault (Swift, `clipvault sync-agent`)
//
// Steps:
//   1. wrangler dev --local (free port, own --persist-to dir, INIT_SECRET set)
//   2. device A creates the vault (needs the init secret) and a pairing code → B joins with only the code
//   3. B (a member, not the creator) creates the next code → C joins; A invites again → D joins: four devices
//   4. text A → B + C, text C → A + B, 6 MB file (big item, in parts) B → A + C, byte-identical
//   5. reconnect: C stops, A shares while C is away, C starts again and catches up
//   6. an error report (text starting with "# Flow-Fehlerbericht") from C arrives at A
//   7. the worker's storage never contains plaintext markers
// Result: JSON on stdout (last line) + exit code 0/1.
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import * as fs from 'node:fs';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';
import { SharedVault } from '../src/clipvault/sync/vault';
import { SyncEngine, type FetchLike, type SyncSnapshot, type WsFactory } from '../src/clipvault/sync/engine';
import type { ClipItem } from '../src/clipvault/core/types';
import { REPORT_HEADER } from '../src/main/errorReport';

const args = process.argv.slice(2);
const opt = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const macCv = opt('--mac-cv');
const workerDir = path.resolve(opt('--worker') ?? path.join(__dirname, '..', '..', 'mac', 'clipvault', 'sync-worker'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'flow-sync-'));
const results: { name: string; ok: boolean; info: string }[] = [];
const add = (name: string, ok: boolean, info = '') => { results.push({ name, ok, info }); console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${info ? ' – ' + info : ''}`); };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function wait(cond: () => boolean | Promise<boolean>, ms = 20000, step = 50): Promise<number | null> {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try { if (await cond()) return Date.now() - t0; } catch { /* retry */ }
    await sleep(step);
  }
  return null;
}
const sha = (p: string) => createHash('sha256').update(fs.readFileSync(p)).digest('hex');
function freePort(): Promise<number> {
  return new Promise((res) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = (s.address() as net.AddressInfo).port; s.close(() => res(p)); }); });
}

interface Dev {
  name: string;
  me: string;
  start(): Promise<boolean>;
  stop(): Promise<void>;
  setup(url: string, initSecret?: string): Promise<void>;
  pairCreate(): Promise<string>;
  pairJoin(code: string): Promise<string>;
  state(): string;
  shareText(text: string): Promise<string>;
  shareFile(p: string): Promise<string>;
  /** shared items by lower-case id */
  shared(): Record<string, { text?: string | null; deleted?: boolean; parts?: number | null; fileName?: string | null }>;
  filePath(id: string, name: string): string;
}

// ---------------------------------------------------------------- Windows client (the real engine, no Electron)
class TsDev implements Dev {
  dir: string; vault!: SharedVault; engine: SyncEngine | null = null; snap: SyncSnapshot | null = null;
  constructor(public name: string, public me: string) { this.dir = path.join(work, 'dev' + name); fs.mkdirSync(this.dir, { recursive: true }); }
  async start() {
    this.vault = new SharedVault(this.dir, { me: () => this.me });
    this.vault.load();
    const fetchImpl: FetchLike = (u, init) => fetch(u, init as RequestInit) as unknown as ReturnType<FetchLike>;
    const W = (globalThis as unknown as { WebSocket?: new (u: string, p: string[]) => unknown }).WebSocket;
    if (!W) throw new Error('Node without global WebSocket (need Node ≥ 22)');
    const ws: WsFactory = (u, p) => new W(u, p) as ReturnType<WsFactory>;
    this.engine = new SyncEngine({
      dir: this.dir, vault: this.vault, fetch: fetchImpl, ws, me: () => this.me,
      secrets: { protect: (b) => b, unprotect: (b) => b },
      onSnapshot: (s) => { this.snap = s; },
      log: process.env.SYNC_DEBUG ? (...a) => console.log(this.name, ...a) : undefined,
    });
    this.engine.start();
    return true;
  }
  async stop() { this.engine?.stop(); this.engine = null; this.snap = null; }
  async setup(url: string, initSecret?: string) { this.engine!.setup(url, initSecret); }
  async pairCreate() { return (await this.engine!.pairCreate()).code; }
  async pairJoin(code: string) { return JSON.stringify(await this.engine!.pairJoin(code)); }
  state() { const s = this.engine?.snapshot(); return s ? (s.state === 'waiting' ? 'connected' : s.state) : 'off'; }
  async shareText(text: string) {
    const s = this.vault.shareText(text);
    await this.engine!.enqueue(s.id);
    return s.id.toLowerCase();
  }
  async shareFile(p: string) {
    const clip = { id: crypto.randomUUID(), kind: 'file', files: [{ name: path.basename(p), stored: null, orig: p }], ts: Date.now() / 1000 } as unknown as ClipItem;
    const [s] = this.vault.share(clip, (r) => r);
    await this.engine!.enqueue(s!.id);
    return s!.id.toLowerCase();
  }
  shared() {
    const o: ReturnType<Dev['shared']> = {};
    for (const i of this.vault.items) o[i.id.toLowerCase()] = i;
    return o;
  }
  filePath(id: string) { const it = this.vault.item(id); return (it && this.vault.filePath(it)) ?? ''; }
}

// ---------------------------------------------------------------- Mac client (clipvault binary, own CLIPVAULT_HOME + keychain name)
class MacDev implements Dev {
  dir: string; proc: ChildProcess | null = null; env: NodeJS.ProcessEnv; suffix: string;
  constructor(public name: string, public me: string, private bin: string) {
    this.dir = path.join(work, 'dev' + name); fs.mkdirSync(this.dir, { recursive: true });
    fs.writeFileSync(path.join(this.dir, 'shared-me.txt'), me);
    this.suffix = 'synctest' + name + randomBytes(4).toString('hex');
    this.env = { ...process.env, CLIPVAULT_HOME: this.dir, CLIPVAULT_KEYCHAIN_SUFFIX: this.suffix };
  }
  private cli(...a: string[]) {
    const r = spawnSync(this.bin, a, { env: this.env, encoding: 'utf8', timeout: 40000 });
    return (r.stdout ?? '').trim();
  }
  private send(action: string, kw: Record<string, string>) {
    const out = this.cli('send', action, ...Object.entries(kw).map(([k, v]) => `${k}=${v}`));
    try { return JSON.parse(out.split('\n').pop()!); } catch { return { ok: false, error: out.slice(-200) }; }
  }
  private status(): Record<string, string> {
    try { return Object.fromEntries(fs.readFileSync(path.join(this.dir, 'status.txt'), 'utf8').split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)])); } catch { return {}; }
  }
  async start() {
    this.proc = spawn(this.bin, ['sync-agent'], { env: this.env, stdio: ['ignore', fs.openSync(path.join(this.dir, 'agent.out'), 'a'), fs.openSync(path.join(this.dir, 'agent.out'), 'a')], detached: true });
    return (await wait(() => fs.existsSync(path.join(this.dir, 'token')) && 'pid' in this.status(), 15000)) !== null;
  }
  async stop() { try { this.proc?.kill('SIGTERM'); } catch { /* ignore */ } this.proc = null; await sleep(300); }
  async setup(url: string, initSecret?: string) { this.cli('sync', 'setup', url, ...(initSecret ? [initSecret] : [])); }
  async pairCreate() { const o = this.cli('pair', 'create'); return o.split('\n').map((l) => l.trim()).find((l) => l.startsWith('cvpair1.')) ?? o; }
  async pairJoin(code: string) { return this.cli('pair', 'join', code); }
  state() { const s = this.status().sync_state ?? 'off'; return s === 'waiting' ? 'connected' : s; }
  async shareText(text: string) {
    const r = this.send('addText', { text });
    const s = this.send('share', { id: r.id });
    return String(s.id ?? '').toLowerCase();
  }
  async shareFile(p: string) {
    const r = this.send('addFile', { path: p });
    const s = this.send('share', { id: r.id });
    return String(s.id ?? '').toLowerCase();
  }
  shared() {
    try {
      const o: ReturnType<Dev['shared']> = {};
      for (const i of JSON.parse(fs.readFileSync(path.join(this.dir, 'shared.json'), 'utf8')).items) o[String(i.id).toLowerCase()] = i;
      return o;
    } catch { return {}; }
  }
  filePath(id: string, name: string) {
    for (const p of [path.join(this.dir, 'shared', 'files', id, name), path.join(this.dir, 'shared', id, name)]) if (fs.existsSync(p)) return p;
    return path.join(this.dir, 'shared', 'files', id, name);
  }
  cleanupKeychain() {
    const svc = 'app.flowdictation.clipvault.sync.' + this.suffix;
    for (const acct of ['vault-key', 'vault-token', 'init-secret']) spawnSync('/usr/bin/security', ['delete-generic-password', '-s', svc, '-a', acct]);
  }
}

async function main() {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const initSecret = randomBytes(24).toString('hex');
  const wranglerBin = path.join(workerDir, 'node_modules', '.bin', process.platform === 'win32' ? 'wrangler.cmd' : 'wrangler');
  if (!fs.existsSync(wranglerBin)) {
    add('wrangler installiert (npm ci im sync-worker-Ordner)', false, wranglerBin);
    return finish(null, []);
  }
  const wlog = fs.openSync(path.join(work, 'wrangler.log'), 'w');
  const wr = spawn(wranglerBin, ['dev', '--local', '--ip', '127.0.0.1', '--port', String(port), '--persist-to', path.join(work, 'state'),
    '--var', `INIT_SECRET:${initSecret}`, '--config', path.join(workerDir, 'wrangler.toml'), '--log-level', 'warn'],
  { cwd: workerDir, stdio: ['ignore', wlog, wlog], env: { ...process.env, WRANGLER_SEND_METRICS: 'false', NO_COLOR: '1', CI: '1' }, shell: process.platform === 'win32', detached: process.platform !== 'win32' });
  const tag = randomBytes(3).toString('hex');
  const a: Dev = macCv ? new MacDev('A', 'Alpha' + tag, macCv) : new TsDev('A', 'Alpha' + tag);
  const b = new TsDev('B', 'Beta' + tag);
  const c = new TsDev('C', 'Gamma' + tag);
  const d = new TsDev('D', 'Delta' + tag);
  const devs: Dev[] = [a, b, c, d];
  const markers: string[] = [];
  try {
    const up = await wait(async () => (await fetch(url + '/health')).status === 200, 60000, 250);
    add('lokaler Worker (wrangler dev --local)', up !== null, up !== null ? `${url}, ${(up / 1000).toFixed(1)} s` : fs.readFileSync(path.join(work, 'wrangler.log'), 'utf8').slice(-300));
    if (up === null) return finish(wr, devs);
    add(`vier Geräte gestartet (A = ${macCv ? 'Mac/Swift' : 'Windows/TS'}, B–D = Windows/TS)`, (await Promise.all(devs.map((d) => d.start()))).every(Boolean));

    // --- A creates the vault
    await a.setup(url);
    let refused = '';
    try { refused = await a.pairCreate(); } catch (e) { refused = (e as Error).message; }
    add('ohne INIT_SECRET entsteht kein Tresor', !refused.startsWith('cvpair1.'), refused.slice(0, 100));
    await a.setup(url, initSecret);
    const code1 = await a.pairCreate();
    add('A legt Tresor an, Kopplungscode cvpair1', code1.startsWith('cvpair1.'), code1.startsWith('cvpair1.') ? '' : code1.slice(0, 200));
    if (!code1.startsWith('cvpair1.')) return finish(wr, devs);
    // --- B joins with the code alone (no URL entered)
    const j1 = await b.pairJoin(code1);
    let dt = await wait(() => a.state() === 'connected' && b.state() === 'connected', 25000);
    add('B koppelt nur mit dem Code, A + B verbunden', dt !== null, dt !== null ? `${dt} ms` : `A=${a.state()} B=${b.state()} ${j1.slice(0, 100)}`);
    // --- C joins via a code created by B (member, not creator)
    const code2 = await b.pairCreate();
    const j2 = await c.pairJoin(code2);
    dt = await wait(() => c.state() === 'connected', 25000);
    add('C koppelt mit Code von B (drittes Gerät)', code2.startsWith('cvpair1.') && dt !== null, dt !== null ? `${dt} ms` : `C=${c.state()} ${j2.slice(0, 100)}`);
    if (dt === null) return finish(wr, devs);
    // --- D joins via a SECOND code from A (the creator invites again, after the vault is already shared)
    const code3 = await a.pairCreate();
    const j3 = code3.startsWith('cvpair1.') ? await d.pairJoin(code3) : code3;
    dt = await wait(() => d.state() === 'connected', 25000);
    add('D koppelt mit zweitem Code von A (viertes Gerät)', dt !== null, dt !== null ? `${dt} ms` : `D=${d.state()} ${j3.slice(0, 120)}`);

    // --- texts
    const textTo = async (src: Dev, dsts: Dev[]) => {
      const m = `SYNCTEST-KLARTEXT-${src.name}-${randomBytes(6).toString('hex')}`; markers.push(m);
      const t0 = Date.now();
      const id = await src.shareText(m);
      const ok = await wait(() => dsts.every((d) => d.shared()[id]?.text === m), 20000, 20);
      add(`Text ${src.name} → ${dsts.map((d) => d.name).join(' + ')}`, ok !== null, ok !== null ? `${Date.now() - t0} ms` : dsts.map((d) => `${d.name}:${!!d.shared()[id]}`).join(' '));
    };
    await textTo(a, [b, c, d]);
    await textTo(c, [a, b, d]);

    // --- big file B → A + C
    const name = `synctest-datei-${randomBytes(3).toString('hex')}.bin`;
    const fp = path.join(work, name);
    const fm = `SYNCTEST-DATEI-${randomBytes(8).toString('hex')}`; markers.push(fm, name);
    fs.writeFileSync(fp, Buffer.concat([Buffer.from(fm), randomBytes(6 * 1024 * 1024), Buffer.from(fm)]));
    const want = sha(fp);
    let t0 = Date.now();
    const fid = await b.shareFile(fp);
    const ok = await wait(() => [a, c].every((d) => { const p = d.filePath(fid, name); return fs.existsSync(p) && fs.statSync(p).size === fs.statSync(fp).size && sha(p) === want; }), 60000, 100);
    add('6-MB-Datei B → A + C byte-identisch', ok !== null, ok !== null ? `${Date.now() - t0} ms` : '');
    add('Datei lief als großer Eintrag (in Teilen)', (a.shared()[fid]?.parts ?? 0) > 0, `parts=${a.shared()[fid]?.parts}`);

    // --- reconnect: C away, A shares, C back
    await c.stop();
    const away = `SYNCTEST-KLARTEXT-WEG-${randomBytes(6).toString('hex')}`; markers.push(away);
    const aid = await a.shareText(away);
    await wait(() => b.shared()[aid]?.text === away, 20000);
    await c.start();
    t0 = Date.now();
    dt = await wait(() => c.shared()[aid]?.text === away && c.state() === 'connected', 30000);
    add('Wiederverbinden: C holt nach, was in der Pause geteilt wurde', dt !== null, dt !== null ? `${Date.now() - t0} ms` : `C=${c.state()}`);

    // --- error report C → A (what the Mac recognises)
    const rep = `${REPORT_HEADER}\n\nSYNCTEST-BERICHT-${randomBytes(4).toString('hex')}`; markers.push(rep.split('\n').pop()!);
    const rid = await c.shareText(rep);
    dt = await wait(() => (a.shared()[rid]?.text ?? '').startsWith(REPORT_HEADER), 20000);
    add('Fehlerbericht C → A kommt an (erste Zeile „# Flow-Fehlerbericht“)', dt !== null, dt !== null ? `${dt} ms` : '');

    // --- no plaintext on the server
    const blobs: Buffer[] = [];
    const walk = (d: string) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else blobs.push(fs.readFileSync(p)); } };
    try { walk(path.join(work, 'state')); } catch { /* none */ }
    const leaks = markers.filter((m) => blobs.some((bl) => bl.includes(Buffer.from(m))));
    add('Server-Speicher ohne Klartext', blobs.length > 0 && leaks.length === 0, `${blobs.length} Dateien, ${markers.length} Marker${leaks.length ? ', gefunden: ' + leaks.join(', ') : ''}`);
  } catch (e) {
    add('Ablauf ohne Ausnahme', false, (e as Error).stack?.slice(0, 400) ?? String(e));
  }
  return finish(wr, devs);
}

async function finish(wr: ChildProcess | null, devs: Dev[]) {
  for (const d of devs) { await d.stop(); if (d instanceof MacDev) d.cleanupKeychain(); }
  if (wr?.pid) {
    try { if (process.platform === 'win32') spawnSync('taskkill', ['/pid', String(wr.pid), '/T', '/F']); else process.kill(-wr.pid, 'SIGTERM'); } catch { /* ignore */ }
  }
  const failed = results.filter((r) => !r.ok);
  console.log(JSON.stringify({ ok: failed.length === 0 && results.length > 0, passed: results.length - failed.length, failed: failed.length, work }));
  process.exit(failed.length === 0 && results.length > 0 ? 0 : 1);
}

void main();
