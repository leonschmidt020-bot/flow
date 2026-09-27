// ClipVault sync – crypto + message format, byte-compatible with the Mac client (clipvault/sync.swift).
//
// Item payload (plaintext):  "CVS1" | UInt32 BE header length | header JSON | raw bytes (image/file)
// Sealed:                    AES-256-GCM, CryptoKit "combined" layout = nonce(12) | ciphertext | tag(16)
// AAD item:                  "clipvault-item|v1|<vault lower>|<id lower>"
// AAD part (big items, v2):  "clipvault-part|v2|<vault>|<id>|<content>|<idx>/<count>"
// Pairing code:              "cvpair1." + base64url( 0x01 | vault uuid 16 B | secret 16 B | key 32 B | url utf8 )
// Vocab id:                  HKDF-SHA256(vaultKey, salt = none, info "clipvault-vocab-id|v1") -> HMAC key;
//                            UUID-form of HMAC(key, "clipvault-vocab|v1|" + normalized word)[0..16] (v5 bits)
// Verified against vectors produced by the Swift code itself: test-fixtures/swift-sync-vectors.json
// (generator: scripts/gen-sync-vectors.swift).
import { createCipheriv, createDecipheriv, createHash, createHmac, hkdfSync, randomBytes } from 'node:crypto';

export const PART_SIZE = 1024 * 1024;
export const V1_MAX_BYTES = 4 * 1024 * 1024;
export const MAX_SHARE_BYTES = 200 * 1024 * 1024;
export const MAX_BODY = 8 * 1024 * 1024;
export const AUTO_DOWNLOAD_MAX = 20 * 1024 * 1024;

export type SharedKind = 'text' | 'image' | 'link' | 'file';

export interface WireHeader {
  v: number;
  id: string;
  kind: string;
  text?: string;
  fileName?: string;
  createdBy: string;
  createdAt: number;
  updatedAt: number;
  pinned: boolean;
  deleted: boolean;
  big?: string;
  size?: number;
  parts?: number;
  partSize?: number;
  content?: string;
  sourceId?: string;
  vocab?: { word: string; type: string };
}

/** A shared item as both clients understand it (mirrors SharedItem in shared.swift). */
export interface SharedItem {
  id: string;
  kind: SharedKind;
  text?: string | null;
  fileName?: string | null;
  createdBy: string;
  createdAt: number; // unix seconds
  updatedAt: number;
  pinned: boolean;
  deleted: boolean;
  size?: number | null;
  parts?: number | null;
  content?: string | null;
  sourceId?: string | null;
  serverGone?: boolean | null;
  expiresAt?: number | null;
  uploadError?: string | null;
  /** in memory only (v1 bodies) */
  body?: Buffer | null;
}

export interface VocabEntry {
  id: string;
  word: string;
  type: string;
  by: string;
  createdAt: number;
  updatedAt: number;
}

export class WireError extends Error {}

const UUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (s: unknown): s is string => typeof s === 'string' && UUID_RX.test(s);

// ------------------------------------------------------------------ AES-GCM
export function seal(plain: Buffer, key: Buffer, aad: Buffer, nonce: Buffer = randomBytes(12)): Buffer {
  if (key.length !== 32) throw new WireError('key must be 32 bytes');
  if (nonce.length !== 12) throw new WireError('nonce must be 12 bytes');
  const c = createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(aad);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.concat([nonce, ct, c.getAuthTag()]);
}

export function open(box: Buffer, key: Buffer, aad: Buffer): Buffer {
  if (box.length < 28) throw new WireError('sealed box too short');
  const d = createDecipheriv('aes-256-gcm', key, box.subarray(0, 12));
  d.setAAD(aad);
  d.setAuthTag(box.subarray(box.length - 16));
  return Buffer.concat([d.update(box.subarray(12, box.length - 16)), d.final()]);
}

export function itemAAD(vault: string, id: string): Buffer {
  return Buffer.from(`clipvault-item|v1|${vault.toLowerCase()}|${id.toLowerCase()}`, 'utf8');
}
export function partAAD(vault: string, id: string, content: string, idx: number, count: number): Buffer {
  return Buffer.from(`clipvault-part|v2|${vault.toLowerCase()}|${id.toLowerCase()}|${content.toLowerCase()}|${idx}/${count}`, 'utf8');
}

// ------------------------------------------------------------------ frame
export function frame(h: WireHeader, body: Buffer = Buffer.alloc(0)): Buffer {
  const clean: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(h)) if (v !== undefined && v !== null) clean[k] = v;
  const head = Buffer.from(JSON.stringify(clean), 'utf8');
  const n = Buffer.alloc(4);
  n.writeUInt32BE(head.length);
  return Buffer.concat([Buffer.from('CVS1', 'utf8'), n, head, body]);
}

