// Agent-Prompt history (prompts/: atomic, corruption quarantine, max 50) and the flow (original saved BEFORE building,
// cancel/failure offer both original options, late answer after cancel ignored, modes, offer card, without Claude CLI).
import { beforeEach, describe, expect, it } from 'vitest';
import { existsSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { APBuilder, type Runner } from '../../src/agentPrompt/builder';
import { emptyContext } from '../../src/agentPrompt/core';
import { APFlow, SOURCE_ORIGINAL, SOURCE_PROMPT, type APActions, type APPhase, type APPresenter, type APTarget } from '../../src/agentPrompt/flow';
import { APStore, MAX_PROMPTS, ORIGINAL_MARK, parse, serialize, type APRecord } from '../../src/agentPrompt/store';
import { FALLBACK_DE, LONG_DE1, SAMPLE_PROMPT_DE, TERM, VSC } from '../../src/agentPrompt/testSet';
import type { APAction, APFlash, APMode } from '../../src/shared/agentPrompt';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let dir = '';
beforeEach(() => { dir = mkdtempSync(path.join(os.tmpdir(), 'flow-prompts-')); });

const rec = (over: Partial<APRecord> = {}): APRecord => ({
  id: 'abc12345-0000', created: '2026-09-21T10:00:00.000Z', prompt: SAMPLE_PROMPT_DE, original: 'Original mit\nzwei Zeilen und --- Strichen',
  appName: 'Visual Studio Code', windowTitle: 'a\nb', source: 'claude/sonnet/low', note: '', trigger: 'zuruf', buildMs: 9000, ...over,
});

describe('store (prompts/)', () => {
  it('one .md file, no write leftovers, read back = written (prompt AND original)', () => {
    const s = new APStore(dir);
    const r = rec();
    s.add(r);
    const files = readdirSync(dir);
    expect(files.filter((f) => f.endsWith('.md'))).toHaveLength(1);
    expect(files.some((f) => f.startsWith('.tmp-'))).toBe(false);
    if (process.platform !== 'win32') expect(statSync(path.join(dir, files[0]!)).mode & 0o777).toBe(0o600);
    const back = new APStore(dir).records[0];
    expect(back).toEqual({ ...r, windowTitle: 'a b' });
    expect(readFileSync(s.filePath(r), 'utf8')).toContain(ORIGINAL_MARK);
  });

  it('broken files skipped + moved to defekt/ (nothing deleted), leftovers removed', () => {
    const s = new APStore(dir);
    s.add(rec());
    writeFileSync(path.join(dir, '2026-01-01_000000_kaputt.md'), 'kein Kopf');
    writeFileSync(path.join(dir, '2026-01-02_000000_halb.md'), '---\nid: x\n');
    writeFileSync(path.join(dir, '.tmp-123.md'), 'halb geschrieben');
    const s3 = new APStore(dir);
    expect(s3.records).toHaveLength(1);
    expect(s3.quarantined).toBe(2);
    expect(readdirSync(dir).some((f) => f.startsWith('.tmp-'))).toBe(false);
    expect(readdirSync(path.join(dir, 'defekt'))).toHaveLength(2);
  });

  it('overwrite same id, at most 50 (newest first), delete removes the file', () => {
    const s = new APStore(dir);
    s.add(rec());
    s.add(rec({ prompt: '**Ziel:** neu' }));
    expect(new APStore(dir).records[0]!.prompt).toBe('**Ziel:** neu');
    for (let i = 0; i < 55; i++) s.add(rec({ id: `n${i}`, created: new Date(Date.parse('2026-09-22T00:00:00Z') + i * 1000).toISOString(), prompt: `**Ziel:** ${i}`, original: `o${i}` }));
    const s4 = new APStore(dir);
    expect(s4.records).toHaveLength(MAX_PROMPTS);
    expect(s4.records[0]!.id).toBe('n54');
    expect(readdirSync(dir).filter((f) => f.endsWith('.md'))).toHaveLength(MAX_PROMPTS);
    s4.delete('n54');
    expect(new APStore(dir).record('n54')).toBeNull();
  });

  it('format: CRLF tolerated, prompt required', () => {
    const r = rec();
    expect(parse(serialize(r).replace(/\n/g, '\r\n'))?.prompt).toBe(r.prompt);
    expect(parse(serialize({ ...r, prompt: '' }))).toBeNull();
  });
});

// ── flow ──

class FakePresenter implements APPresenter {
  shown: APPhase[] = [];
  closed = 0;
  flashes: APFlash[] = [];
  isShowing = false;
  onAction: (a: APAction) => void = () => {};
  show(p: APPhase) { this.shown.push(p); this.isShowing = true; }
  close() { this.closed++; this.isShowing = false; }
  flash(f: APFlash) { this.flashes.push(f); }
  get last() { return this.shown[this.shown.length - 1]; }
}

function setup(o: { claude?: boolean; mode?: APMode; runner?: Runner; fallback?: boolean } = {}) {
  const copies: [string, string][] = [];
  const inserts: [string, string, APTarget | null][] = [];
  const history: string[] = [];
  const toasts: string[] = [];
  const logs: string[] = [];
  let busy = false;
  let copiesAtBuild = -1;
  let ran = false;
  const actions: APActions = {
    copy: (t, s) => { copies.push([t, s]); },
    insert: async (t, s, target) => { inserts.push([t, s, target]); return true; },
    openHub: () => {},
    addHistory: (t) => { history.push(t); },
    toast: (t) => { toasts.push(t); },
    pillBusy: (on) => { busy = on; },
    now: () => Date.now(),
    claudeAvailable: () => o.claude ?? true,
    log: (l) => { logs.push(l); },
    text: (k) => k,
  };
  const pres = new FakePresenter();
  const store = new APStore(dir);
  const state = { mode: o.mode ?? ('on' as APMode) };
  const runner: Runner = o.runner ?? (async (a) => { copiesAtBuild = copies.length; ran = true; a.onText('**Ziel:**'); return SAMPLE_PROMPT_DE; });
  const wrapped: Runner = async (a) => { copiesAtBuild = copies.length; ran = true; return runner(a); };
  const flow = new APFlow({
    mode: () => state.mode, store, presenter: pres, actions, partialMs: 0,
    makeBuilder: () => new APBuilder({ runner: wrapped, available: () => o.claude ?? true, timeoutMs: 3000, ruleFallback: o.fallback ?? true }),
  });
  const target: APTarget = { hwnd: 7, pid: 70, exe: TERM, title: 'claude' };
  const input = (duration = 20) => ({ duration, target, context: { ...emptyContext(), appName: 'Terminal', exe: TERM, windowTitle: 'claude' } });
  const waitEnd = async () => { for (let i = 0; i < 300 && flow.isBuilding; i++) await sleep(10); await sleep(5); };
  return { flow, pres, store, state, copies, inserts, history, toasts, logs, input, waitEnd, get busy() { return busy; }, get copiesAtBuild() { return copiesAtBuild; }, get ran() { return ran; }, target };
}

describe('flow: „Prompt: …“', () => {
  it('success: original saved FIRST, then built, prompt last in the clipboard, card + history + store', async () => {
    const x = setup();
    const said = 'Prompt: bitte bau den Export um, so dass CSV und PDF gehen, und lass alle Tests laufen.';
    expect(x.flow.consume(said, x.input())).toBe(true);
    expect(x.copies[0]).toEqual([expect.stringMatching(/^Bitte bau den Export/), SOURCE_ORIGINAL]);
    expect(x.history[0]!.startsWith('Bitte bau den Export')).toBe(true);
    expect(x.pres.shown[0]!.kind).toBe('building');
    expect(x.busy).toBe(true);
    await x.waitEnd();
    expect(x.copiesAtBuild).toBeGreaterThanOrEqual(1); // the original lay in the clipboard BEFORE building
    expect(x.copies[x.copies.length - 1]).toEqual([SAMPLE_PROMPT_DE, SOURCE_PROMPT]);
    expect(x.busy).toBe(false);
    const last = x.pres.last!;
    expect(last.kind).toBe('done');
    if (last.kind !== 'done') return;
    expect(last.record.original.startsWith('Bitte bau den Export')).toBe(true);
    expect(last.record.prompt).toBe(SAMPLE_PROMPT_DE);
    expect(last.record.trigger).toBe('zuruf');
    expect(new APStore(dir).records).toHaveLength(1);
    // done card: original copy/insert, prompt insert (into the dictation's target), copy, open
    x.pres.onAction('copyOriginal');
    expect(x.copies[x.copies.length - 1]![1]).toBe(SOURCE_ORIGINAL);
    expect(x.pres.flashes).toContain('copiedOriginal');
    x.pres.onAction('insertOriginal');
    await sleep(1);
    expect(x.inserts[x.inserts.length - 1]).toEqual([last.record.original, SOURCE_ORIGINAL, x.target]);
    x.pres.onAction('insert');
    await sleep(1);
    expect(x.inserts[x.inserts.length - 1]).toEqual([SAMPLE_PROMPT_DE, SOURCE_PROMPT, x.target]);
    x.pres.onAction('copy');
    expect(x.pres.flashes).toContain('copied');
  });

  it('logs never contain dictated text', async () => {
    const x = setup();
    x.flow.consume('Prompt: bitte prüf den Geheimwert Zebrafant und schreib einen Test dafür.', x.input());
    await x.waitEnd();
    expect(x.logs.length).toBeGreaterThan(0);
    for (const l of x.logs) { expect(l).not.toContain('Zebrafant'); expect(l).not.toContain('Settings'); }
    expect(x.logs.some((l) => /claude\/sonnet\/low · \d+ → \d+ Wörter/.test(l))).toBe(true);
  });

  it('cancel: card keeps the original, clipboard stays at the original, both original buttons, late answer ignored', async () => {
    let finishLate: (s: string) => void = () => {};
    const x = setup({ runner: () => new Promise<string>((res) => { finishLate = res; }) });
    expect(x.flow.consume('Agent-Prompt: recherchier die drei besten Bibliotheken für PDF-Export in Swift.', x.input())).toBe(true);
    await sleep(20);
    expect(x.flow.isBuilding).toBe(true);
    x.pres.onAction('cancel');
    const last = x.pres.last!;
    expect(last.kind === 'stopped' && last.stop).toBe('cancelled');
    if (last.kind !== 'stopped') return;
    expect(last.original.startsWith('Recherchier die drei')).toBe(true);
    expect(x.copies.map((c) => c[1])).toEqual([SOURCE_ORIGINAL]);
    x.pres.onAction('insertOriginal');
    await sleep(1);
    expect(x.inserts[x.inserts.length - 1]!.slice(0, 2)).toEqual([last.original, SOURCE_ORIGINAL]);
    x.pres.onAction('copyOriginal');
    expect(x.copies[x.copies.length - 1]).toEqual([last.original, SOURCE_ORIGINAL]);
    // the fake Claude answers after all – must change nothing
    finishLate(SAMPLE_PROMPT_DE);
    await sleep(30);
    expect(x.pres.last!.kind).toBe('stopped');
    expect(new APStore(dir).records).toHaveLength(0);
    expect(x.copies.some((c) => c[1] === SOURCE_PROMPT)).toBe(false);
  });

  it('Esc: while building only with the mouse on the card; afterwards it closes the card', async () => {
    const x = setup({ runner: () => new Promise<string>(() => {}) });
    x.flow.consume('Prompt: fix den Crash in Parser.swift bei leeren Zeilen und schreib einen Test.', x.input());
    x.flow.escape(false);
    expect(x.flow.isBuilding).toBe(true);
    x.flow.escape(true);
    expect(x.flow.isBuilding).toBe(false);
    expect(x.pres.last!.kind).toBe('stopped');
    x.flow.escape(false);
    expect(x.pres.isShowing).toBe(false);
  });

  it('failure (no fallback): reason + original, clipboard ends with the original, both buttons, „Nochmal“ rebuilds', async () => {
    let mode = 'fail';
    const x = setup({ fallback: false, runner: async () => { if (mode === 'fail') throw new Error('Claude-CLI Fehler (1)'); return SAMPLE_PROMPT_DE; } });
    x.flow.consume('Prompt: fix den Crash in Parser.swift bei leeren Zeilen und schreib einen Test.', x.input());
    await x.waitEnd();
    const last = x.pres.last!;
    expect(last.kind === 'stopped' && last.stop).toBe('failed');
    if (last.kind !== 'stopped') return;
    expect(last.reason).toBe('Claude nicht erreichbar');
    expect(last.original.startsWith('Fix den Crash')).toBe(true);
    expect(x.copies.map((c) => c[1])).toEqual([SOURCE_ORIGINAL]);
    x.pres.onAction('insertOriginal');
    x.pres.onAction('copyOriginal');
    await sleep(1);
    expect(x.inserts[x.inserts.length - 1]![0]).toBe(last.original);
    expect(x.copies[x.copies.length - 1]![0]).toBe(last.original);
    mode = 'ok';
    x.pres.onAction('retry');
    await x.waitEnd();
    expect(x.pres.last!.kind).toBe('done');
  });

  it('insert that fails → toast „in der Zwischenablage“', async () => {
    const x = setup();
    x.flow.consume('Prompt: bitte bau den Export um und lass alle Tests laufen, danach alles committen.', x.input());
    await x.waitEnd();
    (x.flow as unknown as { d: { actions: APActions } }).d.actions.insert = async () => false;
    x.pres.onAction('insert');
    await sleep(5);
    expect(x.toasts).toEqual(['promptInClipboard']);
  });
});

describe('flow: modes + offer card', () => {
  it('„Aus“: nothing is intercepted', () => {
    const x = setup({ mode: 'off' });
    expect(x.flow.consume('Prompt: bau das um und prüf die Tests.', x.input())).toBe(false);
    expect(x.copies).toHaveLength(0);
  });
  it('„Nur auf Zuruf“: intercepts „Prompt: …“, but never offers', () => {
    const x = setup({ mode: 'explicitOnly' });
    expect(x.flow.offerIfLong(LONG_DE1, { duration: 40, target: { hwnd: 1, pid: 1, exe: VSC, title: 'x' }, context: emptyContext() })).toBeNull();
    expect(x.pres.isShowing).toBe(false);
    expect(x.flow.consume('Prompt: bau das um und prüf die Tests.', x.input())).toBe(true);
  });
  it('„An“: long task → offer card; accepted: only the prompt is added (the text was pasted already)', async () => {
    const x = setup();
    const d = x.flow.offerIfLong(LONG_DE1, { duration: 40, target: { hwnd: 1, pid: 1, exe: VSC, title: 'SettingsPanel.tsx' }, context: { ...emptyContext(), exe: VSC } });
    expect(d?.offer).toBe(true);
    expect(x.pres.last!.kind).toBe('offer');
    x.pres.onAction('build');
    await x.waitEnd();
    expect(x.copies.map((c) => c[1])).toEqual([SOURCE_PROMPT]);
    const last = x.pres.last!;
    expect(last.kind === 'done' && last.record.trigger).toBe('vorschlag');
  });
  it('offer dismissed / short dictation → no card', () => {
    const x = setup();
    x.flow.offerIfLong(LONG_DE1, { duration: 40, target: { hwnd: 1, pid: 1, exe: VSC, title: '' }, context: emptyContext() });
    x.pres.onAction('dismissOffer');
    expect(x.pres.isShowing).toBe(false);
    x.flow.offerIfLong('Ja passt, mach so.', { duration: 2, target: { hwnd: 1, pid: 1, exe: TERM, title: '' }, context: emptyContext() });
    expect(x.pres.isShowing).toBe(false);
  });
});

describe('flow: without the Claude CLI (optional)', () => {
  it('no automatic offer; „Prompt: …“ still intercepted → rule prompt with reason, details kept, original first', async () => {
    const x = setup({ claude: false });
    expect(x.flow.offerIfLong(LONG_DE1, { duration: 42, target: { hwnd: 1, pid: 1, exe: VSC, title: 'SettingsPanel.tsx' }, context: emptyContext() })).toBeNull();
    expect(x.pres.shown).toHaveLength(0);
    expect(x.flow.consume('Prompt: ' + FALLBACK_DE, x.input(30))).toBe(true);
    await x.waitEnd();
    expect(x.ran).toBe(false);
    const last = x.pres.last!;
    expect(last.kind).toBe('done');
    if (last.kind !== 'done') return;
    expect(last.record.source).toBe('regeln');
    expect(last.record.note).toBe('Claude-CLI fehlt');
    expect(last.record.prompt).toContain('users.controller.ts');
    expect(last.record.prompt).toContain('## Aufgabe');
    expect(x.copies[0]![1]).toBe(SOURCE_ORIGINAL);
    expect(x.copies[x.copies.length - 1]![1]).toBe(SOURCE_PROMPT);
    expect(existsSync(dir)).toBe(true);
  });
});
