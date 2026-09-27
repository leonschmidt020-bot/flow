// Shared vault – the local side of "Geteilt" (Mac: shared.swift). Only used when sync is switched on.
//   shared.json                 {version, pending, items} (same shape as on the Mac, PROTOCOL.md §4)
//   shared/<id>.png             image of a shared entry
//   shared/files/<id>/<name>    file of a shared entry
// Conflicts: last writer wins (updatedAt), deletion = tombstone.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { writeFileAtomic, readFileOrNull, removeInside } from '../core/atomic';
import { soleURL } from '../core/badges';
import type { IndexCodec } from '../core/store';
import { ENC_MAGIC } from '../core/store';
import type { ClipItem } from '../core/types';
import { derivedId, isBig, newContentId, partsFor, safeName, MAX_SHARE_BYTES, V1_MAX_BYTES, type SharedItem } from './wire';

interface Disk { version: number; pending: string[]; items: SharedItem[] }

export class ShareError extends Error {}

export class SharedVault {
  items: SharedItem[] = [];
  /** persist() is a no-op until load() ran – never overwrite shared.json with an empty state */
  loaded = false;
  pending = new Set<string>();
  readonly dir: string;
  private listeners = new Set<() => void>();

  constructor(private root: string, private opts: { codec?: IndexCodec | null; now?: () => number; me: () => string; log?: (...a: unknown[]) => void }) {
    this.dir = path.join(root, 'shared');
  }

  get file() { return path.join(this.root, 'shared.json'); }
  private nowSec() { return (this.opts.now?.() ?? Date.now()) / 1000; }
  onChange(cb: () => void) { this.listeners.add(cb); return () => this.listeners.delete(cb); }
  private changed() { for (const l of this.listeners) { try { l(); } catch { /* ignore */ } } }

  load(): void {
    const raw = readFileOrNull(this.file);
    this.loaded = true;
    if (!raw) return;
    let plain = raw;
    try {
      if (raw.subarray(0, ENC_MAGIC.length).equals(ENC_MAGIC)) {
        if (!this.opts.codec) { this.loaded = false; return; }
        plain = this.opts.codec.unprotect(raw.subarray(ENC_MAGIC.length));
      }
      const d = JSON.parse(plain.toString('utf8')) as Disk;
      this.items = Array.isArray(d.items) ? d.items.filter((i) => i && typeof i.id === 'string') : [];
      this.pending = new Set(Array.isArray(d.pending) ? d.pending : []);
    } catch (e) {
      this.opts.log?.('[clipvault] shared.json unreadable – kept as shared.kaputt.json', (e as Error).message);
      try { fs.renameSync(this.file, path.join(this.root, 'shared.kaputt.json')); } catch { /* ignore */ }
    }
  }

  persist(): void {
    if (!this.loaded) return;
    const d: Disk = { version: 1, pending: [...this.pending], items: this.items.map(({ body: _b, ...rest }) => rest) };
    const json = Buffer.from(JSON.stringify(d), 'utf8');
    writeFileAtomic(this.file, this.opts.codec ? Buffer.concat([ENC_MAGIC, this.opts.codec.protect(json)]) : json);
    this.changed();
  }

  setCodec(c: IndexCodec | null) { this.opts.codec = c; this.persist(); }

  item(id: string): SharedItem | undefined {
    const l = id.toLowerCase();
    return this.items.find((i) => i.id.toLowerCase() === l);
  }
  visible(): SharedItem[] {
    return this.items.filter((i) => !i.deleted).sort((a, b) => b.updatedAt - a.updatedAt);
  }

  imagePath(id: string) { return path.join(this.dir, `${id}.png`); }
  filePath(it: SharedItem): string | null {
    return it.fileName ? path.join(this.dir, 'files', it.id, safeName(it.fileName)) : null;
  }
  localPath(it: SharedItem): string | null {
    return it.kind === 'image' ? this.imagePath(it.id) : it.kind === 'file' ? this.filePath(it) : null;
  }
  isLocal(it: SharedItem): boolean {
    const p = this.localPath(it);
    if (!p) return true;
    try { return fs.statSync(p).size === (it.size ?? fs.statSync(p).size); } catch { return false; }
  }
  /** v1 body for upload (read from disk) */
  body(it: SharedItem): Buffer | null {
    const p = this.localPath(it);
    return p ? readFileOrNull(p) : Buffer.alloc(0);
  }

  private removeBlobs(id: string) {
    removeInside(this.dir, `${id}.png`);
    removeInside(this.dir, path.join('files', id));
  }

  private upsert(s: SharedItem) {
    this.items = [s, ...this.items.filter((i) => i.id.toLowerCase() !== s.id.toLowerCase())];
    this.pending.add(s.id);
  }

  private stamp(s: SharedItem, bytes: number) {
    s.size = bytes; s.uploadError = null; s.serverGone = null; s.expiresAt = null;
    if (bytes > V1_MAX_BYTES) { s.parts = partsFor(bytes); s.content = newContentId(); } else { s.parts = null; s.content = null; }
  }

