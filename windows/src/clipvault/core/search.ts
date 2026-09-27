// Search + filters + grouping (Mac PROTOCOL.md §2 display rules).
//   - "Verlauf" = collection == null; pinned on top ("Angeheftet"), rest grouped by day.
//   - Bereich X  = collection == X.
//   - type filter: Text = text without a sole URL · Links = text with a link badge · Bilder · Dateien
//   - search: text, ocrText and file names, case-insensitive; all words must match (any order).
import { detectBadges, soleURL } from './badges';
import type { ClipItem, TypeFilter } from './types';

export interface ListQuery {
  query?: string;
  type?: TypeFilter;
  /** undefined/null = history; '*' = everything; otherwise a collection id */
  collection?: string | null;
  /** collections that still exist (entries pointing at deleted ones count as history) */
  knownCollections?: Set<string>;
}

export function matchesType(it: ClipItem, type: TypeFilter): boolean {
  switch (type) {
    case 'all': return true;
    case 'images': return it.kind === 'image';
    case 'files': return it.kind === 'file';
    case 'links': return it.kind === 'text' && detectBadges(it.text ?? '').includes('link');
    case 'text': return it.kind === 'text' && !soleURL(it.text);
  }
}

function fold(s: string): string {
  return s.toLocaleLowerCase('de').normalize('NFKD').replace(/[̀-ͯ]/g, '');
}

export function haystack(it: ClipItem): string {
  const parts: string[] = [];
  if (it.text) parts.push(it.text);
  if (it.ocrText) parts.push(it.ocrText);
  for (const f of it.files ?? []) parts.push(f.name);
  if (it.source) parts.push(it.source);
  return fold(parts.join('\n'));
}

export function matchesQuery(it: ClipItem, query: string | undefined): boolean {
  const q = fold((query ?? '').trim());
  if (!q) return true;
  const hay = haystack(it);
  return q.split(/\s+/).every((w) => hay.includes(w));
}

export function inScope(it: ClipItem, q: ListQuery): boolean {
  if (q.collection === '*') return true;
  const own = it.collection && (!q.knownCollections || q.knownCollections.has(it.collection)) ? it.collection : null;
  return (q.collection ?? null) === own;
}

/** Filtered list in display order: pinned first (history view), then newest first. */
export function filterItems(items: ClipItem[], q: ListQuery): ClipItem[] {
  const type = q.type ?? 'all';
  const out = items.filter((it) => inScope(it, q) && matchesType(it, type) && matchesQuery(it, q.query));
  out.sort((a, b) => (Number(!!b.pinned) - Number(!!a.pinned)) || b.ts - a.ts);
  return out;
}

export interface Section<T> {
  key: string; // 'pinned' | 'today' | 'yesterday' | 'YYYY-MM-DD'
  items: T[];
}

function dayKey(tsSec: number): string {
  const d = new Date(tsSec * 1000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function groupByDay<T extends { ts: number; pinned?: boolean }>(list: T[], nowMs = Date.now()): Section<T>[] {
  const today = dayKey(nowMs / 1000);
  const yesterday = dayKey(nowMs / 1000 - 86400);
  const out: Section<T>[] = [];
  const pinned = list.filter((x) => x.pinned);
  if (pinned.length) out.push({ key: 'pinned', items: pinned });
  for (const x of list) {
    if (x.pinned) continue;
    const k = dayKey(x.ts);
    const key = k === today ? 'today' : k === yesterday ? 'yesterday' : k;
    const last = out[out.length - 1];
    if (last && last.key === key) last.items.push(x);
    else out.push({ key, items: [x] });
  }
  return out;
}

export function countByType(items: ClipItem[], q: ListQuery): Record<TypeFilter, number> {
  const base = items.filter((it) => inScope(it, q) && matchesQuery(it, q.query));
  return {
    all: base.length,
    text: base.filter((i) => matchesType(i, 'text')).length,
    links: base.filter((i) => matchesType(i, 'links')).length,
    images: base.filter((i) => matchesType(i, 'images')).length,
    files: base.filter((i) => matchesType(i, 'files')).length,
  };
}
