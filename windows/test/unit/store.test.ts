import { describe, expect, it, beforeEach } from 'vitest';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readJsonSafe, writeJsonAtomic, JsonFile } from '../../src/main/store';
import { History, prune, sanitizeHistory } from '../../src/main/history';

let dir = '';
beforeEach(() => { dir = mkdtempSync(path.join(os.tmpdir(), 'flow-store-')); });

describe('atomic JSON store', () => {
  it('writes, keeps last-good backup, leaves no temp files', () => {
    const f = path.join(dir, 'settings.json');
    writeJsonAtomic(f, { a: 1 });
    writeJsonAtomic(f, { a: 2 });
    expect(JSON.parse(readFileSync(f, 'utf8'))).toEqual({ a: 2 });
    expect(JSON.parse(readFileSync(f + '.bak', 'utf8'))).toEqual({ a: 1 });
    expect(readdirSync(dir).filter((x) => x.endsWith('.tmp'))).toEqual([]);
  });
  it('corrupt file → falls back to backup', () => {
    const f = path.join(dir, 's.json');
    writeJsonAtomic(f, { good: true });
    writeJsonAtomic(f, { good: 'newer' });
    writeFileSync(f, '{ broken');
    const r = readJsonSafe(f, () => ({ good: false }));
    expect(r.source).toBe('backup');
    expect(r.value).toEqual({ good: true });
  });
  it('a corrupt current file never overwrites the good backup', () => {
    const f = path.join(dir, 's.json');
    writeJsonAtomic(f, { v: 1 });
    writeJsonAtomic(f, { v: 2 }); // bak = v1
    writeFileSync(f, 'garbage');
    writeJsonAtomic(f, { v: 3 }); // current was garbage → bak stays v1
    expect(JSON.parse(readFileSync(f + '.bak', 'utf8'))).toEqual({ v: 1 });
  });
  it('missing → default', () => {
    expect(readJsonSafe(path.join(dir, 'x.json'), () => 42)).toEqual({ value: 42, source: 'default' });
  });
  it('JsonFile debounces and flushes', () => {
    const jf = new JsonFile<{ n: number }>(path.join(dir, 'd.json'), 10_000);
    jf.save({ n: 1 }); jf.save({ n: 2 });
    expect(existsSync(path.join(dir, 'd.json'))).toBe(false);
    jf.flush();
    expect(jf.load(() => ({ n: 0 })).value).toEqual({ n: 2 });
  });
});

describe('history', () => {
  it('prunes by retention and sanitises', () => {
    const now = Date.parse('2026-09-27T12:00:00Z');
    const recs = sanitizeHistory({ records: [
      { id: 'a', date: '2026-09-27T10:00:00Z', text: 'neu' }, { id: 'b', date: '2026-01-01T10:00:00Z', text: 'alt' }, { nope: true },
    ] });
    expect(recs).toHaveLength(2);
    expect(prune(recs, 30, now).map((r) => r.id)).toEqual(['a']);
  });
  it('add / delete / persist', () => {
    const f = path.join(dir, 'history.json');
    const h = new History(f, () => 90);
    const r = h.add({ text: 'Hallo Welt', raw: 'hallo welt', app: 'notepad.exe', durationSec: 1.2, words: 2, ms: 120 });
    h.add({ text: 'Zweites', raw: 'zweites', app: '', durationSec: 1, words: 1, ms: 80 });
    h.flush();
    const h2 = new History(f, () => 90);
    expect(h2.records.map((x) => x.text)).toEqual(['Zweites', 'Hallo Welt']);
    expect(h2.wordsToday()).toBe(3);
    h2.delete(r.id); h2.flush();
    expect(new History(f, () => 90).records).toHaveLength(1);
  });
});
