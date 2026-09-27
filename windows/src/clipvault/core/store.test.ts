import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { Store, ENC_MAGIC, type IndexCodec } from './store';
import { writeFileAtomic } from './atomic';

let dir: string;
let clock: number;
const now = () => clock;
const mk = (extra: Partial<ConstructorParameters<typeof Store>[1]> = {}) => {
  const s = new Store(dir, { now, ...extra });
  s.load();
  return s;
};
const png = (n: number) => Buffer.alloc(n, 7);

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cv-store-test-'));
  clock = 1_790_000_000_000;
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('atomic write', () => {
  it('replaces the file in one step and leaves no temp files', () => {
    const f = path.join(dir, 'x.json');
    writeFileAtomic(f, 'one');
    writeFileAtomic(f, 'two');
    expect(fs.readFileSync(f, 'utf8')).toBe('two');
    expect(fs.readdirSync(dir).filter((n) => n.includes('.tmp-'))).toEqual([]);
  });

  it('persists, reloads, and keeps Mac-compatible fields', () => {
    const s = mk();
    s.addText('Hallo https://example.com');
    const raw = JSON.parse(fs.readFileSync(s.indexPath, 'utf8'));
    expect(raw[0]).toMatchObject({ kind: 'text', text: 'Hallo https://example.com', badges: ['link'] });
    expect(typeof raw[0].ts).toBe('number');
    const s2 = mk();
    expect(s2.items[0]!.text).toBe('Hallo https://example.com');
  });
});

describe('corruption recovery', () => {
  it('falls back to the backup copy and keeps the broken file', () => {
    const s = mk();
    s.addText('eins');
    clock += 61_000;
    s.addText('zwei'); // this save backs up the version with "eins"
    fs.writeFileSync(s.indexPath, '{"kaputt": ');
    const s2 = mk();
    expect(s2.lastRecovery).toBe('backup');
    expect(s2.items.map((i) => i.text)).toContain('eins');
    expect(fs.readFileSync(s2.brokenPath, 'utf8')).toBe('{"kaputt": ');
    // the recovered state was written back as a valid index
    expect(() => JSON.parse(fs.readFileSync(s2.indexPath, 'utf8'))).not.toThrow();
  });

  it('starts empty (but does not crash) when index and backup are both broken', () => {
    fs.writeFileSync(path.join(dir, 'index.json'), '\u0000\u0001garbage');
    fs.writeFileSync(path.join(dir, 'index.bak.json'), 'also garbage');
    const s = mk();
    expect(s.items).toEqual([]);
    expect(s.lastRecovery).toBe('empty');
  });

  it('never backs up a corrupt file over a good backup', () => {
    const s = mk();
    s.addText('gut');
    clock += 61_000;
    s.addText('auch gut');
    const goodBak = fs.readFileSync(s.backupPath, 'utf8');
    fs.writeFileSync(s.indexPath, 'broken');
    clock += 61_000;
    s.addText('danach');
    expect(fs.readFileSync(s.backupPath, 'utf8')).toBe(goodBak);
  });

  it('encrypted index: round-trips with the codec, stays read-only without it', () => {
    const codec: IndexCodec = { name: 'test', protect: (b) => Buffer.from(b).reverse(), unprotect: (b) => Buffer.from(b).reverse() };
    const s = mk({ codec });
    s.addText('geheim');
    const raw = fs.readFileSync(s.indexPath);
    expect(raw.subarray(0, ENC_MAGIC.length).equals(ENC_MAGIC)).toBe(true);
    expect(raw.toString('utf8')).not.toContain('geheim');
    expect(mk({ codec }).items[0]!.text).toBe('geheim');
    const locked = mk();
    expect(locked.readOnly).toBe(true);
    locked.addText('darf nicht schreiben');
    expect(fs.readFileSync(s.indexPath).equals(raw)).toBe(true);
    // switching encryption off rewrites plain JSON
    const s3 = mk({ codec });
    s3.setCodec(null);
    expect(JSON.parse(fs.readFileSync(s.indexPath, 'utf8'))[0].text).toBe('geheim');
  });
});

