// Dictation ↔ mouse target ↔ learner: capture at RELEASE (only via the hotkey), prepare before the paste, Enter only
// after a paste into the target and only with the setting on, the learner watches the target app afterwards.
import { describe, expect, it } from 'vitest';
import { Dictation, type LearnerLike, type MouseTargetLike } from '../../src/main/dictation';
import { DEFAULTS, type Settings } from '../../src/shared/settings';
import type { CaptureResult, Prepared } from '../../src/main/mouse/mouseTarget';

const cap: CaptureResult = { t: 'target', cap: { point: { x: 1, y: 2 }, win: { hwnd: 9, pid: 90, exe: 'WindowsTerminal.exe', cls: 'CASCADIA_HOSTING_WINDOW_CLASS', title: '', rect: { x: 0, y: 0, width: 800, height: 600 }, style: 0, exStyle: 0, visible: true, iconic: false, cloaked: false }, kind: 'terminal', chatSite: false, covered: false, alreadyForeground: false, prev: null, plan: null } };

function make(s: Partial<Settings>, method: Prepared['method'] = 'c') {
  const seq: string[] = [];
  const settings = { ...DEFAULTS, ...s };
  const mouse: MouseTargetLike = {
    beginTracking: () => seq.push('track'),
    endTracking: () => seq.push('untrack'),
    capture: () => { seq.push('capture'); return cap; },
    prepare: async (c) => { seq.push('prepare:' + (c ? c.t : 'null')); return { method, note: 'x', extraMs: 5, cap: c && c.t === 'target' ? c.cap : null }; },
    autoSend: async () => { seq.push('enter'); return 'Enter gesendet'; },
  };
  const learner: LearnerLike = { watch: (_t, target) => seq.push('watch:' + (target?.exe ?? '-')), finish: async () => { seq.push('finish'); }, stop: () => {} };
  const noop = () => {};
  const d = new Dictation({
    mic: { start: async () => {}, stop: async () => new Float32Array(16000), cancel: noop } as never,
    asr: { ready: true, state: { status: 'ready' }, getEngine: () => ({ transcribe: async () => ({ text: 'ls minus la', ms: 5, segments: 1 }) }) } as never,
    pill: { state: noop, toast: (m: string) => seq.push('toast:' + m) } as never,
    history: { add: noop } as never,
    settings: () => settings, clipboard: { snapshot: () => ({ text: '', formats: {} }), restore: noop, writeText: noop, readText: () => '' },
    keys: { paste: () => { seq.push('paste'); } }, foregroundExe: () => 'notepad.exe', waitKeysReleased: async () => {}, markInjecting: noop,
    onClipboardWrite: noop, setWriting: noop, mouse, learner, foregroundProcess: () => ({ pid: 1, exe: 'notepad.exe' }),
  });
  return { d, seq };
}

describe('dictation with „Text dorthin, wo die Maus ist“', () => {
  it('hotkey: track while speaking → capture at release → prepare → paste → Enter → learner on the target app', async () => {
    const { d, seq } = make({ mouseTarget: true, mouseTargetAutoSend: true, keepInClipboard: true });
    await d.start();
    await d.stop();
    expect(seq).toEqual(['finish', 'track', 'capture', 'untrack', 'prepare:target', 'paste', 'enter', 'watch:WindowsTerminal.exe']);
  });
  it('no Enter without the setting, none after method d; the learner then watches the foreground app', async () => {
    const a = make({ mouseTarget: true, keepInClipboard: true });
    await a.d.start(); await a.d.stop();
    expect(a.seq).not.toContain('enter');
    const b = make({ mouseTarget: true, mouseTargetAutoSend: true, keepInClipboard: true }, 'd');
    await b.d.start(); await b.d.stop();
    expect(b.seq).not.toContain('enter');
    expect(b.seq.at(-1)).toBe('watch:notepad.exe');
  });
  it('feature off / stopped with the pill button → no capture, normal paste; learner off → no watch', async () => {
    const off = make({ mouseTarget: false, learnFromEdits: false, keepInClipboard: true });
    await off.d.start(); await off.d.stop();
    expect(off.seq).toEqual(['finish', 'untrack', 'paste']);
    const pillStop = make({ mouseTarget: true, keepInClipboard: true });
    await pillStop.d.start(); await pillStop.d.stop(false);
    expect(pillStop.seq).not.toContain('capture');
    expect(pillStop.seq).toContain('paste');
  });
});