  /** Share a history entry. Returns the shared items (one per file for multi-file entries). */
  share(clip: ClipItem, abs: (rel: string) => string): SharedItem[] {
    const now = this.nowSec();
    const base = (id: string): SharedItem => {
      const old = this.item(id);
      return { id, kind: 'text', text: null, createdBy: this.opts.me(), createdAt: old?.createdAt ?? now, updatedAt: now, pinned: old?.pinned ?? false, deleted: false };
    };
    fs.mkdirSync(this.dir, { recursive: true });
    const out: SharedItem[] = [];
    if (clip.kind === 'text') {
      const s = base(clip.id);
      s.kind = soleURL(clip.text) ? 'link' : 'text';
      s.text = clip.text ?? '';
      out.push(s);
    } else if (clip.kind === 'image') {
      if (!clip.image) throw new ShareError('Bild fehlt auf der Platte');
      const src = abs(clip.image);
      const bytes = fs.statSync(src).size;
      if (bytes > MAX_SHARE_BYTES) throw new ShareError('Bild zu groß zum Teilen (max. 200 MB)');
      const s = base(clip.id);
      s.kind = 'image';
      s.text = clip.ocrText || null;
      fs.copyFileSync(src, this.imagePath(s.id));
      this.stamp(s, bytes);
      out.push(s);
    } else {
      const refs = clip.files ?? [];
      refs.forEach((r, n) => {
        const src = fs.existsSync(r.orig) ? r.orig : r.stored ? abs(r.stored) : null;
        if (!src) return;
        const st = fs.statSync(src);
        if (!st.isFile() || st.size > MAX_SHARE_BYTES) return; // folders: not supported on Windows yet (Mac zips them)
        const s = base(derivedId(clip.id, n));
        s.kind = 'file';
        s.fileName = safeName(r.name);
        s.sourceId = clip.id;
        const dest = this.filePath(s)!;
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.copyFileSync(src, dest);
        this.stamp(s, st.size);
        out.push(s);
      });
      if (!out.length) throw new ShareError('Keine teilbare Datei (Ordner oder > 200 MB)');
    }
    for (const s of out) this.upsert(s);
    this.persist();
    return out;
  }

  /** soft delete (tombstone) – by shared id or by history id (then all its files) */
  unshare(id: string): string[] {
    const l = id.toLowerCase();
    const hits = this.items.filter((i) => !i.deleted && (i.id.toLowerCase() === l || i.sourceId?.toLowerCase() === l));
    const now = this.nowSec();
    for (const h of hits) {
      Object.assign(h, { deleted: true, updatedAt: now, text: null, fileName: null, parts: null, content: null, size: null });
      this.removeBlobs(h.id);
      this.pending.add(h.id);
    }
    if (hits.length) this.persist();
    return hits.map((h) => h.id);
  }

  setPinned(id: string, pinned: boolean): SharedItem | null {
    const it = this.item(id);
    if (!it || it.deleted) return null;
    it.pinned = pinned;
    it.updatedAt = this.nowSec();
    this.pending.add(it.id);
    this.persist();
    return it;
  }

  markSynced(ids: string[]) {
    let ch = false;
    for (const id of ids) {
      const it = this.item(id);
      if (it && this.pending.delete(it.id)) ch = true;
    }
    if (ch) this.persist();
  }
  markUploadFailed(id: string, msg: string) {
    const it = this.item(id);
    if (it) { it.uploadError = msg; this.persist(); }
  }
  setServerMeta(id: string, gone: boolean, expiresAt: number | null) {
    const it = this.item(id);
    if (!it || (it.serverGone === gone && it.expiresAt === expiresAt)) return;
    it.serverGone = gone; it.expiresAt = expiresAt;
    this.persist();
  }

  /** Apply entries from the partner. Returns ids that changed. */
  applyRemote(remote: SharedItem[]): string[] {
    const touched: string[] = [];
    for (const r0 of remote) {
      const r = { ...r0 };
      const old = this.item(r.id);
      if (old) {
        const wasHint = isBig(r) && !isBig(old) && old.kind === 'text' && !old.deleted;
        if (r.updatedAt < old.updatedAt && !wasHint) continue;
      }
      fs.mkdirSync(this.dir, { recursive: true });
      if (r.deleted) this.removeBlobs(r.id);
      else {
        if (old && (old.content !== r.content || old.fileName !== r.fileName || isBig(old) !== isBig(r)) && (isBig(r) || isBig(old))) this.removeBlobs(r.id);
        if (r.body && r.kind === 'image') writeFileAtomic(this.imagePath(r.id), r.body);
        if (r.body && r.kind === 'file') {
          const p = this.filePath(r);
          if (p) writeFileAtomic(p, r.body);
        }
        if (r.size == null && r.body) r.size = r.body.length;
      }
      delete r.body;
      if (old) { r.serverGone = r.serverGone ?? old.serverGone; r.expiresAt = r.expiresAt ?? old.expiresAt; }
      this.items = [r, ...this.items.filter((i) => i.id.toLowerCase() !== r.id.toLowerCase())];
      this.pending.delete(old?.id ?? r.id);
      touched.push(r.id);
    }
    if (touched.length) {
      this.items.sort((a, b) => b.updatedAt - a.updatedAt);
      this.persist();
    }
    return touched;
  }

  /** a finished download: move the temp file in place */
  placeDownloaded(it: SharedItem, tmp: string) {
    const dest = this.localPath(it);
    if (!dest) return;
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    try { fs.rmSync(dest, { force: true }); } catch { /* ignore */ }
    fs.renameSync(tmp, dest);
    this.changed();
  }
}
