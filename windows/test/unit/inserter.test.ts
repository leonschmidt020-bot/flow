import { describe, expect, it } from 'vitest';
import { insertText, type ClipboardPort, type ClipSnapshot } from '../../src/main/insert/inserter';

function mockClipboard(initial: string) {
  let text = initial;
  let extra: Record<string, unknown> = { 'text/html': '<b>x</b>' };
  const ops: string[] = [];
  const port: ClipboardPort = {
    snapshot: () => { ops.push('snapshot'); return { text, formats: { ...extra, text } }; },
    restore: (s: ClipSnapshot) => { ops.push('restore'); text = s.text; extra = { ...s.formats }; },
    writeText: (t) => { ops.push('write:' + t); text = t; extra = {}; },
    readText: () => text,
  };
  return { port, ops, get text() { return text; }, set text(v: string) { text = v; } };
}

describe('insertText', () => {
  it('save → write → paste → restore', async () => {
    const cb = mockClipboard('alt');
    const seq: string[] = [];
    const phases: string[] = [];
    const writing: boolean[] = [];
    const r = await insertText('Hallo', {
      clipboard: cb.port, keys: { paste: () => { seq.push('paste:' + cb.text); } }, keepInClipboard: false,
      sleep: async () => {}, onPhase: (p) => phases.push(p), setWriting: (v) => writing.push(v),
    });
    expect(r.restored).toBe(true);
    expect(cb.ops).toEqual(['snapshot', 'write:Hallo', 'restore']);
    expect(seq).toEqual(['paste:Hallo']);
    expect(cb.text).toBe('alt');
    expect(phases).toEqual(['insert', 'restore']);
    expect(writing).toEqual([true, false]);
  });
  it('keep in clipboard → no snapshot/restore', async () => {
    const cb = mockClipboard('alt');
    const phases: string[] = [];
    await insertText('Hallo', { clipboard: cb.port, keys: { paste: () => {} }, keepInClipboard: true, sleep: async () => {}, onPhase: (p) => phases.push(p) });
    expect(cb.ops).toEqual(['write:Hallo']);
    expect(cb.text).toBe('Hallo');
    expect(phases).toEqual(['keep']);
  });
  it('clipboard changed by the user meanwhile → not overwritten', async () => {
    const cb = mockClipboard('alt');
    const r = await insertText('Hallo', {
      clipboard: cb.port, keys: { paste: () => {} }, keepInClipboard: false,
      sleep: async (ms) => { if (ms >= 300) cb.text = 'user copied this'; },
    });
    expect(r.restored).toBe(false);
    expect(cb.text).toBe('user copied this');
  });
  it('writing flag resets even when paste throws', async () => {
    const cb = mockClipboard('alt');
    const w: boolean[] = [];
    await expect(insertText('x', { clipboard: cb.port, keys: { paste: () => { throw new Error('boom'); } }, keepInClipboard: false, sleep: async () => {}, setWriting: (v) => w.push(v) })).rejects.toThrow('boom');
    expect(w).toEqual([true, false]);
  });
  it('restore delay defaults to ~300 ms', async () => {
    const cb = mockClipboard('alt');
    const sleeps: number[] = [];
    await insertText('x', { clipboard: cb.port, keys: { paste: () => {} }, keepInClipboard: false, sleep: async (ms) => { sleeps.push(ms); } });
    expect(sleeps).toContain(300);
  });
});
