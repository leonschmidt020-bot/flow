// Where the pill sits (pure – unit-tested). Like the Mac (PillPreset/PillPlacement): eight presets, or a free spot
// stored relative to the screen's work area, per screen. At the left/right edge the pill stands upright.

export type PillPreset = 'bottomCenter' | 'bottomLeft' | 'bottomRight' | 'middleRight' | 'middleLeft' | 'topCenter' | 'topRight' | 'topLeft';
export const PILL_PRESETS: PillPreset[] = ['bottomCenter', 'bottomLeft', 'bottomRight', 'middleRight', 'middleLeft', 'topCenter', 'topRight', 'topLeft'];
export interface PillPlacement { preset?: PillPreset; fx?: number; fy?: number }
export interface Rect { x: number; y: number; width: number; height: number }
export interface Point { x: number; y: number }

/** distance of the capsule centre from the bottom/top edge (bottom centre = where the pill always was) */
export const EDGE_Y = 32;
/** upright pill at the left/right edge: centre this far from the edge */
export const EDGE_X = 18;
/** a drop this close to a preset snaps to it */
export const SNAP_PX = 60;

export function presetCenter(p: PillPreset, wa: Rect): Point {
  const l = wa.x + 22 + 40, r = wa.x + wa.width - 22 - 40, b = wa.y + wa.height - EDGE_Y, t = wa.y + EDGE_Y;
  const mx = wa.x + wa.width / 2, my = wa.y + wa.height / 2;
  switch (p) {
    case 'bottomLeft': return { x: l, y: b };
    case 'bottomRight': return { x: r, y: b };
    case 'middleRight': return { x: wa.x + wa.width - EDGE_X, y: my };
    case 'middleLeft': return { x: wa.x + EDGE_X, y: my };
    case 'topCenter': return { x: mx, y: t };
    case 'topRight': return { x: r, y: t };
    case 'topLeft': return { x: l, y: t };
    default: return { x: mx, y: b };
  }
}

const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));

export function placementCenter(pl: PillPlacement | undefined, wa: Rect): Point {
  if (!pl || pl.preset || typeof pl.fx !== 'number' || typeof pl.fy !== 'number') return presetCenter(pl?.preset ?? 'bottomCenter', wa);
  return {
    x: clamp(wa.x + pl.fx * wa.width, wa.x + EDGE_X, wa.x + wa.width - EDGE_X),
    y: clamp(wa.y + pl.fy * wa.height, wa.y + EDGE_X, wa.y + wa.height - EDGE_X),
  };
}

/** upright at the left/right edge (like the Mac: outer 8 % of the width) */
export function isVertical(c: Point, wa: Rect): boolean {
  const fx = (c.x - wa.x) / Math.max(1, wa.width);
  return fx < 0.08 || fx > 0.92;
}

/** placement for a drop at `p`: a preset when close to one, else the relative spot */
export function placementForDrop(p: Point, wa: Rect): PillPlacement {
  let best: PillPreset | null = null, bestD = Infinity;
  for (const pr of PILL_PRESETS) {
    const c = presetCenter(pr, wa);
    const d = Math.hypot(c.x - p.x, c.y - p.y);
    if (d < SNAP_PX && d < bestD) { best = pr; bestD = d; }
  }
  if (best) return { preset: best };
  const r = (v: number) => Math.round(v * 10000) / 10000;
  return { fx: r(clamp((p.x - wa.x) / Math.max(1, wa.width), 0, 1)), fy: r(clamp((p.y - wa.y) / Math.max(1, wa.height), 0, 1)) };
}

/** key of a screen in the settings (the same monitor keeps its spot; a new one starts at the bottom centre) */
export function displayKey(d: { label?: string; size: { width: number; height: number } }): string {
  return `${(d.label || 'display').trim().slice(0, 60)}|${d.size.width}x${d.size.height}`;
}

/**
 * Window around the capsule: the window must stay on the screen, so the capsule is not always in the window centre.
 * Cards and toasts go above the capsule, or below it when the pill sits near the top edge.
 * Returns the window bounds and where the capsule centre is inside the window.
 */
export function windowAround(c: Point, W: number, H: number, wa: Rect, bottomGap = 26): { x: number; y: number; ax: number; ay: number; below: boolean } {
  const below = c.y - wa.y < H - bottomGap;
  let y = below ? c.y - bottomGap : c.y - (H - bottomGap);
  y = clamp(y, wa.y, wa.y + wa.height - H);
  const x = clamp(Math.round(c.x - W / 2), wa.x, wa.x + wa.width - W);
  return { x: Math.round(x), y: Math.round(y), ax: Math.round(c.x - x), ay: Math.round(c.y - y), below };
}

export function sanitizePlacements(v: unknown): Record<string, PillPlacement> {
  const out: Record<string, PillPlacement> = {};
  if (!v || typeof v !== 'object' || Array.isArray(v)) return out;
  for (const [k, raw] of Object.entries(v as Record<string, unknown>).slice(0, 20)) {
    if (!raw || typeof raw !== 'object') continue;
    const o = raw as Record<string, unknown>;
    if (typeof o.preset === 'string' && (PILL_PRESETS as string[]).includes(o.preset)) out[k.slice(0, 100)] = { preset: o.preset as PillPreset };
    else if (typeof o.fx === 'number' && typeof o.fy === 'number' && Number.isFinite(o.fx) && Number.isFinite(o.fy)) {
      out[k.slice(0, 100)] = { fx: clamp(o.fx, 0, 1), fy: clamp(o.fy, 0, 1) };
    }
  }
  return out;
}
