// Word learner service (watching, polling, finish) and the UI Automation client protocol – both with mocks.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CorrectionLearner } from '../../src/main/learn/correctionLearner';
import type { Suggestion } from '../../src/core/learner';
import type { UiaPort, UiaRead } from '../../src/main/uia/types';
import { toElement, toRead, UiaClient, type LineProcess } from '../../src/main/uia/uiaClient';

class ScriptedUia implements UiaPort {
  available = true;
  dpiAware = true;
  /** successive answers of read()/reread(); the last one repeats */
  reads: (UiaRead | null)[] = [];
  calls = 0;
  private next() { this.calls++; return this.reads.length > 1 ? this.reads.shift()! : this.reads[0] ?? null; }
  async at() { return null; }
  async focused() { return null; }
  async setFocusAt() { return false; }
  async read() { return this.next(); }
  async reread() { return this.next(); }
  dispose() {}
}
const field = (text: string, pid = 7): UiaRead => ({ kind: 'field', text, pid });

describe('CorrectionLearner service', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  function make(fgPid = 7, exe = 'notepad.exe') {
    const uia = new ScriptedUia();
    const asked: Suggestion[][] = [];
    const logs: string[] = [];
    let fg = { pid: fgPid, exe };
    const l = new CorrectionLearner({
      uia, foreground: () => fg, onCandidate: (s) => asked.push(s), log: (m) => logs.push(String(m)), now: () => Date.now(),
    });
    return { uia, asked, logs, l, setFg: (p: number) => { fg = { pid: p, exe }; } };
  }

  it('finds the pasted text, asks after three equal readings, logs no text', async () => {
    const m = make();
    const ins = 'wir treffen uns morgen bei ID um acht';
    m.uia.reads = [field(`Hallo Lena, ${ins}.`), field(`Hallo Lena, ${ins.replace('ID', 'Lidl')}.`)];
    m.l.watch(ins, { pid: 7, exe: 'notepad.exe' });
    await vi.advanceTimersByTimeAsync(400);
    expect(m.l.watching).toBe(true);
    await vi.advanceTimersByTimeAsync(1500 * 3);
    expect(m.asked).toEqual([[{ old: 'ID', options: ['Lidl'] }]]);
    expect(m.logs.join('\n')).not.toMatch(/treffen|Lidl|Lena/u);
  });

  it('a new dictation (finish) compares one last time', async () => {
    const m = make();
    m.uia.reads = [field('frag mal Klot ob das geht'), field('frag mal Claude ob das geht')];
    m.l.watch('frag mal Klot ob das geht', { pid: 7, exe: 'notepad.exe' });
    await vi.advanceTimersByTimeAsync(400);
    await m.l.finish();
    expect(m.asked).toEqual([[{ old: 'Klot', options: ['Claude'] }]]);
    expect(m.l.watching).toBe(false);
  });

  it('does not read while another app is in front; ends after 3 minutes', async () => {
    const m = make();
    m.uia.reads = [field('bitte an Nico schicken')];
    m.l.watch('bitte an Nico schicken', { pid: 7, exe: 'notepad.exe' });
    await vi.advanceTimersByTimeAsync(400);
    const calls = m.uia.calls;
    m.setFg(99);
    await vi.advanceTimersByTimeAsync(1500 * 4);
    expect(m.uia.calls).toBe(calls);
    await vi.advanceTimersByTimeAsync(181_000);
    expect(m.l.watching).toBe(false);
    expect(m.logs.some((x) => x.includes('nach 3 Min.'))).toBe(true);
  });

  it('password field, password manager, rejected pairs, no UI Automation', async () => {
    const m = make();
    m.uia.reads = [{ kind: 'none', pwd: true, pid: 7 }];
    m.l.watch('geheim', { pid: 7, exe: 'notepad.exe' });
    await vi.advanceTimersByTimeAsync(400);
    expect(m.l.watching).toBe(false);
    expect(m.logs.at(-1)).toMatch(/Passwortfeld/u);

    const p = make(8, 'Bitwarden.exe');
    p.l.watch('hallo', { pid: 8, exe: 'Bitwarden.exe' });
    expect(p.logs.at(-1)).toMatch(/Passwort-App/u);
    await vi.advanceTimersByTimeAsync(5000);
    expect(p.uia.calls).toBe(0);

    const r = make();
    const l2 = new CorrectionLearner({ uia: r.uia, foreground: () => ({ pid: 7, exe: 'x.exe' }), onCandidate: (s) => r.asked.push(s), isRejected: (o) => o === 'ID' });
    r.uia.reads = [field('bei ID um acht'), field('bei Lidl um acht')];
    l2.watch('bei ID um acht', { pid: 7, exe: 'x.exe' });
    await vi.advanceTimersByTimeAsync(400 + 1500 * 4);
    expect(r.asked).toEqual([]);

    const off = make();
    off.uia.available = false;
    off.l.watch('hallo', null);
    expect(off.logs.at(-1)).toMatch(/UI Automation nicht verfügbar/u);
  });

  it('retries up to 8 times while the terminal draws late, then gives up with a hint for VS Code', async () => {
    const m = make(5, 'Code.exe');
    m.uia.reads = [{ kind: 'xterm', rows: [], pid: 5 }];
    m.l.watch('teste bitte den Lerner', { pid: 5, exe: 'Code.exe' });
    await vi.advanceTimersByTimeAsync(400 + 500 * 8);
    expect(m.uia.calls).toBe(8);
    expect(m.logs.at(-1)).toMatch(/Bildschirmleser/u);
  });
});

