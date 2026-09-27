// Cross-implementation vectors: produced by the Mac client's own Swift code (CryptoKit, JSONEncoder),
// see scripts/gen-sync-vectors.swift. If these pass, Windows reads exactly what the Mac writes.
import { describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import {
  seal, open, itemAAD, partAAD, frame, unframe, decodeAny, encodeItem, encodeVocab, encodePairCode, decodePairCode,
  vocabIdKey, vocabId, vocabKey, derivedId, safeName, WireError, expectedPartLen, partsFor, PART_SIZE,
} from './wire';

const V = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'test-fixtures', 'swift-sync-vectors.json'), 'utf8'));
const key = Buffer.from(V.key, 'hex');
const hex = (h: string) => Buffer.from(h, 'hex');

describe('AES-GCM compatible with CryptoKit combined box', () => {
  it('opens the Swift-sealed text item and re-seals byte-identically with the same nonce', () => {
    const box = hex(V.text.sealed);
    const plain = open(box, key, itemAAD(V.vault, V.text.id));
    expect(plain.toString('hex')).toBe(V.text.plain);
    expect(seal(plain, key, itemAAD(V.vault, V.text.id), hex(V.text.nonce)).toString('hex')).toBe(V.text.sealed);
  });

  it('rejects a wrong AAD (other vault / other id) and a flipped bit', () => {
    const box = hex(V.text.sealed);
    expect(() => open(box, key, itemAAD(V.vault, V.image.id))).toThrow();
    expect(() => open(box, key, itemAAD('00000000-0000-0000-0000-000000000000', V.text.id))).toThrow();
    const bad = Buffer.from(box);
    bad[20] = bad[20]! ^ 1;
    expect(() => open(bad, key, itemAAD(V.vault, V.text.id))).toThrow();
  });

  it('AAD is case-insensitive in vault and id (Swift lowercases)', () => {
    const box = hex(V.text.sealed);
    expect(() => open(box, key, itemAAD(V.vault.toUpperCase(), V.text.id.toLowerCase()))).not.toThrow();
  });

  it('opens a big-file part with the v2 part AAD', () => {
    const p = V.big.part;
    expect(partAAD(V.vault, V.big.id, '00112233445566778899aabbccddeeff', p.idx, p.count).toString('utf8')).toBe(p.aad);
    const plain = open(hex(p.sealed), key, Buffer.from(p.aad, 'utf8'));
    expect(plain.toString('hex')).toBe(p.plain);
    // same bytes under another index must fail (parts can't be swapped)
    expect(() => open(hex(p.sealed), key, partAAD(V.vault, V.big.id, '00112233445566778899aabbccddeeff', 4, p.count))).toThrow();
  });
});

