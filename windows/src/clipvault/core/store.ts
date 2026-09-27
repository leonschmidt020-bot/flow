// ClipVault (Windows) – history store in <userData>/clipvault/.
//
//   index.json        history (array, newest first; Mac-compatible fields). Atomic (temp + rename).
//                     With encryption on: "CVDP1\n" + DPAPI blob (see platform/win32.ts, README.md).
//   index.bak.json    last good copy (at most every 60 s)
//   index.kaputt.json the corrupt file, kept for inspection after a recovery
//   collections.json  "Bereiche"
//   <id>.png          full image · thumbs/<id>.png thumbnail · files/<id>/<name> copied files
//
// Retention: history 2 days, max 200 entries, size quota; pinned or in a collection = kept forever;
// secret collection: 24 h after collectedAt unless pinned.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomUUID } from 'node:crypto';
import { writeFileAtomic, readFileOrNull, removeInside, fileSize } from './atomic';
import { detectBadges } from './badges';
import { filesKey, textKey, roughlyMatches, finesLookSame, printFromHex, printToHex, IMAGE_TWIN_WINDOW_SEC, type ImagePrint } from './dedupe';
import { DEFAULT_LIMITS, type ClipItem, type Collection, type FileRef, type StoreLimits } from './types';

export interface IndexCodec {
  /** short name for logs */
  name: string;
  protect(plain: Buffer): Buffer;
  unprotect(blob: Buffer): Buffer;
}

export const ENC_MAGIC = Buffer.from('CVDP1\n', 'utf8');
const BACKUP_EVERY_MS = 60_000;

export interface StoreOptions {
  limits?: Partial<StoreLimits>;
  codec?: IndexCodec | null;
  now?: () => number; // ms
  log?: (...a: unknown[]) => void;
  locale?: 'de' | 'en';
}

export interface NewImage {
  png: Buffer;
  thumbPng?: Buffer | null;
  w: number;
  h: number;
  print?: ImagePrint | null;
  /** 256-px gray raster of the new image (for the fine twin check) */
  fine?: Uint8Array | null;
}

/** Fine raster of an existing entry's image (read from disk by the platform layer). */
export type FineLoader = (item: ClipItem, absPath: string) => Uint8Array | null;

export function looksSecretName(n: string): boolean {
  const l = n.toLowerCase();
  return l.includes('passw') || l.includes('kennw') || l.includes('geheim') || l.includes('secret');
}

export function newId(): string {
  return randomUUID().toUpperCase();
}

