// Orchestration of „Text dorthin, wo die Maus ist“ with a mocked native layer and a mocked UI Automation helper:
// capture at release, foreground techniques, a/b/c/d, auto-Enter, frame tracking. Plus the koffi prototypes.
import { describe, expect, it } from 'vitest';
import { createRequire } from 'node:module';
import { HTCLIENT, type Point, type Rect, type UiaNode, type WinInfo } from '../../src/core/mouseTarget';
import { MouseTarget, type HighlightPort } from '../../src/main/mouse/mouseTarget';
import type { FocusTechnique, NativeWindows } from '../../src/main/mouse/native';
import type { UiaElement, UiaPort } from '../../src/main/uia/types';
import { defineMouseTypes, MOUSE_PROTOS } from '../../src/main/mouse/win32Windows';

const OWN = 4242;
const W = (hwnd: number, exe: string, cls: string, rect: Rect, extra: Partial<WinInfo> = {}): WinInfo =>
  ({ hwnd, pid: hwnd * 10, exe, cls, title: '', rect, style: 0, exStyle: 0, visible: true, iconic: false, cloaked: false, ...extra });

const editor = W(1, 'notepad.exe', 'Notepad', { x: 0, y: 0, width: 1000, height: 800 });
const term = W(2, 'WindowsTerminal.exe', 'CASCADIA_HOSTING_WINDOW_CLASS', { x: 1000, y: 0, width: 1000, height: 800 });
const chat = W(3, 'Discord.exe', 'Chrome_WidgetWin_1', { x: -1600, y: 100, width: 1600, height: 900 });
const pw = W(4, 'KeePassXC.exe', 'Qt5QWindowIcon', { x: 0, y: 900, width: 600, height: 400 });

class FakeNative implements NativeWindows {
  cursor: Point = { x: 500, y: 400 };
  fg: WinInfo | null = editor;
  windows: WinInfo[] = [editor, term, chat, pw];
  /** which technique brings a window to the front (null = none works) */
  works: FocusTechnique | null = 'direct';
  tried: FocusTechnique[] = [];
  clicks: Point[] = [];
  enters = 0;
  hit: number | null = HTCLIENT;
  cursorPos() { return this.cursor; }
  windowFromPoint(p: Point) { return this.windows.find((w) => p.x >= w.rect.x && p.x < w.rect.x + w.rect.width && p.y >= w.rect.y && p.y < w.rect.y + w.rect.height) ?? null; }
  zOrder() { return this.windows; }
  foreground() { return this.fg; }
  hitTest() { return this.hit; }
  setForeground(hwnd: number, how: FocusTechnique) {
    this.tried.push(how);
    const order: FocusTechnique[] = ['direct', 'attach', 'alt'];
    if (this.works && order.indexOf(how) >= order.indexOf(this.works)) this.fg = this.windows.find((w) => w.hwnd === hwnd) ?? null;
  }
  click(p: Point) { this.clicks.push(p); }
  pressEnter() { this.enters++; }
  virtualScreen() { return { x: -1600, y: 0, width: 3600, height: 1300 }; }
}

class FakeUia implements UiaPort {
  available = true;
  dpiAware = true;
  atEl: UiaElement | null = null;
  focusedEl: UiaElement | null = null;
  setFocusOk = true;
  focusCalls: Point[] = [];
  async at() { return this.atEl; }
  async focused(o?: { value?: boolean }) { return this.focusedEl && (o?.value ? this.focusedEl : { ...this.focusedEl, value: undefined }); }
  async setFocusAt(p: Point) { this.focusCalls.push(p); return this.setFocusOk; }
  async read() { return null; }
  async reread() { return null; }
  dispose() {}
}
const el = (chain: UiaNode[], root: number, extra: Partial<UiaElement> = {}): UiaElement => ({ chain, root, pid: 1, pwd: !!chain[0]?.pwd, editable: !!chain[0]?.editable, ...extra });