describe('CVS1 frame', () => {
  it('decodes the Swift text item', () => {
    const o = decodeAny(hex(V.text.plain));
    expect(o.type).toBe('item');
    if (o.type !== 'item') return;
    expect(o.item).toMatchObject({
      id: V.text.id, kind: 'text', text: 'Hallo Nico – ünïcødé ✓ https://example.com/a?b=c', createdBy: 'Lena',
      createdAt: 1790438950.7, updatedAt: 1790438951.25, pinned: false, deleted: false,
    });
  });

  it('decodes the Swift image item incl. body', () => {
    const o = decodeAny(open(hex(V.image.sealed), key, itemAAD(V.vault, V.image.id)));
    if (o.type !== 'item') throw new Error('expected item');
    expect(o.item.kind).toBe('image');
    expect(o.item.pinned).toBe(true);
    expect(o.item.text).toBe('OCR-Text');
    expect(o.item.body?.toString('hex')).toBe('89504e470d0a1a0a0102030405');
    expect(o.item.size).toBe(13);
  });

  it('decodes the Swift big-file manifest (v2) and validates it', () => {
    const o = decodeAny(hex(V.big.plain));
    if (o.type !== 'item') throw new Error('expected item');
    expect(o.item).toMatchObject({ kind: 'file', fileName: 'Video.mp4', parts: 6, size: 5 * 1024 * 1024 + 12345, content: '00112233445566778899aabbccddeeff', text: null });
    expect(o.item.sourceId).toBe('6FA459EA-EE8A-3CA4-894E-DB77E160355E');
    // a manifest whose part count doesn't fit its size is rejected
    const { header } = unframe(hex(V.big.plain));
    expect(() => decodeAny(frame({ ...header, parts: 7 }))).toThrow(WireError);
  });

  it('decodes a tombstone and a vocab entry', () => {
    const t = decodeAny(hex(V.tombstone.plain));
    if (t.type !== 'item') throw new Error('expected item');
    expect(t.item.deleted).toBe(true);
    const v = decodeAny(hex(V.vocabItem.plain));
    expect(v).toEqual({ type: 'vocab', vocab: { id: V.vocab.words[0].id, word: 'Brandauer', type: 'person', by: 'Lena', createdAt: 1790456424.33, updatedAt: 1790456424.33 } });
  });

  it('round-trips what Windows encodes', () => {
    const body = Buffer.from('PNGDATA');
    const enc = encodeItem({ id: V.image.id, kind: 'image', text: null, createdBy: 'Lena', createdAt: 1, updatedAt: 2, pinned: false, deleted: false, body });
    const o = decodeAny(enc);
    if (o.type !== 'item') throw new Error('expected item');
    expect(o.item.body?.toString()).toBe('PNGDATA');
    const big = encodeItem({ id: V.big.id, kind: 'file', fileName: 'a.zip', createdBy: 'Lena', createdAt: 1, updatedAt: 2, pinned: false, deleted: false, size: PART_SIZE * 5 + 1, parts: 6, content: 'ab'.repeat(16) });
    const ob = decodeAny(big);
    if (ob.type !== 'item') throw new Error('expected item');
    expect(ob.item.parts).toBe(6);
    const { header } = unframe(big);
    expect(header.kind).toBe('bigfile');
    expect(header.v).toBe(2);
    const voc = decodeAny(encodeVocab({ id: V.vocab.words[0].id, word: 'Brandauer', type: 'person', by: 'Lena', createdAt: 5, updatedAt: 6 }));
    expect(voc.type).toBe('vocab');
  });

  it('rejects garbage', () => {
    expect(() => unframe(Buffer.from('nope'))).toThrow();
    expect(() => unframe(Buffer.concat([Buffer.from('CVS1'), Buffer.from([0, 0, 1, 0])]))).toThrow();
    expect(() => decodeAny(frame({ v: 1, id: 'not-a-uuid', kind: 'text', createdBy: 'x', createdAt: 1, updatedAt: 1, pinned: false, deleted: false }))).toThrow();
  });

  it('file names from the partner are made safe', () => {
    expect(safeName('../../etc/passwd')).toBe('_.._etc_passwd');
    expect(safeName('..\\..\\Windows\\x.dll')).not.toMatch(/[\\/]/);
    expect(safeName('CON')).toBe('_CON');
    expect(safeName('a<b>c?.txt')).toBe('a_b_c_.txt');
    expect(safeName('')).toBe('Datei');
  });
});

describe('pairing code', () => {
  it('decodes the Swift code and encodes it back identically', () => {
    const p = decodePairCode(V.pair.code)!;
    expect(p).not.toBeNull();
    expect(p.url).toBe(V.pair.url);
    expect(p.vaultId).toBe(V.pair.vault);
    expect(p.secret).toBe(V.pair.secret);
    expect(p.key.toString('hex')).toBe(V.pair.key);
    expect(encodePairCode(p)).toBe(V.pair.code);
  });
  it('tolerates whitespace/line breaks and a leading text', () => {
    const c = V.pair.code as string;
    expect(decodePairCode(`Hier: ${c.slice(0, 30)}\n ${c.slice(30)}  `)?.vaultId).toBe(V.pair.vault);
  });
  it('rejects wrong codes', () => {
    expect(decodePairCode('cvpair2.abc')).toBeNull();
    expect(decodePairCode('cvpair1.AAAA')).toBeNull();
  });
});

describe('ids', () => {
  it('vocab id key + ids match Swift (HKDF + HMAC, NFC normalization)', () => {
    const ik = vocabIdKey(key);
    expect(ik.toString('hex')).toBe(V.vocab.idKey);
    for (const w of V.vocab.words) {
      expect(vocabKey(w.word)).toBe(w.key.normalize('NFC'));
      expect(vocabId(w.word, ik)).toBe(w.id);
    }
  });
  it('derived ids for multi-file shares match Swift', () => {
    for (const d of V.derived) expect(derivedId(d.base, d.n)).toBe(d.id);
    expect(derivedId('ABC', 0)).toBe('ABC');
  });
  it('part lengths', () => {
    expect(partsFor(PART_SIZE * 2 + 1)).toBe(3);
    expect(expectedPartLen(2, 3, PART_SIZE * 2 + 1)).toBe(1);
    expect(expectedPartLen(0, 3, PART_SIZE * 2 + 1)).toBe(PART_SIZE);
  });
});
