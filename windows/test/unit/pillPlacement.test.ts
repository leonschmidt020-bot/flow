import { describe, expect, it } from 'vitest';
import { displayKey, isVertical, placementCenter, placementForDrop, presetCenter, sanitizePlacements, windowAround, PILL_PRESETS } from '../../src/shared/pillPlacement';
import { migrateSettings, DEFAULTS } from '../../src/shared/settings';

const wa = { x: 0, y: 0, width: 1920, height: 1032 }; // 1080p minus taskbar
const W = 460, H = 230;

describe('pill placement', () => {
  it('default = bottom centre, window exactly where it always was (centred, 6 px above the taskbar)', () => {
    const c = placementCenter(undefined, wa);
    const g = windowAround(c, W, H, wa);
    expect(g).toMatchObject({ x: (1920 - W) / 2, y: 1032 - H - 6, ax: W / 2, ay: H - 26, below: false });
    expect(isVertical(c, wa)).toBe(false);
  });
  it('middle right: upright, window stays on screen, capsule near the right window edge', () => {
    const c = presetCenter('middleRight', wa);
    expect(isVertical(c, wa)).toBe(true);
    const g = windowAround(c, W, H, wa);
    expect(g.x + W).toBe(1920);
    expect(g.ax).toBe(W - 18);
    expect(g.below).toBe(false);
  });
  it('top: cards go below the capsule', () => {
    const g = windowAround(presetCenter('topCenter', wa), W, H, wa);
    expect(g.below).toBe(true);
    expect(g.y).toBeGreaterThanOrEqual(0);
    expect(g.ay).toBe(26);
  });
  it('second monitor left of the main one (negative coordinates)', () => {
    const left = { x: -1280, y: 0, width: 1280, height: 984 };
    const g = windowAround(presetCenter('bottomLeft', left), W, H, left);
    expect(g.x).toBe(-1280);
    expect(g.ax).toBeLessThan(W / 2);
  });
  it('a drop near a preset snaps, elsewhere it is stored relative to the work area', () => {
    const near = presetCenter('topRight', wa);
    expect(placementForDrop({ x: near.x - 20, y: near.y + 15 }, wa)).toEqual({ preset: 'topRight' });
    const free = placementForDrop({ x: 960, y: 516 }, wa);
    expect(free).toEqual({ fx: 0.5, fy: 0.5 });
    // a relative spot follows a resolution change
    const c = placementCenter(free, { x: 0, y: 0, width: 2560, height: 1392 });
    expect(c).toEqual({ x: 1280, y: 696 });
  });
  it('every preset is on the screen', () => {
    for (const p of PILL_PRESETS) {
      const c = presetCenter(p, wa);
      expect(c.x).toBeGreaterThan(0); expect(c.x).toBeLessThan(1920);
      expect(c.y).toBeGreaterThan(0); expect(c.y).toBeLessThan(1032);
    }
  });
  it('settings: garbage is dropped, valid spots kept', () => {
    expect(sanitizePlacements({ a: { preset: 'middleRight' }, b: { fx: 2, fy: -1 }, c: { preset: 'nope' }, d: 'x' })).toEqual({ a: { preset: 'middleRight' }, b: { fx: 1, fy: 0 } });
    expect(DEFAULTS.pillPlacements).toEqual({});
    expect(migrateSettings({ pillPlacements: { 'Dell|1920x1080': { preset: 'topLeft' } } }).pillPlacements).toEqual({ 'Dell|1920x1080': { preset: 'topLeft' } });
    expect(migrateSettings({}).hotkeyHintDone).toBe(false);
  });
  it('display key: same monitor → same key', () => {
    expect(displayKey({ label: 'DELL U2720Q', size: { width: 2560, height: 1440 } })).toBe('DELL U2720Q|2560x1440');
    expect(displayKey({ label: '', size: { width: 1920, height: 1080 } })).toBe('display|1920x1080');
  });
});
