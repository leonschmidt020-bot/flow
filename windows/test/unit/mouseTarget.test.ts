// „Text dorthin, wo die Maus ist“ – pure rules: window filtering, DPI/coordinate maths (multi-monitor, negative
// coordinates), click-allowed rules, the auto-Enter list, paste confirmation. No native calls.
import { describe, expect, it } from 'vitest';
import {
  absoluteInput, appKind, autoSend, chatTitle, clickAllowed, dipToPhysRect, HTCLIENT, isPasswordApp, makeLParam, pasteConfirmed, physToDipPoint,
  physToDipRect, pickEditable, pickFromList, resolveTarget, scaleAt, skipReason, visibleFrame, WS_EX, WS, type ClickInput, type DisplayMap,
  type UiaNode, type WinInfo,
} from '../../src/core/mouseTarget';

const OWN = 999;
let nextHwnd = 100;
function win(p: Partial<WinInfo> & { rect: WinInfo['rect'] }): WinInfo {
  return { hwnd: nextHwnd++, pid: 50, exe: 'notepad.exe', cls: 'Notepad', title: 'Unbenannt', style: 0x14cf0000, exStyle: 0x100, visible: true, iconic: false, cloaked: false, ...p };
}
const N = (ct: string, cls = '', extra: Partial<UiaNode> = {}): UiaNode => ({ ct, cls, ...extra });

describe('coordinates: physical ↔ DIP on mixed-DPI multi-monitor layouts', () => {
  // primary 2560×1440 @150 % (DIP 1707×960), left 1920×1080 @100 % at x = −1920, above-right 3840×2160 @200 % at (2560, −1200)
  const primary: DisplayMap = { phys: { x: 0, y: 0, width: 2560, height: 1440 }, dip: { x: 0, y: 0, width: 1707, height: 960 }, scale: 1.5 };
  const left: DisplayMap = { phys: { x: -1920, y: 180, width: 1920, height: 1080 }, dip: { x: -1920, y: 120, width: 1920, height: 1080 }, scale: 1 };
  const upRight: DisplayMap = { phys: { x: 2560, y: -1200, width: 3840, height: 2160 }, dip: { x: 1707, y: -800, width: 1920, height: 1080 }, scale: 2 };
  const all = [primary, left, upRight];

  it('window on the scaled primary monitor', () => {
    expect(physToDipRect({ x: 300, y: 150, width: 1500, height: 900 }, all)).toEqual({ x: 200, y: 100, width: 1000, height: 600 });
  });
  it('window on the monitor left of the primary (negative x)', () => {
    expect(physToDipRect({ x: -1800, y: 300, width: 800, height: 600 }, all)).toEqual({ x: -1800, y: 240, width: 800, height: 600 });
  });
  it('window on the 200 % monitor above (negative y)', () => {
    expect(physToDipRect({ x: 2760, y: -1000, width: 2000, height: 1000 }, all)).toEqual({ x: 1807, y: -700, width: 1000, height: 500 });
  });
  it('a window spanning two monitors uses the one holding most of it', () => {
    const r = physToDipRect({ x: -400, y: 300, width: 1600, height: 600 }, all); // 400 px left, 1200 px primary
    expect(r.width).toBe(Math.round(1600 / 1.5));
  });
  it('off-screen rect → nearest monitor; no monitors → unchanged', () => {
    expect(physToDipRect({ x: -5000, y: 400, width: 100, height: 100 }, all).width).toBe(100);
    expect(physToDipRect({ x: 1, y: 2, width: 3, height: 4 }, [])).toEqual({ x: 1, y: 2, width: 3, height: 4 });
  });
  it('round trip DIP → phys → DIP per monitor, points, scale lookup', () => {
    for (const d of all) {
      const dip = { x: d.dip.x + 40, y: d.dip.y + 30, width: 400, height: 200 };
      expect(physToDipRect(dipToPhysRect(dip, d), all)).toEqual(dip);
    }
    expect(physToDipPoint({ x: -1, y: 500 }, all)).toEqual({ x: -1, y: 440 });
    expect(scaleAt({ x: 10, y: 10 }, all)).toBe(1.5);
    expect(scaleAt({ x: 3000, y: -10 }, all)).toBe(2);
  });
  it('SendInput absolute coordinates span the virtual desktop (incl. negative origin)', () => {
    const vs = { x: -1920, y: -1200, width: 1920 + 2560 + 3840, height: 2640 };
    expect(absoluteInput({ x: -1920, y: -1200 }, vs)).toEqual({ dx: 0, dy: 0 });
    expect(absoluteInput({ x: vs.x + vs.width - 1, y: vs.y + vs.height - 1 }, vs)).toEqual({ dx: 65535, dy: 65535 });
    const mid = absoluteInput({ x: 0, y: 0 }, vs);
    expect(mid.dx).toBe(Math.round((1920 * 65535) / (vs.width - 1)));
    expect(absoluteInput({ x: -99999, y: 99999 }, vs)).toEqual({ dx: 0, dy: 65535 });
  });
  it('MAKELPARAM keeps negative screen coordinates as signed 16-bit halves', () => {
    expect(makeLParam(10, 20)).toBe((20 << 16) | 10);
    const lp = makeLParam(-5, -1200);
    expect(((lp & 0xffff) << 16) >> 16).toBe(-5);
    expect(lp >> 16).toBe(-1200);
    expect(lp).toBeGreaterThanOrEqual(0);
  });
  it('visible frame: DWM bounds for maximized windows, window rect if DWM is implausible', () => {
    const wr = { x: -8, y: -8, width: 2576, height: 1416 };
    expect(visibleFrame(wr, { x: 0, y: 0, width: 2560, height: 1400 })).toEqual({ x: 0, y: 0, width: 2560, height: 1400 });
    expect(visibleFrame(wr, null)).toEqual(wr);
    expect(visibleFrame(wr, { x: 5000, y: 0, width: 10, height: 10 })).toEqual(wr);
  });
});

