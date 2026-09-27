import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { makePrint, fineRaster, roughlyMatches, finesLookSame, type Bitmap } from './dedupe';
import { Store } from './store';

/** synthetic "screenshot": gradient + some text-like blocks */
function shot(w: number, h: number, mutate?: (px: Uint8Array, w: number) => void, order: 'rgba' | 'bgra' = 'rgba'): Bitmap {
  const data = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const p = (y * w + x) * 4;
    const v = (x * 255) / w;
    const block = (Math.floor(x / 40) + Math.floor(y / 25)) % 3 === 0 ? 60 : 0;
    data[p] = Math.max(0, v - block); data[p + 1] = Math.max(0, 200 - block); data[p + 2] = Math.max(0, 255 - v - block); data[p + 3] = 255;
  }
  mutate?.(data, w);
  return { width: w, height: h, data, order };
}

describe('perceptual image dedupe', () => {
  it('same pixels (e.g. RGBA vs BGRA source, re-encoded) match', () => {
    const a = shot(800, 500);
    const b = shot(800, 500);
    // same image delivered in BGRA order (Electron nativeImage)
    const bgra = new Uint8Array(b.data);
    for (let i = 0; i < bgra.length; i += 4) { const r = bgra[i]!; bgra[i] = bgra[i + 2]!; bgra[i + 2] = r; }
    const b2: Bitmap = { ...b, data: bgra, order: 'bgra' };
    expect(roughlyMatches(makePrint(a), makePrint(b2))).toBe(true);
    expect(finesLookSame(fineRaster(a), fineRaster(b2))).toBe(true);
  });

  it('tiny colour-profile rounding (±2) still matches', () => {
    const a = shot(640, 400);
    const b = shot(640, 400, (px) => { for (let i = 0; i < px.length; i += 4) px[i] = Math.min(255, px[i]! + 2); });
    expect(roughlyMatches(makePrint(a), makePrint(b))).toBe(true);
    expect(finesLookSame(fineRaster(a), fineRaster(b))).toBe(true);
  });

  it('one typed character / cursor stays separate (fine check catches it)', () => {
    const a = shot(1920, 1080);
    const b = shot(1920, 1080, (px, w) => {
      for (let y = 500; y < 530; y++) for (let x = 900; x < 916; x++) { const p = (y * w + x) * 4; px[p] = px[p + 1] = px[p + 2] = 255; }
    });
    expect(roughlyMatches(makePrint(a), makePrint(b))).toBe(true); // coarse print can't see it…
    expect(finesLookSame(fineRaster(a), fineRaster(b))).toBe(false); // …the fine raster can
  });

  it('different size never matches', () => {
    expect(roughlyMatches(makePrint(shot(800, 500)), makePrint(shot(801, 500)))).toBe(false);
  });

  it('transparency is composited over white', () => {
    const t: Bitmap = { width: 2, height: 2, data: new Uint8Array(16), order: 'rgba' };
    expect([...makePrint(t).gray].every((g) => g === 255)).toBe(true);
  });
});

describe('store dedupe', () => {
  let dir: string;
  let clock = 1_790_000_000_000;
  beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cv-dedupe-test-')); });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('merges an image twin within 3 minutes, keeps separate after', () => {
    const s = new Store(dir, { now: () => clock });
    s.load();
    const bm = shot(300, 200);
    const fine = fineRaster(bm);
    const loadFine = () => fine;
    const first = s.addImage({ png: Buffer.from('A'), w: 300, h: 200, print: makePrint(bm), fine }, null, null, loadFine);
    clock += 60_000;
    const twin = s.addImage({ png: Buffer.from('B'), w: 300, h: 200, print: makePrint(bm), fine }, null, 'C:\\Shots\\a.png', loadFine);
    expect(twin.isNew).toBe(false);
    expect(twin.item.id).toBe(first.item.id);
    expect(twin.item.origin).toBe('C:\\Shots\\a.png');
    expect(s.items.filter((i) => i.kind === 'image').length).toBe(1);
    clock += 200_000;
    const later = s.addImage({ png: Buffer.from('C'), w: 300, h: 200, print: makePrint(bm), fine }, null, null, loadFine);
    expect(later.isNew).toBe(true);
  });

  it('text: same text or same text with extra whitespace = one entry moved to the top', () => {
    const s = new Store(dir, { now: () => clock });
    s.load();
    const a = s.addText('Schick Nico');
    s.addText('anderes');
    const b = s.addText('Schick Nico\n');
    expect(b.isNew).toBe(false);
    expect(b.item.id).toBe(a.item.id);
    expect(s.items[0]!.id).toBe(a.item.id);
  });

  it('files: same path list = one entry', () => {
    const s = new Store(dir, { now: () => clock });
    s.load();
    const f = path.join(dir, 'a.txt');
    fs.writeFileSync(f, 'x');
    const a = s.addFiles([f])!;
    const b = s.addFiles([f.toUpperCase() === f ? f : f])!;
    expect(b.item.id).toBe(a.item.id);
  });
});