function setup(o: { highlight?: HighlightPort; mouseTarget?: boolean; frame?: boolean } = {}) {
  const native = new FakeNative();
  const uia = new FakeUia();
  let now = 0;
  const logs: string[] = [];
  const injected: number[] = [];
  let held = false;
  const mt = new MouseTarget({
    native, uia, highlight: o.highlight ?? null, ownPid: OWN,
    settings: () => ({ mouseTarget: o.mouseTarget ?? true, mouseTargetHighlight: o.frame ?? true }),
    text: (k) => k, displays: () => [{ phys: { x: 0, y: 0, width: 2000, height: 1300 }, dip: { x: 0, y: 0, width: 1000, height: 650 }, scale: 2 }],
    log: (...a) => logs.push(a.join(' ')), now: () => now, sleep: async (ms) => { now += ms; await new Promise((r) => setImmediate(r)); },
    markInjecting: (ms) => injected.push(ms), hotkeyHeld: () => held,
    timers: { setInterval: (() => 1) as unknown as typeof setInterval, clearInterval: (() => {}) as unknown as typeof clearInterval },
  });
  return { native, uia, mt, logs, injected, setHeld: (v: boolean) => { held = v; }, get now() { return now; } };
}

describe('capture at key release', () => {
  it('mouse over the active window → method 0, 0 ms, no UI Automation', async () => {
    const s = setup();
    const c = s.mt.capture();
    expect(c.t === 'target' && c.cap.alreadyForeground).toBe(true);
    expect(c.t === 'target' && c.cap.plan).toBeNull();
    expect(await s.mt.prepare(c)).toMatchObject({ method: '0', extraMs: 0 });
  });
  it('the window under the mouse at RELEASE counts (not at press)', () => {
    const s = setup();
    s.mt.beginTracking();
    s.native.cursor = { x: 1500, y: 400 }; // moved to the terminal while speaking
    const c = s.mt.capture();
    expect(c.t === 'target' && c.cap.win.exe).toBe('WindowsTerminal.exe');
    expect(c.t === 'target' && c.cap.kind).toBe('terminal');
  });
  it('password manager under the mouse / nothing under the mouse → no target', async () => {
    const s = setup();
    s.native.cursor = { x: 100, y: 1000 };
    const c = s.mt.capture();
    expect(c).toEqual({ t: 'none', why: 'Passwort-App' });
    expect((await s.mt.prepare(c)).method).toBe('–');
    s.native.cursor = { x: 5000, y: 5000 };
    expect(s.mt.capture().t).toBe('none');
  });
});