describe('window filtering', () => {
  const r = { x: 0, y: 0, width: 800, height: 600 };
  it('normal window is a target, own/tool/cloaked/desktop/taskbar are not', () => {
    expect(skipReason(win({ rect: r }), OWN)).toBeNull();
    expect(skipReason(win({ rect: r, pid: OWN }), OWN)).toBe('own');
    expect(skipReason(win({ rect: r, exStyle: WS_EX.TOOLWINDOW }), OWN)).toBe('tool');
    expect(skipReason(win({ rect: r, exStyle: WS_EX.TOOLWINDOW | WS_EX.APPWINDOW }), OWN)).toBeNull();
    expect(skipReason(win({ rect: r, exStyle: WS_EX.NOACTIVATE }), OWN)).toBe('noactivate');
    expect(skipReason(win({ rect: r, exStyle: WS_EX.TRANSPARENT | WS_EX.LAYERED }), OWN)).toBe('clickThrough');
    expect(skipReason(win({ rect: r, cloaked: true }), OWN)).toBe('cloaked');
    expect(skipReason(win({ rect: r, visible: false }), OWN)).toBe('invisible');
    expect(skipReason(win({ rect: r, iconic: true }), OWN)).toBe('iconic');
    expect(skipReason(win({ rect: r, style: WS.CHILD }), OWN)).toBe('child');
    expect(skipReason(win({ rect: r, style: WS.DISABLED }), OWN)).toBe('disabled');
    expect(skipReason(win({ rect: r, cls: 'Progman', exe: 'explorer.exe' }), OWN)).toBe('shell');
    expect(skipReason(win({ rect: r, cls: 'WorkerW', exe: 'explorer.exe' }), OWN)).toBe('shell');
    expect(skipReason(win({ rect: r, cls: 'Shell_TrayWnd', exe: 'explorer.exe' }), OWN)).toBe('shell');
    expect(skipReason(win({ rect: r, cls: 'Windows.UI.Core.CoreWindow', exe: 'SearchHost.exe' }), OWN)).toBe('shell');
    expect(skipReason(win({ rect: r, exe: 'KeePassXC.exe' }), OWN)).toBe('password');
    expect(skipReason(win({ rect: { x: 0, y: 0, width: 30, height: 300 } }), OWN)).toBe('small');
  });

  const p = { x: 500, y: 400 };
  const pill = win({ pid: OWN, exe: 'Flow.exe', cls: 'Chrome_WidgetWin_1', rect: { x: 300, y: 300, width: 460, height: 230 }, exStyle: WS_EX.TOOLWINDOW | WS_EX.NOACTIVATE });
  const term = win({ exe: 'WindowsTerminal.exe', cls: 'CASCADIA_HOSTING_WINDOW_CLASS', rect: { x: 100, y: 100, width: 900, height: 700 } });
  const code = win({ exe: 'Code.exe', cls: 'Chrome_WidgetWin_1', rect: { x: 0, y: 0, width: 1400, height: 900 } });
  const hidden = win({ exe: 'Mail.exe', rect: { x: 0, y: 0, width: 1400, height: 900 }, cloaked: true });
  const taskbar = win({ exe: 'explorer.exe', cls: 'Shell_TrayWnd', rect: { x: 0, y: 1392, width: 2560, height: 48 } });
  const desktop = win({ exe: 'explorer.exe', cls: 'Progman', rect: { x: -1920, y: 0, width: 4480, height: 1440 } });

  it('Z-order: frontmost normal window, own pill looked through (→ covered)', () => {
    expect(pickFromList([pill, hidden, term, code, desktop], p, OWN)).toEqual({ t: 'target', win: term, covered: true });
    expect(pickFromList([hidden, term, code, desktop], { x: 50, y: 50 }, OWN)).toEqual({ t: 'target', win: code, covered: false });
  });
  it('taskbar / desktop → blocked, nothing → none, disabled owner → none', () => {
    expect(pickFromList([taskbar, code, desktop], { x: 100, y: 1400 }, OWN).t).toBe('blocked');
    expect(pickFromList([desktop], { x: 2000, y: 1000 }, OWN).t).toBe('blocked');
    expect(pickFromList([code], { x: 5000, y: 5000 }, OWN).t).toBe('none');
    expect(pickFromList([win({ rect: r, style: WS.DISABLED })], { x: 10, y: 10 }, OWN).t).toBe('none');
  });
  it('WindowFromPoint fast path; own window under the mouse → Z-order walk', () => {
    let walked = 0;
    const z = () => { walked++; return [pill, term, code]; };
    expect(resolveTarget(code, z, p, OWN)).toEqual({ t: 'target', win: code, covered: false });
    expect(walked).toBe(0);
    expect(resolveTarget(pill, z, p, OWN)).toEqual({ t: 'target', win: term, covered: true });
    expect(walked).toBe(1);
    expect(resolveTarget(taskbar, z, p, OWN).t).toBe('blocked');
    expect(resolveTarget(win({ rect: r, exe: '1Password.exe' }), z, p, OWN).t).toBe('none');
    expect(resolveTarget(null, () => [], p, OWN).t).toBe('none');
  });
});