describe('UiaClient (JSON line protocol, mocked process)', () => {
  function fakeProc(answer: (req: Record<string, unknown>) => Record<string, unknown> | null, ready: Record<string, unknown> | null = { ready: true, v: 1, dpi: true }) {
    let lineCb: (l: string) => void = () => {};
    let exitCb: (c: number | null) => void = () => {};
    const sent: Record<string, unknown>[] = [];
    let killed = 0;
    const proc: LineProcess = {
      write: (l) => {
        const req = JSON.parse(l) as Record<string, unknown>;
        sent.push(req);
        const a = answer(req);
        if (a) setTimeout(() => lineCb(JSON.stringify({ id: req.id, ...a })), 1);
      },
      onLine: (cb) => { lineCb = cb; if (ready) setTimeout(() => cb(JSON.stringify(ready)), 1); },
      onExit: (cb) => { exitCb = cb; },
      kill: () => { killed++; exitCb(1); },
    };
    return { proc, sent, get killed() { return killed; } };
  }

  it('starts once, answers requests, normalises PowerShell JSON', async () => {
    let spawns = 0;
    const f = fakeProc((req) => req.cmd === 'focused'
      ? { ok: true, el: { chain: { ct: 'ControlType.Edit', cls: 'Edit', ed: true }, root: '131844', pid: 12, pwd: false, ed: true, value: 'Hallo' } }
      : req.cmd === 'read' ? { ok: true, kind: 'terminal', rows: 'eine Zeile', pid: 3 } : { ok: false });
    const c = new UiaClient({ spawn: () => { spawns++; return f.proc; } });
    const el = await c.focused({ value: true });
    expect(el).toEqual({ chain: [{ ct: 'Edit', cls: 'Edit', editable: true }], root: 131844, pid: 12, pwd: false, editable: true, value: 'Hallo' });
    expect(await c.read()).toEqual({ kind: 'terminal', rows: ['eine Zeile'], pid: 3, root: 0 });
    expect(await c.reread()).toBeNull();
    expect(spawns).toBe(1);
    expect(c.dpiAware).toBe(true);
    expect(f.sent.map((r) => r.cmd)).toEqual(['focused', 'read', 'reread']);
    c.dispose();
  });

  it('a hung request is killed after its timeout; a helper that never starts is given up after 3 tries', async () => {
    const f = fakeProc(() => null);
    const c = new UiaClient({ spawn: () => f.proc });
    expect(await c.request('focused', {}, 30)).toBeNull();
    expect(f.killed).toBe(1);

    const dead = fakeProc(() => null, null);
    const d = new UiaClient({ spawn: () => dead.proc, startTimeoutMs: 20 });
    for (let i = 0; i < 3; i++) expect(await d.focused()).toBeNull();
    expect(d.available).toBe(false);
  });

  it('DPI-unaware helper: coordinate commands are not trusted', async () => {
    const f = fakeProc(() => ({ ok: true, el: { chain: [{ ct: 'Edit', cls: '' }], root: 1, pid: 1 } }), { ready: true, v: 1, dpi: false });
    const c = new UiaClient({ spawn: () => f.proc });
    expect(await c.at({ x: 1, y: 2 })).toBeNull();
    expect(await c.setFocusAt({ x: 1, y: 2 })).toBe(false);
    expect(await c.focused()).not.toBeNull();
  });

  it('password results never carry text', () => {
    expect(toRead({ ok: true, kind: 'field', pwd: true, text: 'geheim', pid: 1 })).toEqual({ kind: 'none', pwd: true, pid: 1, root: 0 });
    expect(toElement({ chain: [{ ct: 'Edit', cls: '', pwd: true }], value: 'geheim' })?.value).toBeUndefined();
    expect(toElement({ chain: [] })).toBeNull();
  });
});