describe('retention', () => {
  it('drops history older than 2 days, keeps pinned and collection entries forever', () => {
    const s = mk();
    const a = s.addText('alt').item;
    const p = s.addText('angeheftet').item;
    s.setPinned(p.id, true);
    const c = s.addText('im Bereich').item;
    const work = s.collections.find((x) => !x.secret)!;
    s.setCollection(c.id, work.id);
    clock += 2 * 24 * 3600 * 1000 + 1000;
    s.addText('neu');
    const texts = s.items.map((i) => i.text);
    expect(texts).toContain('angeheftet');
    expect(texts).toContain('im Bereich');
    expect(texts).toContain('neu');
    expect(texts).not.toContain('alt');
    expect(s.item(a.id)).toBeUndefined();
  });

  it('secret collection entries expire after 24 h unless pinned', () => {
    const s = mk();
    const pw = s.collections.find((x) => x.secret)!;
    const a = s.addText('pw-1').item;
    const b = s.addText('pw-2').item;
    s.setCollection(a.id, pw.id);
    s.setCollection(b.id, pw.id);
    s.setPinned(b.id, true);
    clock += 25 * 3600 * 1000;
    s.prune();
    expect(s.item(a.id)).toBeUndefined();
    expect(s.item(b.id)).toBeTruthy();
  });

  it('caps history at 200 entries (pinned/collection entries do not count)', () => {
    const s = mk();
    const keep = s.addText('bleibt').item;
    s.setPinned(keep.id, true);
    for (let i = 0; i < 230; i++) { clock += 10; s.addText(`t${i}`); }
    const hist = s.items.filter((i) => !i.pinned && !i.collection);
    expect(hist.length).toBe(200);
    expect(s.item(keep.id)).toBeTruthy();
    expect(s.items.find((i) => i.text === 't0')).toBeUndefined();
    expect(s.items.find((i) => i.text === 't229')).toBeTruthy();
  });

  it('size quota drops the oldest images and removes their files', () => {
    const s = mk({ limits: { quotaBytes: 250_000 } });
    const ids: string[] = [];
    for (let i = 0; i < 4; i++) {
      clock += 1000;
      ids.push(s.addImage({ png: png(100_000), w: 10 + i, h: 10 }).item.id);
    }
    expect(s.totalBytes()).toBeLessThanOrEqual(250_000);
    expect(s.item(ids[0]!)).toBeUndefined();
    expect(fs.existsSync(path.join(dir, `${ids[0]}.png`))).toBe(false);
    expect(s.item(ids[3]!)).toBeTruthy();
  });

  it('deleting an entry removes its image, thumbnail and copied files', () => {
    const s = mk();
    const img = s.addImage({ png: png(10), thumbPng: png(5), w: 1, h: 1 }).item;
    const src = path.join(dir, 'quelle.txt');
    fs.writeFileSync(src, 'inhalt');
    const f = s.addFiles([src])!.item;
    expect(fs.existsSync(path.join(dir, 'files', f.id, 'quelle.txt'))).toBe(true);
    s.delete(img.id);
    s.delete(f.id);
    expect(fs.existsSync(path.join(dir, `${img.id}.png`))).toBe(false);
    expect(fs.existsSync(path.join(dir, 'thumbs', `${img.id}.png`))).toBe(false);
    expect(fs.existsSync(path.join(dir, 'files', f.id))).toBe(false);
    expect(fs.existsSync(src)).toBe(true); // the original is never touched
  });

  it('deleting a collection returns its entries to the history', () => {
    const s = mk();
    const it = s.addText('x').item;
    const c = s.createCollection('Rezepte');
    s.setCollection(it.id, c.id);
    s.deleteCollection(c.id);
    expect(s.item(it.id)?.collection).toBeNull();
  });
});