describe('apps', () => {
  it('app kinds', () => {
    expect(appKind('WindowsTerminal.exe')).toBe('terminal');
    expect(appKind('C:\\Windows\\System32\\conhost.exe')).toBe('terminal');
    expect(appKind('whatever.exe', 'ConsoleWindowClass')).toBe('terminal');
    expect(appKind('Code.exe')).toBe('xtermEditor');
    expect(appKind('Cursor.exe')).toBe('xtermEditor');
    expect(appKind('Claude.exe')).toBe('chat');
    expect(appKind('ChatGPT.exe')).toBe('chat');
    expect(appKind('WhatsApp.Root.exe')).toBe('chat');
    expect(appKind('Discord.exe')).toBe('chat');
    expect(appKind('msedge.exe')).toBe('browser');
    expect(appKind('WINWORD.EXE')).toBe('other');
    expect(isPasswordApp('Bitwarden.exe')).toBe(true);
    expect(isPasswordApp('notepad.exe')).toBe(false);
  });
  it('web chats via the tab title – exact names only', () => {
    expect(chatTitle('ChatGPT - Google Chrome')).toBe(true);
    expect(chatTitle('Neuer Chat - Claude - Google Chrome')).toBe(true);
    expect(chatTitle('(3) WhatsApp - Persönlich - Microsoft\u200b Edge')).toBe(true);
    expect(chatTitle('#allgemein | Lenas Server - Discord — Mozilla Firefox')).toBe(true);
    expect(chatTitle('Slack | allgemein | Nico & Lena')).toBe(true);
    expect(chatTitle('Google Gemini')).toBe(true);
    expect(chatTitle('Claude Monet – Wikipedia - Google Chrome')).toBe(false);
    expect(chatTitle('Rezepte mit Claude und ChatGPT vergleichen - Google Chrome')).toBe(false);
    expect(chatTitle('Posteingang - Outlook')).toBe(false);
    expect(chatTitle('')).toBe(false);
  });
});

