// Duplicate detection – port of the Mac imagededupe.swift (27.09.2026).
//
// Same picture, different bytes (clipboard copy without metadata vs. the original PNG) must become ONE entry,
// but two screenshots taken on purpose a second apart with a tiny change (one typed character, a cursor)
// must stay separate.
//   1. quick filter: same pixel size + 16×16 gray print, mean diff <= 2.5 and max diff <= 16
//   2. fine check on a 256 px (long edge) gray raster: NO pixel may differ by more than 12 levels
// Only within 3 minutes of the older entry's last use.

export const PRINT_SIDE = 16;
export const FINE_LONG_EDGE = 256;
export const IMAGE_TWIN_WINDOW_SEC = 180;

export interface ImagePrint {
  w: number;
  h: number;
  gray: Uint8Array; // PRINT_SIDE * PRINT_SIDE
}

export interface Bitmap {
  width: number;
  height: number;
  /** 4 bytes per pixel */
  data: Uint8Array;
  /** channel order; Electron's nativeImage.toBitmap() is BGRA */
  order: 'rgba' | 'bgra';
}

/** Box-filter a bitmap into an outW×outH gray raster. Transparency is composited over white (like the Mac). */
export function grayRaster(bm: Bitmap, outW: number, outH: number): Uint8Array {
  const out = new Uint8Array(outW * outH);
  const { width: w, height: h, data } = bm;
  const rI = bm.order === 'rgba' ? 0 : 2;
  const bI = bm.order === 'rgba' ? 2 : 0;
  for (let oy = 0; oy < outH; oy++) {
    const y0 = Math.floor((oy * h) / outH);
    const y1 = Math.max(y0 + 1, Math.floor(((oy + 1) * h) / outH));
    for (let ox = 0; ox < outW; ox++) {
      const x0 = Math.floor((ox * w) / outW);
      const x1 = Math.max(x0 + 1, Math.floor(((ox + 1) * w) / outW));
      let sum = 0;
      let n = 0;
      for (let y = y0; y < y1 && y < h; y++) {
        let p = (y * w + x0) * 4;
        for (let x = x0; x < x1 && x < w; x++, p += 4) {
          const a = (data[p + 3] ?? 255) / 255;
          const r = (data[p + rI] ?? 0) * a + 255 * (1 - a);
          const g = (data[p + 1] ?? 0) * a + 255 * (1 - a);
          const b = (data[p + bI] ?? 0) * a + 255 * (1 - a);
          sum += 0.299 * r + 0.587 * g + 0.114 * b;
          n++;
        }
      }
      out[oy * outW + ox] = n ? Math.round(sum / n) : 255;
    }
  }
  return out;
}

export function makePrint(bm: Bitmap, fullW = bm.width, fullH = bm.height): ImagePrint {
  return { w: fullW, h: fullH, gray: grayRaster(bm, PRINT_SIDE, PRINT_SIDE) };
}

export function fineSize(w: number, h: number): { fw: number; fh: number } {
  const s = FINE_LONG_EDGE / Math.max(w, h);
  return { fw: Math.max(1, Math.round(w * s)), fh: Math.max(1, Math.round(h * s)) };
}

export function fineRaster(bm: Bitmap, fullW = bm.width, fullH = bm.height): Uint8Array {
  const { fw, fh } = fineSize(fullW, fullH);
  return grayRaster(bm, fw, fh);
}

export function roughlyMatches(a: ImagePrint, b: ImagePrint): boolean {
  if (a.w !== b.w || a.h !== b.h || a.gray.length !== b.gray.length) return false;
  let sum = 0;
  let mx = 0;
  for (let i = 0; i < a.gray.length; i++) {
    const d = Math.abs(a.gray[i]! - b.gray[i]!);
    sum += d;
    if (d > mx) mx = d;
  }
  return sum / a.gray.length <= 2.5 && mx <= 16;
}

export function finesLookSame(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (Math.abs(a[i]! - b[i]!) > 12) return false;
  return true;
}

export function printToHex(p: ImagePrint): string {
  return Buffer.from(p.gray).toString('hex');
}

export function printFromHex(hex: string | null | undefined, w: number | undefined, h: number | undefined): ImagePrint | null {
  if (!hex || !w || !h || hex.length !== PRINT_SIDE * PRINT_SIDE * 2 || !/^[0-9a-f]+$/i.test(hex)) return null;
  return { w, h, gray: new Uint8Array(Buffer.from(hex, 'hex')) };
}

/** Texts that differ only in surrounding whitespace are the same entry (Mac store.swift, 27.09.2026). */
export function textKey(s: string): string {
  return s.trim();
}

/** Same set of original paths (in order) = same file entry. */
export function filesKey(paths: string[]): string {
  return paths.map((p) => p.replace(/\\/g, '/').toLowerCase()).join('\u0000');
}