export function safeFileName(n: string): string {
  let s = n.replace(/[\\/:*?"<>|\0]/g, '_');
  while (s.startsWith('.')) s = s.slice(1);
  s = s.slice(0, 180).trim();
  return s || 'Datei';
}

export class Store {
  readonly dir: string;
  items: ClipItem[] = [];
  collections: Collection[] = [];
  readonly limits: StoreLimits;
  codec: IndexCodec | null;
  /** set when the index could not be read at all (e.g. encrypted on another machine) – never overwrite then */
  readOnly = false;
  lastRecovery: 'none' | 'backup' | 'empty' = 'none';
  private lastBackup = 0;
  private now: () => number;
  private log: (...a: unknown[]) => void;
  private locale: 'de' | 'en';
  private listeners = new Set<() => void>();

  constructor(dir: string, opts: StoreOptions = {}) {
    this.dir = dir;
    this.limits = { ...DEFAULT_LIMITS, ...(opts.limits ?? {}) };
    this.codec = opts.codec ?? null;
    this.now = opts.now ?? (() => Date.now());
    this.log = opts.log ?? (() => {});
    this.locale = opts.locale ?? 'de';
    fs.mkdirSync(dir, { recursive: true });
  }

  get indexPath() { return path.join(this.dir, 'index.json'); }
  get backupPath() { return path.join(this.dir, 'index.bak.json'); }
  get brokenPath() { return path.join(this.dir, 'index.kaputt.json'); }
  get collectionsPath() { return path.join(this.dir, 'collections.json'); }
  private nowSec() { return this.now() / 1000; }

  onChange(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }
  private changed() {
    for (const l of this.listeners) {
      try { l(); } catch { /* listener errors never break the store */ }
    }
  }

  // ------------------------------------------------------------------ load / save
  private decode(buf: Buffer | null): ClipItem[] | null | 'locked' {
    if (!buf || buf.length === 0) return null;
    let plain = buf;
    if (buf.subarray(0, ENC_MAGIC.length).equals(ENC_MAGIC)) {
      if (!this.codec) return 'locked';
      try {
        plain = this.codec.unprotect(buf.subarray(ENC_MAGIC.length));
      } catch {
        return null;
      }
    }
    try {
      const arr = JSON.parse(plain.toString('utf8'));
      if (!Array.isArray(arr)) return null;
      return arr.filter((x) => x && typeof x.id === 'string' && typeof x.kind === 'string' && typeof x.ts === 'number') as ClipItem[];
    } catch {
      return null;
    }
  }

  load(): void {
    this.loadCollections();
    const main = readFileOrNull(this.indexPath);
    let items = this.decode(main);
    if (items === 'locked') {
      this.readOnly = true;
      this.log('[clipvault] index is encrypted but no key is available – read-only, nothing is overwritten');
      this.items = [];
      return;
    }
    if (items === null && main !== null) {
      this.log('[clipvault] index damaged – trying the backup copy');
      const bak = this.decode(readFileOrNull(this.backupPath));
      items = bak === 'locked' ? null : bak;
      try {
        fs.rmSync(this.brokenPath, { force: true });
        fs.renameSync(this.indexPath, this.brokenPath);
      } catch { /* keep going */ }
      this.lastRecovery = items ? 'backup' : 'empty';
    }
    this.items = (items ?? []).map((it) => ({ ...it }));
    for (const it of this.items) if (this.isSecret(it.collection) && !it.collectedAt) it.collectedAt = this.nowSec();
    if (this.prune() || this.lastRecovery !== 'none') this.persist();
  }

  loadCollections(): void {
    const raw = readFileOrNull(this.collectionsPath);
    if (raw) {
      try {
        const cs = JSON.parse(raw.toString('utf8'));
        if (Array.isArray(cs)) {
          this.collections = cs.filter((c) => c && typeof c.id === 'string' && typeof c.name === 'string');
          return;
        }
      } catch { /* fall through to defaults */ }
    }
    const de = this.locale === 'de';
    this.collections = [
      { id: newId(), name: de ? 'Arbeit' : 'Work', symbol: 'briefcase' },
      { id: newId(), name: de ? 'Passwörter' : 'Passwords', symbol: 'lock', secret: true },
    ];
    this.persistCollections();
  }

  persistCollections(): void {
    if (this.readOnly) return;
    writeFileAtomic(this.collectionsPath, JSON.stringify(this.collections, null, 1));
    this.changed();
  }

  serialize(): Buffer {
    const out = this.items.map((it) => {
      const o: ClipItem = { ...it };
      const b = it.kind === 'text' ? detectBadges(it.text ?? '') : [];
      if (b.length) o.badges = b; else delete o.badges;
      if (!o.shared) delete o.shared;
      return o;
    });
    const json = Buffer.from(JSON.stringify(out), 'utf8');
    return this.codec ? Buffer.concat([ENC_MAGIC, this.codec.protect(json)]) : json;
  }

  persist(): void {
    if (this.readOnly) return;
    const data = this.serialize();
    if (this.now() - this.lastBackup > BACKUP_EVERY_MS) {
      const old = readFileOrNull(this.indexPath);
      // only back up a copy that still decodes (never overwrite a good backup with garbage)
      if (old && old.length && this.decode(old) !== null) {
        try { writeFileAtomic(this.backupPath, old); this.lastBackup = this.now(); } catch (e) { this.log('[clipvault] backup failed', e); }
      }
    }
    try {
      writeFileAtomic(this.indexPath, data);
    } catch (e) {
      this.log('[clipvault] could not save history', e);
    }
    this.changed();
  }

  /** Switch encryption on/off and rewrite index + backup in the new form. */
  setCodec(codec: IndexCodec | null): void {
    this.codec = codec;
    if (this.readOnly) return;
    this.lastBackup = 0;
    this.persist();
    try { writeFileAtomic(this.backupPath, this.serialize()); this.lastBackup = this.now(); } catch { /* next save */ }
  }

  // ------------------------------------------------------------------ queries
  item(id: string): ClipItem | undefined {
    return this.items.find((i) => i.id === id);
  }
  collection(id: string | null | undefined): Collection | undefined {
    return id ? this.collections.find((c) => c.id === id) : undefined;
  }
  isSecret(collectionId: string | null | undefined): boolean {
    const c = this.collection(collectionId);
    return c ? (c.secret ?? looksSecretName(c.name)) : false;
  }
  secretExpiry(it: ClipItem): number | null {
    if (it.pinned || !this.isSecret(it.collection)) return null;
    return (it.collectedAt ?? it.ts) + this.limits.secretTtlSec;
  }
  abs(rel: string): string {
    return path.join(this.dir, rel);
  }
  imagePath(it: ClipItem): string | null {
    return it.image ? this.abs(it.image) : null;
  }
  thumbPath(it: ClipItem): string | null {
    return it.thumb ? this.abs(it.thumb) : null;
  }
  /** best existing file of a file entry: original first, then the stored copy */
  filePaths(it: ClipItem): string[] {
    return (it.files ?? [])
      .map((r) => (fs.existsSync(r.orig) ? r.orig : r.stored && fs.existsSync(this.abs(r.stored)) ? this.abs(r.stored) : null))
      .filter((p): p is string => !!p);
  }
  totalBytes(filter: (it: ClipItem) => boolean = () => true): number {
    return this.items.filter(filter).reduce((s, it) => s + (it.bytes ?? 0), 0);
  }

  // ------------------------------------------------------------------ retention
  private removeStorage(it: ClipItem) {
    if (this.readOnly) return;
    if (it.image) removeInside(this.dir, it.image);
    if (it.thumb) removeInside(this.dir, it.thumb);
    if (it.kind === 'file') removeInside(this.dir, path.join('files', it.id));
  }

  /** Drop expired / overflowing entries. Returns true if something was removed. */
  prune(): boolean {
    const now = this.nowSec();
    const cutoff = now - this.limits.maxAgeSec;
    const before = this.items.length;
    const expired = (it: ClipItem) => {
      if (it.pinned) return false;
      const exp = this.secretExpiry(it);
      if (exp !== null) return exp < now;
      if (it.collection && this.collection(it.collection)) return false;
      return it.ts < cutoff;
    };
    const kept: ClipItem[] = [];
    for (const it of this.items) {
      if (expired(it)) this.removeStorage(it);
      else kept.push(it);
    }
    this.items = kept;
    const protectedItem = (it: ClipItem) => !!it.pinned || (!!it.collection && !!this.collection(it.collection));
    // count cap (history only), oldest first
    let historyCount = this.items.filter((i) => !protectedItem(i)).length;
    if (historyCount > this.limits.maxItems) {
      const drop = new Set<string>();
      for (let i = this.items.length - 1; i >= 0 && historyCount > this.limits.maxItems; i--) {
        const it = this.items[i]!;
        if (!protectedItem(it)) { drop.add(it.id); historyCount--; this.removeStorage(it); }
      }
      this.items = this.items.filter((i) => !drop.has(i.id));
    }
    // size quota (history only), oldest first – the newest entry always stays
    let bytes = this.totalBytes((i) => !protectedItem(i));
    if (bytes > this.limits.quotaBytes) {
      const drop = new Set<string>();
      for (let i = this.items.length - 1; i >= 1 && bytes > this.limits.quotaBytes; i--) {
        const it = this.items[i]!;
        if (!protectedItem(it) && (it.bytes ?? 0) > 0) { drop.add(it.id); bytes -= it.bytes ?? 0; this.removeStorage(it); }
      }
      this.items = this.items.filter((i) => !drop.has(i.id));
    }
    return this.items.length !== before;
  }

  private insertTop(it: ClipItem) {
    this.items = [it, ...this.items.filter((x) => x.id !== it.id)];
  }

  /** mark as just used (moves to the top) */
  touch(id: string): boolean {
    const it = this.item(id);
    if (!it) return false;
    it.ts = this.nowSec();
    this.insertTop(it);
    this.persist();
    return true;
  }

  // ------------------------------------------------------------------ add
  addText(text: string, source: string | null = null, collection: string | null = null): { item: ClipItem; isNew: boolean } {
    const key = textKey(text);
    let it = this.items.find((i) => i.kind === 'text' && (i.text === text || textKey(i.text ?? '') === key));
    const isNew = !it;
    if (it) {
      it.ts = this.nowSec();
      if (source) it.source = source;
    } else {
      it = { id: newId(), kind: 'text', text, ts: this.nowSec(), source };
    }
    if (collection && it.collection !== collection) { it.collection = collection; it.collectedAt = this.nowSec(); it.pinned = false; }
    this.insertTop(it);
    this.prune();
    this.persist();
    return { item: it, isNew };
  }

  /** Twin within 3 minutes (see dedupe.ts). */
  findImageTwin(img: NewImage, loadFine: FineLoader | null): ClipItem | null {
    if (!img.print) return null;
    const now = this.nowSec();
    for (const it of this.items) {
      if (it.kind !== 'image' || now - it.ts > IMAGE_TWIN_WINDOW_SEC) continue;
      const p = printFromHex(it.print, it.w, it.h);
      if (!p || !roughlyMatches(p, img.print)) continue;
      const abs = this.imagePath(it);
      if (!abs) continue;
      if (img.fine && loadFine) {
        const old = loadFine(it, abs);
        if (!old || !finesLookSame(old, img.fine)) continue;
      } else if (img.fine || loadFine) {
        continue; // can't do the fine check -> not a twin (stay separate rather than merge wrongly)
      }
      return it;
    }
    return null;
  }

  addImage(img: NewImage, source: string | null = null, origin: string | null = null, loadFine: FineLoader | null = null): { item: ClipItem; isNew: boolean } {
    const twin = this.findImageTwin(img, loadFine);
    if (twin) {
      if (origin && !twin.origin && !twin.shared && twin.image) {
        try { writeFileAtomic(this.abs(twin.image), img.png); } catch { /* keep old bytes */ }
      }
      twin.origin = twin.origin ?? origin;
      twin.source = twin.source ?? source;
      twin.ts = this.nowSec();
      this.insertTop(twin);
      this.recountBytes(twin);
      this.prune();
      this.persist();
      this.log(`[clipvault] image twin merged (${img.w}x${img.h})`);
      return { item: twin, isNew: false };
    }
    const id = newId();
    const image = `${id}.png`;
    writeFileAtomic(this.abs(image), img.png, 0o600);
    let thumb: string | null = null;
    if (img.thumbPng && img.thumbPng.length) {
      thumb = `thumbs/${id}.png`;
      writeFileAtomic(this.abs(thumb), img.thumbPng, 0o600);
    }
    const it: ClipItem = {
      id, kind: 'image', image, thumb, ts: this.nowSec(), source, origin, w: img.w, h: img.h,
      print: img.print ? printToHex(img.print) : null,
    };
    this.recountBytes(it);
    this.insertTop(it);
    this.prune();
    this.persist();
    return { item: it, isNew: true };
  }

  addFiles(paths: string[], source: string | null = null): { item: ClipItem; isNew: boolean } | null {
    const clean = paths.filter((p) => typeof p === 'string' && p.length > 0);
    if (!clean.length) return null;
    const key = filesKey(clean);
    const existing = this.items.find((i) => i.kind === 'file' && filesKey((i.files ?? []).map((f) => f.orig)) === key);
    if (existing) {
      existing.ts = this.nowSec();
      this.insertTop(existing);
      this.persist();
      return { item: existing, isNew: false };
    }
    const id = newId();
    const refs: FileRef[] = [];
    const used = new Set<string>();
    for (const p of clean) {
      let name = safeFileName(path.win32.basename(p.replace(/\//g, '\\')) || path.basename(p));
      while (used.has(name.toLowerCase())) name = '_' + name;
      used.add(name.toLowerCase());
      let stored: string | null = null;
      let size: number | undefined;
      try {
        const st = fs.statSync(p);
        if (st.isFile() && st.size <= this.limits.maxFileCopyBytes) {
          const rel = path.join('files', id, name);
          fs.mkdirSync(path.dirname(this.abs(rel)), { recursive: true });
          fs.copyFileSync(p, this.abs(rel));
          stored = rel.replace(/\\/g, '/');
          size = st.size;
        }
      } catch { /* gone or unreadable: keep the reference only */ }
      refs.push({ name, stored, orig: p, ...(size !== undefined ? { size } : {}) });
    }
    const it: ClipItem = { id, kind: 'file', files: refs, ts: this.nowSec(), source };
    this.recountBytes(it);
    this.insertTop(it);
    this.prune();
    this.persist();
    return { item: it, isNew: true };
  }

  private recountBytes(it: ClipItem) {
    let b = 0;
    if (it.image) b += fileSize(this.abs(it.image));
    if (it.thumb) b += fileSize(this.abs(it.thumb));
    for (const f of it.files ?? []) if (f.stored) b += f.size ?? fileSize(this.abs(f.stored));
    it.bytes = b;
  }

  // ------------------------------------------------------------------ edit
  setPinned(id: string, pinned: boolean): boolean {
    const it = this.item(id);
    if (!it) return false;
    if (!!it.pinned !== pinned) { it.pinned = pinned; this.persist(); }
    return true;
  }
  setCollection(id: string, collectionId: string | null): boolean {
    const it = this.item(id);
    if (!it) return false;
    if (collectionId && !this.collection(collectionId)) return false;
    it.collection = collectionId;
    it.collectedAt = collectionId ? this.nowSec() : null;
    if (collectionId) it.pinned = false;
    this.persist();
    return true;
  }
  delete(id: string): boolean {
    const it = this.item(id);
    if (!it) return false;
    this.removeStorage(it);
    this.items = this.items.filter((i) => i.id !== id);
    this.persist();
    return true;
  }
  edit(id: string, text: string): boolean {
    const it = this.item(id);
    if (!it || it.kind !== 'text' || !text.trim()) return false;
    if (it.text !== text) { it.text = text; it.edited = this.nowSec(); this.persist(); }
    return true;
  }
  setShared(id: string, shared: boolean): void {
    const it = this.item(id);
    if (it && !!it.shared !== shared) { it.shared = shared; this.persist(); }
  }
  createCollection(name: string, symbol = 'folder', secret?: boolean): Collection {
    const c: Collection = { id: newId(), name: name.trim().slice(0, 60) || 'Bereich', symbol };
    if (secret !== undefined) c.secret = secret;
    this.collections.push(c);
    this.persistCollections();
    return c;
  }
  renameCollection(id: string, name?: string, symbol?: string): boolean {
    const c = this.collection(id);
    if (!c) return false;
    if (name && name.trim()) c.name = name.trim().slice(0, 60);
    if (symbol) c.symbol = symbol;
    this.persistCollections();
    return true;
  }
  deleteCollection(id: string): boolean {
    if (!this.collection(id)) return false;
    for (const it of this.items) if (it.collection === id) { it.collection = null; it.collectedAt = null; }
    this.collections = this.collections.filter((c) => c.id !== id);
    this.persistCollections();
    this.persist();
    return true;
  }
  clearHistory(): number {
    const drop = this.items.filter((i) => !i.pinned && !i.collection);
    for (const it of drop) this.removeStorage(it);
    this.items = this.items.filter((i) => i.pinned || i.collection);
    this.persist();
    return drop.length;
  }
}