describe('prepare: bring to front, pick the input', () => {
  it('a) text field under the mouse → UI Automation SetFocus, no click', async () => {
    const s = setup();
    s.native.fg = term;
    s.native.cursor = { x: 300, y: 300 };
    s.uia.atEl = el([{ ct: 'Edit', cls: 'Edit', editable: true }, { ct: 'Window', cls: 'Notepad' }], editor.hwnd);
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.method).toBe('a');
    expect(p.focus).toBe('direct');
    expect(s.native.fg).toBe(editor);
    expect(s.native.clicks).toEqual([]);
    expect(s.uia.focusCalls).toEqual([{ x: 300, y: 300 }]);
  });
  it('c) terminal: one click at the release point when direct SetForegroundWindow is refused → AttachThreadInput', async () => {
    const s = setup();
    s.native.works = 'attach';
    s.native.cursor = { x: 1500, y: 400 };
    s.uia.atEl = el([{ ct: 'Text', cls: 'TermControl' }, { ct: 'Window', cls: 'CASCADIA_HOSTING_WINDOW_CLASS' }], term.hwnd);
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.method).toBe('c');
    expect(p.focus).toBe('attach');
    expect(s.native.tried).toEqual(['direct', 'attach']);
    expect(s.native.clicks).toEqual([{ x: 1500, y: 400 }]);
    // the fake clock also counts the 350 ms timer that lost the race against the UI Automation answer
    expect(p.extraMs - 350).toBeLessThanOrEqual(400);
  });
  it('ALT tap as last resort is marked as our own input', async () => {
    const s = setup();
    s.native.works = 'alt';
    s.native.cursor = { x: 1500, y: 400 };
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.focus).toBe('alt');
    expect(s.native.tried).toEqual(['direct', 'attach', 'alt']);
    expect(s.injected.length).toBeGreaterThan(0);
  });
  it('no click on the title bar / a tab / when UI Automation says button', async () => {
    for (const variant of ['caption', 'tab'] as const) {
      const s = setup();
      s.native.cursor = { x: 1500, y: 20 };
      if (variant === 'caption') s.native.hit = 2;
      s.uia.atEl = el(variant === 'tab' ? [{ ct: 'TabItem', cls: '' }, { ct: 'Tab', cls: '' }] : [{ ct: 'Text', cls: 'TermControl' }], term.hwnd);
      const p = await s.mt.prepare(s.mt.capture());
      expect(p.method).toBe('b');
      expect(s.native.clicks).toEqual([]);
    }
  });
  it('b) no field and no click allowed → the remembered focus', async () => {
    const s = setup();
    s.native.fg = term;
    s.native.cursor = { x: 300, y: 300 };
    s.uia.atEl = el([{ ct: 'Document', cls: 'RichEditD2DPT' }], editor.hwnd);
    expect((await s.mt.prepare(s.mt.capture())).method).toBe('b');
  });
  it('an answer from ANOTHER window is ignored (two windows of the same app)', async () => {
    const s = setup();
    s.native.cursor = { x: 1500, y: 400 };
    s.uia.atEl = el([{ ct: 'Edit', cls: '', editable: true }], 777);
    const p = await s.mt.prepare(s.mt.capture());
    expect(s.uia.focusCalls).toEqual([]);
    expect(p.method).toBe('c'); // terminal without UIA info: click on the client area, below the tab strip
  });
  it('d) password field under the mouse → nothing switched, pasted normally', async () => {
    const s = setup();
    s.native.fg = term;
    s.native.cursor = { x: 300, y: 300 };
    s.uia.atEl = el([{ ct: 'Edit', cls: '', pwd: true }], editor.hwnd);
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.method).toBe('d');
    expect(s.native.fg).toBe(term);
    expect(s.native.tried).toEqual([]);
  });
  it('d) the window does not come to the front within 400 ms → toast, back to the previous window', async () => {
    const s = setup();
    s.native.works = null;
    s.native.cursor = { x: 1500, y: 400 };
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.method).toBe('d');
    expect(p.toast).toBe('toastFocusFailed');
    // focus budget 400 ms (+ going back to the previous window, + the lost 350 ms race timer of the fake clock)
    expect(s.native.tried.slice(0, 3)).toEqual(['direct', 'attach', 'alt']);
    expect(p.extraMs - 350).toBeLessThanOrEqual(2 * 420);
  });
  it('the user switched windows himself during the dictation → his choice counts', async () => {
    const s = setup();
    s.native.cursor = { x: 1500, y: 400 };
    const c = s.mt.capture();
    s.native.fg = chat;
    expect(await s.mt.prepare(c)).toMatchObject({ method: '–', extraMs: 0 });
    expect(s.native.tried).toEqual([]);
  });
  it('a slow UI Automation answer does not hold up the paste (≤ 350 ms)', async () => {
    const s = setup();
    s.native.cursor = { x: 1500, y: 400 };
    s.uia.at = () => new Promise(() => {}); // never answers
    const p = await s.mt.prepare(s.mt.capture());
    expect(p.method).toBe('c');
    expect(s.now).toBeLessThan(800);
  });
  it('switched off / captured nothing', async () => {
    const s = setup();
    expect((await s.mt.prepare(null)).method).toBe('–');
  });
});