export function unframe(d: Buffer): { header: WireHeader; body: Buffer } {
  if (d.length < 8 || d.subarray(0, 4).toString('latin1') !== 'CVS1') throw new WireError('unknown format');
  const n = d.readUInt32BE(4);
  if (8 + n > d.length) throw new WireError('broken packet');
  let h: WireHeader;
  try { h = JSON.parse(d.subarray(8, 8 + n).toString('utf8')); } catch { throw new WireError('broken header'); }
  for (const k of ['id', 'kind', 'createdBy'] as const) if (typeof h[k] !== 'string') throw new WireError(`header.${k} missing`);
  for (const k of ['createdAt', 'updatedAt'] as const) if (typeof h[k] !== 'number') throw new WireError(`header.${k} missing`);
  if (typeof h.pinned !== 'boolean' || typeof h.deleted !== 'boolean') throw new WireError('header flags missing');
  if (!isUuid(h.id)) throw new WireError('invalid id');
  return { header: h, body: d.subarray(8 + n) };
}

/** Partner-supplied file names never contain paths (Mac: SharedVault.safeName). */
export function safeName(n: string | null | undefined): string {
  let s = (n ?? 'Datei').replace(/[/:\\\0]/g, '_');
  while (s.startsWith('.')) s = s.slice(1);
  s = [...s].slice(0, 180).join('').trim();
  // Windows additionally forbids these (they are fine on macOS)
  s = s.replace(/[*?"<>|]/g, '_').replace(/[. ]+$/, '');
  if (/^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$/i.test(s)) s = '_' + s;
  return s || 'Datei';
}

export function hintText(it: SharedItem): string {
  const mb = ((it.size ?? 0) / 1_000_000).toFixed(1).replace('.', ',');
  const what = it.kind === 'image' ? 'Bild' : `Datei „${it.fileName ?? 'Datei'}"`;
  return `${what} (${mb} MB) — zum Öffnen ClipVault aktualisieren.`;
}

export function isBig(it: SharedItem): boolean {
  return (it.parts ?? 0) > 0;
}

export function encodeItem(it: SharedItem): Buffer {
  const h: WireHeader = {
    v: 1, id: it.id, kind: it.kind,
    text: it.deleted ? undefined : it.text ?? undefined,
    fileName: it.deleted ? undefined : it.fileName ?? undefined,
    createdBy: it.createdBy, createdAt: it.createdAt, updatedAt: it.updatedAt, pinned: it.pinned, deleted: it.deleted,
    sourceId: it.sourceId ?? undefined,
  };
  if (isBig(it) && !it.deleted) {
    h.v = 2; h.big = it.kind; h.kind = 'bigfile'; h.text = hintText(it);
    h.size = it.size ?? 0; h.parts = it.parts ?? 0; h.partSize = PART_SIZE; h.content = it.content ?? undefined;
    return frame(h);
  }
  const body = it.deleted ? Buffer.alloc(0) : it.kind === 'image' || it.kind === 'file' ? it.body ?? null : Buffer.alloc(0);
  if (body === null) throw new WireError('Bild/Datei fehlt auf der Platte');
  if (body.length > MAX_BODY) throw new WireError('Zu groß zum Teilen (max. 8 MB)');
  if (!it.deleted && (it.kind === 'image' || it.kind === 'file')) h.size = body.length;
  return frame(h, body);
}

export function encodeVocab(v: VocabEntry): Buffer {
  return frame({
    v: 1, id: v.id, kind: 'vocab', createdBy: v.by, createdAt: v.createdAt, updatedAt: v.updatedAt,
    pinned: false, deleted: true, vocab: { word: v.word, type: v.type },
  });
}

export type Opened = { type: 'item'; item: SharedItem } | { type: 'vocab'; vocab: VocabEntry };

const VOCAB_TYPES = ['person', 'company', 'place', 'term'];

export function vocabKey(w: string): string {
  return w.normalize('NFC').split(/\s+/u).filter(Boolean).join(' ').toLowerCase();
}
export function cleanVocab(raw: string): string | null {
  const w = raw.normalize('NFC').split(/\s+/u).filter(Boolean).join(' ');
  const len = [...w].length;
  if (len < 2 || len > 60 || w.split(' ').length > 4 || !/\p{L}/u.test(w) || /\p{Cc}/u.test(w)) return null;
  return w;
}

export function decodeAny(d: Buffer): Opened {
  const { header: h, body } = unframe(d);
  if (h.kind === 'vocab') {
    const word = h.vocab ? cleanVocab(h.vocab.word) : null;
    if (!word) throw new WireError('broken vocab');
    const type = VOCAB_TYPES.includes((h.vocab!.type ?? '').toLowerCase()) ? h.vocab!.type.toLowerCase() : 'term';
    return { type: 'vocab', vocab: { id: h.id, word, type, by: [...h.createdBy].slice(0, 40).join(''), createdAt: h.createdAt, updatedAt: h.updatedAt } };
  }
  const big = h.kind === 'bigfile' && !h.deleted;
  const kinds: SharedKind[] = ['text', 'image', 'link', 'file'];
  const kind: SharedKind = big ? (kinds.includes(h.big as SharedKind) ? (h.big as SharedKind) : 'file') : kinds.includes(h.kind as SharedKind) ? (h.kind as SharedKind) : 'text';
  const it: SharedItem = {
    id: h.id, kind, text: big ? null : h.text ?? null, createdBy: [...h.createdBy].slice(0, 40).join(''),
    createdAt: h.createdAt, updatedAt: h.updatedAt, pinned: h.pinned, deleted: h.deleted,
    sourceId: isUuid(h.sourceId) ? h.sourceId : null,
  };
  if (big) {
    const parts = h.parts ?? 0, size = h.size ?? 0, c = h.content ?? '';
    if (!(parts > 0 && parts <= 256 && size > 0 && size <= MAX_SHARE_BYTES && h.partSize === PART_SIZE &&
          parts === Math.ceil(size / PART_SIZE) && /^[0-9a-f]{32}$/i.test(c))) throw new WireError('broken manifest');
    it.parts = parts; it.size = size; it.content = c.toLowerCase();
    if (kind === 'file') it.fileName = safeName(h.fileName);
  } else if (!h.deleted) {
    if (kind === 'image') { it.body = body; it.size = body.length; }
    if (kind === 'file') { it.fileName = safeName(h.fileName); it.body = body; it.size = body.length; }
  }
  return { type: 'item', item: it };
}

// ------------------------------------------------------------------ pairing code
export interface PairParts { url: string; vaultId: string; secret: string; key: Buffer }

export function uuidToBytes(s: string): Buffer {
  if (!isUuid(s)) return Buffer.alloc(16);
  return Buffer.from(s.replace(/-/g, ''), 'hex');
}
export function bytesToUuid(b: Buffer): string {
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

export function encodePairCode(p: PairParts): string {
  const d = Buffer.concat([Buffer.from([1]), uuidToBytes(p.vaultId), Buffer.from(p.secret, 'hex'), p.key, Buffer.from(p.url, 'utf8')]);
  return 'cvpair1.' + d.toString('base64url');
}

export function decodePairCode(raw: string): PairParts | null {
  const s0 = raw.trim().replace(/[\s\n]/g, '');
  const i = s0.indexOf('cvpair1.');
  if (i < 0) return null;
  const s = s0.slice(i + 8);
  if (!/^[A-Za-z0-9_+/=-]+$/.test(s)) return null;
  const d = Buffer.from(s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''), 'base64url');
  if (d.length <= 65 || d[0] !== 1) return null;
  const url = d.subarray(65).toString('utf8');
  if (!url.startsWith('http')) return null;
  return { url, vaultId: bytesToUuid(d.subarray(1, 17)), secret: d.subarray(17, 33).toString('hex'), key: Buffer.from(d.subarray(33, 65)) };
}

// ------------------------------------------------------------------ ids
function uuidV5Form(b: Buffer): string {
  const x = Buffer.from(b.subarray(0, 16));
  x[6] = (x[6]! & 0x0f) | 0x50;
  x[8] = (x[8]! & 0x3f) | 0x80;
  return bytesToUuid(x).toUpperCase();
}

export function vocabIdKey(vaultKey: Buffer): Buffer {
  return Buffer.from(hkdfSync('sha256', vaultKey, Buffer.alloc(0), Buffer.from('clipvault-vocab-id|v1', 'utf8'), 32));
}
export function vocabId(word: string, idKey: Buffer): string {
  return uuidV5Form(createHmac('sha256', idKey).update(`clipvault-vocab|v1|${vocabKey(word)}`, 'utf8').digest());
}

/** stable id for the n-th file of a multi-file history entry (shared.swift derivedId) */
export function derivedId(base: string, n: number): string {
  if (n === 0) return base;
  return uuidV5Form(createHash('sha256').update(`clipvault-multi|${base.toLowerCase()}|${n}`, 'utf8').digest());
}

export function newContentId(): string {
  return randomBytes(16).toString('hex');
}

export function partsFor(size: number): number {
  return Math.ceil(size / PART_SIZE);
}
export function expectedPartLen(idx: number, parts: number, size: number): number {
  return idx < parts - 1 ? PART_SIZE : size - (parts - 1) * PART_SIZE;
}
