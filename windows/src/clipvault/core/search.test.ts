import { describe, expect, it } from 'vitest';
import { filterItems, groupByDay, countByType, matchesType } from './search';
import { detectBadges, soleURL, parseColor } from './badges';
import type { ClipItem } from './types';

const T0 = new Date(2026, 8, 27, 12, 0, 0).getTime() / 1000;
const items: ClipItem[] = [
  { id: '1', kind: 'text', text: 'Rechnung Mai für Müller', ts: T0 - 10 },
  { id: '2', kind: 'text', text: 'https://tessera.example.app/login', ts: T0 - 20 },
  { id: '3', kind: 'text', text: 'Schau mal https://example.com an', ts: T0 - 30 },
  { id: '4', kind: 'image', image: '4.png', ocrText: 'Kontoauszug Sparkasse', ts: T0 - 40 },
  { id: '5', kind: 'file', files: [{ name: 'Vertrag_Final.pdf', stored: null, orig: 'C:\\x\\Vertrag_Final.pdf' }], ts: T0 - 86400 },
  { id: '6', kind: 'text', text: 'angeheftet', ts: T0 - 3 * 86400, pinned: true },
  { id: '7', kind: 'text', text: 'Arbeitsnotiz', ts: T0 - 50, collection: 'C1' },
];

describe('type filters (Mac rules)', () => {
  it('Text excludes sole URLs, Links = any text with a link', () => {
    expect(filterItems(items, { type: 'text' }).map((i) => i.id)).toEqual(['6', '1', '3']);
    expect(filterItems(items, { type: 'links' }).map((i) => i.id)).toEqual(['2', '3']);
    expect(filterItems(items, { type: 'images' }).map((i) => i.id)).toEqual(['4']);
    expect(filterItems(items, { type: 'files' }).map((i) => i.id)).toEqual(['5']);
  });
  it('history view excludes collection entries; collection view shows only them', () => {
    expect(filterItems(items, {}).map((i) => i.id)).not.toContain('7');
    expect(filterItems(items, { collection: 'C1' }).map((i) => i.id)).toEqual(['7']);
    expect(filterItems(items, { collection: '*' }).length).toBe(7);
  });
  it('entries of a deleted collection fall back to the history', () => {
    expect(filterItems(items, { knownCollections: new Set() }).map((i) => i.id)).toContain('7');
  });
});

describe('search', () => {
  it('searches text, OCR text and file names; case/diacritics-insensitive; all words', () => {
    expect(filterItems(items, { query: 'mueller' }).length).toBe(0);
    expect(filterItems(items, { query: 'MÜLLER' }).map((i) => i.id)).toEqual(['1']);
    expect(filterItems(items, { query: 'muller rechnung' }).map((i) => i.id)).toEqual(['1']);
    expect(filterItems(items, { query: 'sparkasse' }).map((i) => i.id)).toEqual(['4']);
    expect(filterItems(items, { query: 'vertrag' }).map((i) => i.id)).toEqual(['5']);
    expect(filterItems(items, { query: 'vertrag', type: 'images' })).toEqual([]);
  });
  it('pinned first, then newest first', () => {
    expect(filterItems(items, {})[0]!.id).toBe('6');
  });
  it('counts per type follow the search', () => {
    expect(countByType(items, { query: 'https' })).toEqual({ all: 2, text: 1, links: 2, images: 0, files: 0 });
  });
});

describe('grouping', () => {
  it('pinned, today, yesterday, older days', () => {
    const g = groupByDay(filterItems(items, {}), T0 * 1000);
    expect(g.map((s) => s.key)).toEqual(['pinned', 'today', 'yesterday']);
    expect(g[1]!.items.map((i) => i.id)).toEqual(['1', '2', '3', '4']);
  });
});

describe('badges', () => {
  it('detects link/email/phone/color/code without obvious false positives', () => {
    expect(soleURL('  https://a.de/x?y=1 ')).toBe('https://a.de/x?y=1');
    expect(soleURL('see https://a.de')).toBeNull();
    expect(detectBadges('lena@example.com')).toContain('email');
    expect(detectBadges('+49 5231 123456')).toContain('phone');
    expect(detectBadges('2026-09-27')).not.toContain('phone');
    expect(detectBadges('12345678')).not.toContain('phone');
    expect(parseColor('#34C759')).toBe('#34C759');
    expect(detectBadges('rgb(52, 199, 89)')).toContain('color');
    expect(detectBadges('const x = () => {\n  return a && b;\n}')).toContain('code');
    expect(detectBadges('Ganz normaler Satz ohne alles.')).toEqual([]);
    expect(matchesType({ id: 'x', kind: 'text', text: 'http://a.b', ts: 0 }, 'text')).toBe(false);
  });
});
