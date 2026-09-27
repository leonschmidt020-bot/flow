// End-to-end sync between two in-process clients through an in-memory worker (no network).
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { SyncEngine, type SecretBox } from './engine';
import { SharedVault } from './vault';
import { FakeWorker } from './fakeWorker.testutil';
import type { ClipItem } from '../core/types';

const box: SecretBox = {
  protect: (p) => Buffer.concat([Buffer.from('TESTBOX'), Buffer.from(p).reverse()]),
  unprotect: (b) => Buffer.from(b.subarray(7)).reverse(),
};

async function until(cond: () => boolean, ms = 4000) {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error('timeout');
    await new Promise((r) => setTimeout(r, 10));
  }
}

let tmp: string;
let worker: FakeWorker;
const engines: SyncEngine[] = [];

function client(name: string) {
  const dir = path.join(tmp, name);
  fs.mkdirSync(dir, { recursive: true });
  const vault = new SharedVault(dir, { me: () => name });
  vault.load();
  const e = new SyncEngine({ dir, vault, secrets: box, fetch: worker.fetch, ws: worker.ws, me: () => name, periodicMs: 3_600_000, pongTimeoutMs: 200, pingEveryMs: 400 });
  e.start();
  engines.push(e);
  return { dir, vault, e };
}

function textClip(text: string): ClipItem {
  return { id: randomBytes(16).toString('hex').replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5').toUpperCase(), kind: 'text', text, ts: Date.now() / 1000 };
}

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cv-sync-test-'));
  worker = new FakeWorker();
});
afterEach(() => {
  for (const e of engines.splice(0)) e.stop();
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function pairedPair() {
  const a = client('Lena');
  const b = client('Nico');
  a.e.setup('https://fake.test');
  expect(() => a.e.setup('http://example.com')).toThrow();
  const { code } = await a.e.pairCreate();
  expect(code.startsWith('cvpair1.')).toBe(true);
  await b.e.pairJoin(code);
  await until(() => a.e.snapshot().state === 'connected' && b.e.snapshot().state === 'connected');
  return { a, b };
}

describe('sync engine', () => {
  it('pairs, shares text live, and keeps secrets out of sync.json', async () => {
    const { a, b } = await pairedPair();
    expect(a.e.snapshot().partnerJoined).toBe(true);
    const cfg = fs.readFileSync(path.join(a.dir, 'sync.json'), 'utf8');
    expect(cfg).not.toMatch(/[0-9a-f]{64}/);
    const sec = fs.readFileSync(path.join(a.dir, 'sync-secrets.bin'));
    expect(sec.subarray(0, 7).toString()).toBe('TESTBOX');

    const clip = textClip('Hallo Nico 👋 https://example.com');
    const s = a.vault.share(clip, (r) => r)[0]!;
    expect(s.kind).toBe('text'); // link only when the whole text is one URL (Mac rule)
    expect(a.vault.share(textClip(' https://example.com/x '), (r) => r)[0]!.kind).toBe('link');
    await a.e.enqueue(s.id);
    await until(() => !!b.vault.item(s.id));
    expect(b.vault.item(s.id)).toMatchObject({ text: 'Hallo Nico 👋 https://example.com', createdBy: 'Lena', kind: 'text' });
    expect(a.vault.pending.has(s.id)).toBe(false);
  });

  it('outbox survives offline + restart, then catches up', async () => {
    const { a, b } = await pairedPair();
    worker.offline = true;
    const s = a.vault.share(textClip('offline geschrieben'), (r) => r)[0]!;
    await a.e.enqueue(s.id);
    expect(JSON.parse(fs.readFileSync(path.join(a.dir, 'sync-queue.json'), 'utf8'))).toContain(s.id);
    // restart client A while offline
    a.e.stop();
    const a2 = new SyncEngine({ dir: a.dir, vault: a.vault, secrets: box, fetch: worker.fetch, ws: worker.ws, me: () => 'Lena', periodicMs: 3_600_000, pongTimeoutMs: 200, pingEveryMs: 400 });
    engines.push(a2);
    a2.start();
    expect(a2.snapshot().queue).toBe(1);
    worker.offline = false;
    await a2.flush();
    await b.e.catchUp();
    expect(b.vault.item(s.id)?.text).toBe('offline geschrieben');
  });

  it('uploads a big file in parts; partner auto-downloads and bytes match', async () => {
    const { a, b } = await pairedPair();
    const src = path.join(tmp, 'Video.mp4');
    const data = randomBytes(5 * 1024 * 1024 + 777);
    fs.writeFileSync(src, data);
    const clip: ClipItem = { ...textClip(''), kind: 'file', text: null, files: [{ name: 'Video.mp4', stored: null, orig: src }] };
    const s = a.vault.share(clip, (r) => r)[0]!;
    expect(s.parts).toBe(6);
    await a.e.enqueue(s.id);
    await a.e.idle();
    expect(worker.requests.filter((r) => r.includes('/parts/')).length).toBe(6);
    await until(() => { const it = b.vault.item(s.id); return !!it && b.vault.isLocal(it); }, 8000);
    expect(fs.readFileSync(b.vault.localPath(b.vault.item(s.id)!)!).equals(data)).toBe(true);
  });

  it('a tampered part is rejected and nothing is written', async () => {
    const { a, b } = await pairedPair();
    const src = path.join(tmp, 'x.bin');
    fs.writeFileSync(src, randomBytes(4 * 1024 * 1024 + 10));
    const s = a.vault.share({ ...textClip(''), kind: 'file', text: null, files: [{ name: 'x.bin', stored: null, orig: src }] }, (r) => r)[0]!;
    b.e.stop(); // B must not auto-download before we tamper
    await a.e.enqueue(s.id);
    await a.e.idle();
    const vault = [...worker.vaults.values()][0]!;
    const p = vault.parts.get(s.id.toLowerCase())!.get(1)!;
    p[40] = p[40]! ^ 0xff;
    const b2 = new SyncEngine({ dir: b.dir, vault: b.vault, secrets: box, fetch: worker.fetch, ws: worker.ws, me: () => 'Nico', periodicMs: 3_600_000 });
    engines.push(b2);
    b2.start();
    await b2.catchUp();
    const it = b.vault.item(s.id)!;
    expect(it).toBeTruthy();
    expect(b.vault.isLocal(it)).toBe(false);
    expect(fs.readdirSync(path.dirname(b.vault.localPath(it)!)).filter((f) => f.endsWith('.part'))).toEqual([]);
  });

  it('tombstones propagate; newer local edits win (last writer wins)', async () => {
    const { a, b } = await pairedPair();
    const s = a.vault.share(textClip('weg damit'), (r) => r)[0]!;
    await a.e.enqueue(s.id);
    await until(() => !!b.vault.item(s.id));
    a.vault.unshare(s.id);
    await a.e.enqueue(s.id);
    await until(() => b.vault.item(s.id)?.deleted === true);
    expect(b.vault.visible().find((i) => i.id === s.id)).toBeUndefined();
    // stale remote update must not overwrite a newer local state
    const cur = b.vault.item(s.id)!;
    b.vault.applyRemote([{ ...cur, deleted: false, text: 'alt', updatedAt: cur.updatedAt - 10 }]);
    expect(b.vault.item(s.id)?.deleted).toBe(true);
  });

  it('reconnects after a dead socket (no pong) with backoff', async () => {
    const { a } = await pairedPair();
    const sock = worker.sockets.find((s) => s.device === (JSON.parse(fs.readFileSync(path.join(a.dir, 'sync.json'), 'utf8')).deviceId));
    expect(sock).toBeTruthy();
    sock!.kill();
    await until(() => a.e.snapshot().state === 'offline', 8000);   // grosszuegig: unter Volllast (CI) dauert die Tot-Erkennung laenger
    await until(() => a.e.snapshot().state === 'connected', 10000);
  });

  it('rejects a wrong pairing code', async () => {
    const b = client('Nico');
    await expect(b.e.pairJoin('cvpair1.xyz')).rejects.toThrow(/Code nicht erkannt/);
  });
});
