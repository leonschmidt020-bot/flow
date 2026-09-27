// Turn store items into what the UI shows (titles, subtitles, masking). Pure – unit-testable.
import { pathToFileURL } from 'node:url';
import { detectBadges, parseColor, soleURL } from './badges';
import { filterItems, groupByDay, countByType, type ListQuery } from './search';
import type { Store } from './store';
import type { ClipItem, Collection, ItemView, TypeFilter } from './types';

export interface ListResult {
  sections: { key: string; items: ItemView[] }[];
  counts: Record<TypeFilter, number>;
  collections: (Collection & { count: number; secret: boolean })[];
  historyCount: number;
  total: number;
}

function firstLine(s: string, max = 140): string {
  const line = s.split(/\r?\n/).map((l) => l.trim()).find((l) => l.length > 0) ?? '';
  return line.length > max ? line.slice(0, max - 1) + '…' : line;
}

export function fileUrl(abs: string | null, ts?: number): string | undefined {
  if (!abs) return undefined;
  return pathToFileURL(abs).href + (ts ? `?v=${Math.round(ts)}` : '');
}

export function toView(it: ClipItem, store: Store, opts: { full?: boolean; revealSecrets?: boolean; locale?: 'de' | 'en' } = {}): ItemView {
  const de = (opts.locale ?? 'de') === 'de';
  const secret = store.isSecret(it.collection);
  const masked = secret && !opts.revealSecrets;
  const badges = it.kind === 'text' && !masked ? detectBadges(it.text ?? '') : [];
  const link = it.kind === 'text' ? soleURL(it.text) : null;
  let title: string;
  if (masked) title = '••••••••••••';
  else if (it.kind === 'image') {
    const o = (it.ocrText ?? '').split('\n').find((l) => l.trim().length >= 3);
    title = (de ? 'Bild' : 'Image') + (o ? ' · ' + o.trim().slice(0, 70) : it.w && it.h ? ` · ${it.w}×${it.h}` : '');
  } else if (it.kind === 'file') {
    const f = it.files ?? [];
    title = f.length === 1 ? f[0]!.name : `${f.length} ${de ? 'Dateien' : 'files'} · ${f.map((x) => x.name).join(', ')}`;
  } else title = firstLine(it.text ?? '') || (de ? '(leer)' : '(empty)');

  const bits: string[] = [];
  if (it.kind === 'text' && !masked) {
    const n = (it.text ?? '').length;
    bits.push(link ? new URL(link).host : `${n.toLocaleString(de ? 'de-DE' : 'en-US')} ${de ? 'Zeichen' : 'chars'}`);
  }
  if (it.kind === 'file') {
    const total = (it.files ?? []).reduce((s, f) => s + (f.size ?? 0), 0);
    if (total) bits.push(total > 1e6 ? `${(total / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(total / 1e3))} KB`);
  }
  if (it.source) bits.push(it.source);
  const exp = store.secretExpiry(it);
  const v: ItemView = {
    id: it.id, kind: it.kind, isLink: !!link, title, subtitle: bits.join(' · '), badges: masked ? [] : badges,
    ts: it.ts, pinned: !!it.pinned, collection: it.collection && store.collection(it.collection) ? it.collection : null,
    masked, shared: !!it.shared, source: it.source ?? null,
    expiresInH: exp === null ? null : Math.max(0, Math.ceil((exp - Date.now() / 1000) / 3600)),
  };
  if (it.kind === 'image') {
    v.thumbUrl = fileUrl(store.thumbPath(it) ?? store.imagePath(it), it.ts);
    v.imageUrl = fileUrl(store.imagePath(it), it.ts);
    v.w = it.w; v.h = it.h;
  }
  if (it.kind === 'file') v.fileNames = (it.files ?? []).map((f) => f.name);
  if (!masked && it.kind === 'text') {
    const c = parseColor(it.text);
    if (c) v.color = c;
    v.text = opts.full ? it.text ?? '' : (it.text ?? '').slice(0, 2000);
  }
  if (!masked && it.kind === 'image' && it.ocrText) v.text = it.ocrText;
  return v;
}

export function buildList(store: Store, q: ListQuery & { locale?: 'de' | 'en' }): ListResult {
  const known = new Set(store.collections.map((c) => c.id));
  const query = { ...q, knownCollections: known };
  const list = filterItems(store.items, query);
  const views = list.map((it) => toView(it, store, { locale: q.locale }));
  const sections = q.collection && q.collection !== '*' ? [{ key: 'collection', items: views }] : groupByDay(views);
  return {
    sections,
    counts: countByType(store.items, query),
    collections: store.collections.map((c) => ({ ...c, secret: store.isSecret(c.id), count: store.items.filter((i) => i.collection === c.id).length })),
    historyCount: store.items.filter((i) => !i.collection || !known.has(i.collection)).length,
    total: store.items.length,
  };
}