describe('text field under the mouse', () => {
  it('first editable within 4 levels, password wins, stops at the window', () => {
    expect(pickEditable([N('Text'), N('Edit', '', { editable: true })])).toEqual({ t: 'at', i: 1 });
    expect(pickEditable([N('Edit', '', { pwd: true, editable: true })])).toEqual({ t: 'secure' });
    expect(pickEditable([N('Text'), N('Window'), N('Edit', '', { editable: true })])).toEqual({ t: 'none' });
    expect(pickEditable([N('Text'), N('Group'), N('Group'), N('Group'), N('Group'), N('Edit', '', { editable: true })])).toEqual({ t: 'none' });
  });
});

describe('click allowed (method c)', () => {
  const base: ClickInput = { kind: 'terminal', chatSite: false, exe: 'WindowsTerminal.exe', cls: 'CASCADIA_HOSTING_WINDOW_CLASS', hit: HTCLIENT, chain: [N('Text', 'TermControl')], covered: false, offset: { x: 400, y: 300 }, scale: 1.5 };
  it('terminal surface: yes; covered, title bar, buttons, tabs, passwords: no', () => {
    expect(clickAllowed(base)).toBe(true);
    expect(clickAllowed({ ...base, covered: true })).toBe(false);
    expect(clickAllowed({ ...base, hit: 2 /* HTCAPTION */ })).toBe(false);
    expect(clickAllowed({ ...base, hit: null })).toBe(false);
    expect(clickAllowed({ ...base, chain: [N('Button'), N('Pane')] })).toBe(false);
    expect(clickAllowed({ ...base, chain: [N('TabItem'), N('Tab')] })).toBe(false);
    expect(clickAllowed({ ...base, chain: [N('Hyperlink')] })).toBe(false);
    expect(clickAllowed({ ...base, chain: [N('Edit', '', { pwd: true })] })).toBe(false);
  });
  it('Windows Terminal without UI Automation: never in the tab strip (DPI-scaled)', () => {
    expect(clickAllowed({ ...base, chain: null, offset: { x: 400, y: 60 } })).toBe(false); // 60 px < 44 DIP × 1.5
    expect(clickAllowed({ ...base, chain: null, offset: { x: 400, y: 80 } })).toBe(true);
    expect(clickAllowed({ ...base, chain: null, exe: 'conhost.exe', cls: 'ConsoleWindowClass', offset: { x: 400, y: 10 } })).toBe(true);
  });
  it('VS Code: only on the xterm terminal, never on the Monaco editor or without UI Automation', () => {
    const vs = { ...base, kind: 'xtermEditor' as const, exe: 'Code.exe', cls: 'Chrome_WidgetWin_1' };
    expect(clickAllowed({ ...vs, chain: [N('Group', 'xterm-screen'), N('Group', 'terminal xterm focus'), N('Document')] })).toBe(true);
    expect(clickAllowed({ ...vs, chain: [N('Group', 'view-lines'), N('Group', 'monaco-editor')] })).toBe(false);
    expect(clickAllowed({ ...vs, chain: null })).toBe(false);
  });
  it('chat apps / web chats: only onto an input field', () => {
    const chat = { ...base, kind: 'chat' as const, exe: 'Discord.exe', cls: 'Chrome_WidgetWin_1' };
    expect(clickAllowed({ ...chat, chain: [N('Text'), N('Edit', 'editor', { editable: true })] })).toBe(true);
    expect(clickAllowed({ ...chat, chain: [N('Text'), N('Group', 'messages')] })).toBe(false);
    expect(clickAllowed({ ...chat, chain: null })).toBe(false);
    const web = { ...base, kind: 'browser' as const, exe: 'chrome.exe', cls: 'Chrome_WidgetWin_1', chain: [N('Edit', 'ProseMirror', { editable: true }), N('Group'), N('Document')] };
    expect(clickAllowed({ ...web, chatSite: true })).toBe(true);
    expect(clickAllowed({ ...web, chatSite: false })).toBe(false);
    expect(clickAllowed({ ...base, kind: 'other', exe: 'WINWORD.EXE', cls: 'OpusApp', chain: [N('Document', '', { editable: true })] })).toBe(false);
  });
});