describe('auto-Enter', () => {
  async function prepared(s: ReturnType<typeof setup>, cursor: Point, at: UiaElement | null) {
    s.native.cursor = cursor;
    s.uia.atEl = at;
    return s.mt.prepare(s.mt.capture());
  }
  it('terminal: Enter after a short pause for bracketed paste', async () => {
    const s = setup();
    const p = await prepared(s, { x: 1500, y: 400 }, null);
    expect(await s.mt.autoSend('ls -la', p)).toBe('Enter gesendet');
    expect(s.native.enters).toBe(1);
  });
  it('chat: only when the pasted text is really in the field', async () => {
    const s = setup();
    const at = el([{ ct: 'Edit', cls: 'editor', editable: true }], chat.hwnd);
    const p = await prepared(s, { x: -800, y: 500 }, at);
    expect(p.method).toBe('a');
    s.uia.focusedEl = { ...at, value: 'noch nichts' };
    expect(await s.mt.autoSend('Hallo Nico, bis gleich', p)).toBe('kein Enter: Einfügen nicht bestätigt');
    s.uia.focusedEl = { ...at, value: 'Hallo Nico, bis gleich' };
    expect(await s.mt.autoSend('Hallo Nico, bis gleich', p)).toBe('Enter gesendet');
    expect(s.native.enters).toBe(1);
  });
  it('document app, switched window, hotkey still held, method d: no Enter', async () => {
    const s = setup();
    s.native.fg = term;
    const p = await prepared(s, { x: 300, y: 300 }, el([{ ct: 'Edit', cls: 'Edit', editable: true }], editor.hwnd));
    s.uia.focusedEl = el([{ ct: 'Edit', cls: 'Edit', editable: true }], editor.hwnd);
    expect(await s.mt.autoSend('Hallo', p)).toBe('kein Enter: App nicht auf der Enter-Liste');
    const s2 = setup();
    const p2 = await prepared(s2, { x: 1500, y: 400 }, null);
    s2.setHeld(true);
    expect(await s2.mt.autoSend('ls', p2)).toBe('kein Enter: Fokus/Taste geändert');
    s2.setHeld(false);
    s2.native.fg = chat;
    expect(await s2.mt.autoSend('ls', p2)).toBe('kein Enter: Fenster gewechselt');
    expect(await s2.mt.autoSend('ls', { ...p2, method: 'd' })).toMatch(/^kein Enter/);
    expect(s2.native.enters).toBe(0);
  });
});

describe('frame „Text kommt hierher“ follows the mouse', () => {
  function hl() {
    const calls: string[] = [];
    const port: HighlightPort = { show: (r, label) => calls.push(`show ${r.x},${r.y},${r.width}x${r.height} ${label}`), hide: () => calls.push('hide') };
    return { calls, port };
  }
  it('shown over a non-active window in DIP, hidden over the active one, only redrawn after moving', () => {
    const h = hl();
    const s = setup({ highlight: h.port });
    s.native.cursor = { x: 1500, y: 400 };
    s.mt.beginTracking();
    expect(h.calls.at(-1)).toBe('show 500,0,500x400 label'); // 2× scale
    const n = h.calls.length;
    s.native.cursor = { x: 1502, y: 401 };
    s.mt.tick();
    expect(h.calls.length).toBe(n); // < 4 px: nothing to do
    s.native.cursor = { x: 300, y: 300 };
    s.mt.tick();
    expect(h.calls.at(-1)).toBe('hide');
    s.mt.endTracking();
    expect(h.calls.at(-1)).toBe('hide');
  });
  it('switched off → never shown; feature off → no tracking at all', () => {
    const h = hl();
    const s = setup({ highlight: h.port, frame: false });
    s.native.cursor = { x: 1500, y: 400 };
    s.mt.beginTracking();
    expect(h.calls.some((c) => c.startsWith('show'))).toBe(false);
    const h2 = hl();
    const s2 = setup({ highlight: h2.port, mouseTarget: false });
    s2.mt.beginTracking();
    expect(s2.mt.tracking).toBe(false);
  });
});

describe('koffi bindings', () => {
  const require = createRequire(import.meta.url);
  const koffi = require('koffi');
  it('all prototypes parse and POINT/RECT have the Windows layout', () => {
    const T = defineMouseTypes(koffi);
    expect(koffi.sizeof(T.POINT)).toBe(8);
    expect(koffi.sizeof(T.RECT)).toBe(16);
    for (const [name, p] of Object.entries(MOUSE_PROTOS)) expect(() => koffi.proto(p), name).not.toThrow();
  });
});
