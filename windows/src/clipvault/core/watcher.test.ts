// Watcher with an injected FAKE clipboard – the real system clipboard is never touched.
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ClipboardWatcher, type ClipboardAdapter } from './watcher';
import { Store } from './store';
import type { ClipboardFlags } from './sensitive';
import type { NewImage } from './store';

class FakeClipboard implements ClipboardAdapter {
  seq: number | null = 1;
  text = '';
  files: string[] = [];
  image: NewImage | null = null;
  f: ClipboardFlags = {};
  reads = 0;
  sequence() { return this.seq; }
  fingerprint() { return `${this.text}|${this.files.join(',')}|${this.image?.png.length ?? 0}`; }
  flags() { return this.f; }
  readFiles() { this.reads++; return this.files; }
  readText() { this.reads++; return this.text; }
  hasImage() { return !!this.image; }
  readImage() { this.reads++; return this.image; }
  set(p: { text?: string; files?: string[]; image?: NewImage | null; flags?: ClipboardFlags }) {
    this.text = p.text ?? ''; this.files = p.files ?? []; this.image = p.image ?? null; this.f = p.flags ?? {};
    if (this.seq !== null) this.seq++;
  }
}

let dir: string;
beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cv-watch-test-')); });
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

async function setup(opts: Partial<ConstructorParameters<typeof ClipboardWatcher>[2]> = {}) {
  const cb = new FakeClipboard();
  const store = new Store(dir);
  store.load();
  const w = new ClipboardWatcher(cb, store, { setInterval: () => 1, clearInterval: () => {}, ...opts });
  await w.start();
  return { cb, store, w };
}

describe('clipboard watcher', () => {
  it('ignores what was on the clipboard at start, captures changes, cheap when unchanged', async () => {
    const { cb, store, w } = await setup();
    cb.text = 'schon da';
    expect(await w.tick()).toBe('unchanged');
    cb.set({ text: 'neu kopiert' });
    expect(await w.tick()).toBe('captured');
    expect(store.items[0]!.text).toBe('neu kopiert');
    const reads = cb.reads;
    for (let i = 0; i < 20; i++) await w.tick();
    expect(cb.reads).toBe(reads); // no content reads while the sequence number is unchanged
  });

  it('files win over text; images are captured when there is no text', async () => {
    const { cb, store, w } = await setup();
    const f = path.join(dir, 'a.txt');
    fs.writeFileSync(f, 'x');
    cb.set({ files: [f], text: f });
    await w.tick();
    expect(store.items[0]!.kind).toBe('file');
    cb.set({ image: { png: Buffer.from('png'), w: 2, h: 2 } });
    await w.tick();
    expect(store.items[0]!.kind).toBe('image');
  });

  it('skips password-manager / excluded content and never stores it', async () => {
    const skipped: string[] = [];
    const { cb, store, w } = await setup({ onSkipped: (r) => skipped.push(r) });
    cb.set({ text: 'hunter2hunter2', flags: { excludeFromMonitor: true } });
    expect(await w.tick()).toBe('skipped');
    cb.set({ text: 'geheim', flags: { canIncludeInHistory: 0 } });
    expect(await w.tick()).toBe('skipped');
    cb.set({ text: 'also secret', flags: { ownerProcess: 'KeePass.exe' } });
    expect(await w.tick()).toBe('skipped');
    cb.set({ text: 'xQ9!mZ2#pL7@' });
    expect(await w.tick()).toBe('skipped');
    expect(store.items).toEqual([]);
    expect(skipped).toEqual(['exclude-format', 'history-disallowed', 'password-manager', 'password-like']);
    const onDisk = fs.existsSync(store.indexPath) ? fs.readFileSync(store.indexPath, 'utf8') : '';
    expect(onDisk).not.toMatch(/hunter2|geheim|secret|xQ9/);
  });

  it('suppressed while Flow writes the clipboard (dictation insert/restore)', async () => {
    let flowWriting = false;
    const { cb, store, w } = await setup({ isSuppressed: () => flowWriting });
    flowWriting = true;
    cb.set({ text: 'Diktat-Text' });
    expect(await w.tick()).toBe('suppressed');
    flowWriting = false;
    expect(await w.tick()).toBe('unchanged'); // the same content is not picked up afterwards
    expect(store.items).toEqual([]);
  });

  it('skipCurrent() after our own write: the paste-back is not re-captured', async () => {
    const { cb, store, w } = await setup();
    cb.set({ text: 'eins' });
    await w.tick();
    cb.set({ text: 'eins' }); // ClipVault writes the entry back
    await w.skipCurrent();
    expect(await w.tick()).toBe('unchanged');
    expect(store.items.length).toBe(1);
  });

  it('works without a sequence number (fingerprint fallback)', async () => {
    const { cb, store, w } = await setup();
    cb.seq = null;
    await w.skipCurrent();
    cb.set({ text: 'ohne Zähler' });
    expect(await w.tick()).toBe('captured');
    expect(await w.tick()).toBe('unchanged');
    expect(store.items[0]!.text).toBe('ohne Zähler');
  });

  it('pause stops capturing', async () => {
    const { cb, store, w } = await setup();
    await w.pause(true);
    cb.set({ text: 'nicht speichern' });
    expect(await w.tick()).toBe('paused');
    await w.pause(false);
    expect(await w.tick()).toBe('unchanged');
    expect(store.items).toEqual([]);
  });
});