describe('auto-Enter list', () => {
  const ed = (cls = '') => N('Edit', cls, { editable: true });
  it('terminals and chat apps always, also without UI Automation', () => {
    expect(autoSend('terminal', false, null)).toEqual({ send: true });
    expect(autoSend('chat', false, null)).toEqual({ send: true });
    expect(autoSend('chat', false, [ed()])).toEqual({ send: true });
  });
  it('VS Code: xterm, chat inputs and webviews yes; code editor no', () => {
    expect(autoSend('xtermEditor', false, [N('Edit', 'xterm-helper-textarea'), N('Group', 'terminal xterm')]).send).toBe(true);
    expect(autoSend('xtermEditor', false, [N('Edit', 'inputarea'), N('Group', 'monaco-editor')])).toEqual({ send: false, why: 'Code-Editor – Enter wäre eine neue Zeile' });
    expect(autoSend('xtermEditor', false, [N('Edit', 'inputarea'), N('Group', 'monaco-editor'), N('Group', 'interactive-input-part chat-input')]).send).toBe(true);
    expect(autoSend('xtermEditor', false, [ed(), N('Document'), N('Pane'), N('Document')]).send).toBe(true);
    expect(autoSend('xtermEditor', false, null).send).toBe(false);
  });
  it('browsers: only inside a web-chat page, never the address bar', () => {
    const inPage = [ed('ProseMirror'), N('Group'), N('Document')];
    expect(autoSend('browser', true, inPage)).toEqual({ send: true });
    expect(autoSend('browser', false, inPage)).toEqual({ send: false, why: 'keine Chat-Seite' });
    expect(autoSend('browser', true, [ed('OmniboxViewViews'), N('ToolBar'), N('Pane')]).send).toBe(false);
    expect(autoSend('browser', true, [N('Text'), N('Document')]).send).toBe(false);
  });
  it('documents, mail, passwords: never', () => {
    expect(autoSend('other', false, [ed()]).send).toBe(false);
    expect(autoSend('chat', false, [N('Edit', '', { pwd: true })])).toEqual({ send: false, why: 'Passwortfeld' });
    expect(autoSend('terminal', false, [N('Edit', '', { pwd: true })]).send).toBe(false);
  });
  it('paste confirmation', () => {
    expect(pasteConfirmed('Hallo Lena, bis morgen', 'Vorher. Hallo Lena, bis morgen')).toBe(true);
    expect(pasteConfirmed('Hallo Lena, bis morgen', 'Vorher.')).toBe(false);
    expect(pasteConfirmed('Hallo', 'x', 'x')).toBe(false);
    expect(pasteConfirmed('Hallo', '')).toBeUndefined();
    expect(pasteConfirmed('Hallo', null)).toBeUndefined();
    expect(pasteConfirmed('a\n  b', 'x a b')).toBe(true);
  });
});
