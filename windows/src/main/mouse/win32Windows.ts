// Windows-only: the native layer for „Text dorthin, wo die Maus ist“ via koffi → user32 / dwmapi / kernel32.
// HWNDs are declared as intptr_t so they travel as plain numbers (handles fit into 32 bits on 64-bit Windows).
// NOT verified on a real Windows PC by the author of this port – see README „Was nur ein echter Windows-PC prüfen kann“.
/* eslint-disable @typescript-eslint/no-explicit-any */
import { absoluteInput, ltrb, makeLParam, visibleFrame, type Point, type Rect, type WinInfo } from '../../core/mouseTarget';
import { FLOW_EXTRA, sendKeys, sendRaw, VK } from '../insert/win32';
import type { FocusTechnique, NativeWindows } from './native';

export const W32 = {
  GA_ROOT: 2, GW_HWNDNEXT: 2, GWL_STYLE: -16, GWL_EXSTYLE: -20, WM_NCHITTEST: 0x84, SMTO_ABORTIFHUNG: 0x2,
  DWMWA_EXTENDED_FRAME_BOUNDS: 9, DWMWA_CLOAKED: 14,
  SM_XVIRTUALSCREEN: 76, SM_YVIRTUALSCREEN: 77, SM_CXVIRTUALSCREEN: 78, SM_CYVIRTUALSCREEN: 79,
  INPUT_MOUSE: 0, MOUSEEVENTF_MOVE: 0x1, MOUSEEVENTF_LEFTDOWN: 0x2, MOUSEEVENTF_LEFTUP: 0x4, MOUSEEVENTF_VIRTUALDESK: 0x4000, MOUSEEVENTF_ABSOLUTE: 0x8000,
  PROCESS_QUERY_LIMITED_INFORMATION: 0x1000,
} as const;

/** prototypes (checked by a unit test with koffi.proto on any OS) */
export const MOUSE_PROTOS = {
  GetCursorPos: 'int __stdcall GetCursorPos(_Out_ FLOW_POINT *pt)',
  SetCursorPos: 'int __stdcall SetCursorPos(int x, int y)',
  WindowFromPoint: 'intptr_t __stdcall WindowFromPoint(FLOW_POINT pt)',
  GetAncestor: 'intptr_t __stdcall GetAncestor(intptr_t hwnd, uint32_t flags)',
  GetTopWindow: 'intptr_t __stdcall GetTopWindow(intptr_t hwnd)',
  GetWindow: 'intptr_t __stdcall GetWindow(intptr_t hwnd, uint32_t cmd)',
  GetForegroundWindow: 'intptr_t __stdcall GetForegroundWindow()',
  SetForegroundWindow: 'int __stdcall SetForegroundWindow(intptr_t hwnd)',
  BringWindowToTop: 'int __stdcall BringWindowToTop(intptr_t hwnd)',
  AttachThreadInput: 'int __stdcall AttachThreadInput(uint32_t idAttach, uint32_t idAttachTo, int attach)',
  GetWindowThreadProcessId: 'uint32_t __stdcall GetWindowThreadProcessId(intptr_t hwnd, _Out_ uint32_t *pid)',
  GetClassNameW: 'int __stdcall GetClassNameW(intptr_t hwnd, void *buf, int max)',
  GetWindowTextW: 'int __stdcall GetWindowTextW(intptr_t hwnd, void *buf, int max)',
  GetWindowLongPtrW: 'intptr_t __stdcall GetWindowLongPtrW(intptr_t hwnd, int index)',
  IsWindowVisible: 'int __stdcall IsWindowVisible(intptr_t hwnd)',
  IsIconic: 'int __stdcall IsIconic(intptr_t hwnd)',
  GetWindowRect: 'int __stdcall GetWindowRect(intptr_t hwnd, _Out_ FLOW_RECT *rect)',
  SendMessageTimeoutW: 'intptr_t __stdcall SendMessageTimeoutW(intptr_t hwnd, uint32_t msg, uintptr_t wParam, intptr_t lParam, uint32_t flags, uint32_t timeout, _Out_ intptr_t *result)',
  PhysicalToLogicalPointForPerMonitorDPI: 'int __stdcall PhysicalToLogicalPointForPerMonitorDPI(intptr_t hwnd, _Inout_ FLOW_POINT *pt)',
  GetSystemMetrics: 'int __stdcall GetSystemMetrics(int index)',
  FindWindowExW: 'intptr_t __stdcall FindWindowExW(intptr_t parent, intptr_t after, const char16_t *cls, const char16_t *title)',
  GetCurrentThreadId: 'uint32_t __stdcall GetCurrentThreadId()',
  OpenProcess: 'intptr_t __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)',
  CloseHandle: 'int __stdcall CloseHandle(intptr_t h)',
  QueryFullProcessImageNameW: 'int __stdcall QueryFullProcessImageNameW(intptr_t h, uint32_t flags, void *buf, _Inout_ uint32_t *size)',
  DwmGetWindowAttribute: 'int32_t __stdcall DwmGetWindowAttribute(intptr_t hwnd, uint32_t attr, void *out, uint32_t size)',
} as const;

let types: { POINT: any; RECT: any } | null = null;
/** koffi registers struct names globally → define once */
export function defineMouseTypes(kf: any) {
  if (!types) types = { POINT: kf.struct('FLOW_POINT', { x: 'int32', y: 'int32' }), RECT: kf.struct('FLOW_RECT', { left: 'int32', top: 'int32', right: 'int32', bottom: 'int32' }) };
  return types;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createWin32Native(): NativeWindows {
  const kf: any = require('koffi');
  defineMouseTypes(kf);
  const user32 = kf.load('user32.dll');
  const kernel32 = kf.load('kernel32.dll');
  const dwmapi = kf.load('dwmapi.dll');
  const lib = (name: keyof typeof MOUSE_PROTOS) => (name === 'GetCurrentThreadId' || name === 'OpenProcess' || name === 'CloseHandle' || name === 'QueryFullProcessImageNameW' ? kernel32
    : name === 'DwmGetWindowAttribute' ? dwmapi : user32);
  const f: Record<string, any> = {};
  for (const [name, proto] of Object.entries(MOUSE_PROTOS)) {
    try { f[name] = lib(name as keyof typeof MOUSE_PROTOS).func(proto); } catch { f[name] = null; } // e.g. PhysicalToLogical… on old Windows
  }
  const n = (v: unknown) => Number(v ?? 0);
  const buf = Buffer.alloc(1024);

  const exeCache = new Map<number, string>();
  function exeOf(pid: number): string {
    if (!pid) return '';
    const c = exeCache.get(pid);
    if (c !== undefined) return c;
    let exe = '';
    const h = n(f.OpenProcess(W32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid));
    if (h) {
      try {
        const b = Buffer.alloc(2048);
        const len = [1024];
        if (f.QueryFullProcessImageNameW(h, 0, b, len)) exe = b.toString('utf16le', 0, (len[0] ?? 0) * 2).split('\\').pop() ?? '';
      } finally { f.CloseHandle(h); }
    }
    if (exeCache.size > 256) exeCache.clear();
    exeCache.set(pid, exe);
    return exe;
  }
  const text = (fn: any, hwnd: number) => { const len = n(fn(hwnd, buf, 512)); return len > 0 ? buf.toString('utf16le', 0, Math.min(len, 511) * 2) : ''; };
  const pidOf = (hwnd: number) => { const p = [0]; f.GetWindowThreadProcessId(hwnd, p); return n(p[0]); };

  function info(hwnd: number): WinInfo | null {
    if (!hwnd) return null;
    let pid = pidOf(hwnd);
    const cls = text(f.GetClassNameW, hwnd);
    // UWP apps: the frame belongs to ApplicationFrameHost.exe, the app itself is the CoreWindow inside
    if (cls === 'ApplicationFrameWindow' && f.FindWindowExW) {
      const core = n(f.FindWindowExW(hwnd, 0, 'Windows.UI.Core.CoreWindow', null));
      if (core) pid = pidOf(core) || pid;
    }
    const r: any = {};
    f.GetWindowRect(hwnd, r);
    const wr = ltrb(n(r.left), n(r.top), n(r.right), n(r.bottom));
    const fb = Buffer.alloc(16);
    const frame = n(f.DwmGetWindowAttribute(hwnd, W32.DWMWA_EXTENDED_FRAME_BOUNDS, fb, 16)) === 0
      ? ltrb(fb.readInt32LE(0), fb.readInt32LE(4), fb.readInt32LE(8), fb.readInt32LE(12)) : null;
    const cb = Buffer.alloc(4);
    const cloaked = n(f.DwmGetWindowAttribute(hwnd, W32.DWMWA_CLOAKED, cb, 4)) === 0 && cb.readUInt32LE(0) !== 0;
    return {
      hwnd, pid, exe: exeOf(pid), cls, title: text(f.GetWindowTextW, hwnd), rect: visibleFrame(wr, frame),
      style: n(f.GetWindowLongPtrW(hwnd, W32.GWL_STYLE)) | 0, exStyle: n(f.GetWindowLongPtrW(hwnd, W32.GWL_EXSTYLE)) | 0,
      visible: !!n(f.IsWindowVisible(hwnd)), iconic: !!n(f.IsIconic(hwnd)), cloaked,
    };
  }

  const cursorPos = (): Point => { const p: any = {}; f.GetCursorPos(p); return { x: n(p.x), y: n(p.y) }; };
  const virtualScreen = (): Rect => ({ x: n(f.GetSystemMetrics(W32.SM_XVIRTUALSCREEN)), y: n(f.GetSystemMetrics(W32.SM_YVIRTUALSCREEN)),
    width: n(f.GetSystemMetrics(W32.SM_CXVIRTUALSCREEN)), height: n(f.GetSystemMetrics(W32.SM_CYVIRTUALSCREEN)) });

  return {
    cursorPos,
    virtualScreen,
    windowFromPoint(p) {
      const h = n(f.WindowFromPoint({ x: Math.round(p.x), y: Math.round(p.y) }));
      return h ? info(n(f.GetAncestor(h, W32.GA_ROOT)) || h) : null;
    },
    zOrder() {
      const out: WinInfo[] = [];
      let h = n(f.GetTopWindow(0));
      for (let i = 0; h && i < 600; i++) {
        // cheap pre-filter before the full info: only visible windows
        if (n(f.IsWindowVisible(h))) { const w = info(h); if (w) out.push(w); }
        h = n(f.GetWindow(h, W32.GW_HWNDNEXT));
      }
      return out;
    },
    foreground() { return info(n(f.GetForegroundWindow())); },
    hitTest(hwnd, p) {
      const pt: any = { x: Math.round(p.x), y: Math.round(p.y) };
      // DPI-unaware / system-aware windows think in logical coordinates
      try { f.PhysicalToLogicalPointForPerMonitorDPI?.(hwnd, pt); } catch { /* keep physical */ }
      const res = [0];
      const ok = n(f.SendMessageTimeoutW(hwnd, W32.WM_NCHITTEST, 0, makeLParam(n(pt.x), n(pt.y)), W32.SMTO_ABORTIFHUNG, 100, res));
      return ok ? n(res[0]) | 0 : null;
    },
    setForeground(hwnd, how: FocusTechnique) {
      if (how === 'direct') { f.SetForegroundWindow(hwnd); return; }
      if (how === 'attach') {
        // share the input state with the current foreground thread → SetForegroundWindow is allowed
        const fg = n(f.GetForegroundWindow());
        const fgThread = fg ? n(f.GetWindowThreadProcessId(fg, [0])) : 0;
        const me = n(f.GetCurrentThreadId());
        const attached = fgThread && fgThread !== me ? !!n(f.AttachThreadInput(me, fgThread, 1)) : false;
        try { f.BringWindowToTop(hwnd); f.SetForegroundWindow(hwnd); } finally { if (attached) f.AttachThreadInput(me, fgThread, 0); }
        return;
      }
      // 'alt': while ALT is down Windows lets any process change the foreground window (the Alt+Tab path).
      // An unassigned key before ALT-up keeps the menu bar of the new window from opening (same trick as the Start-menu mask).
      sendKeys([{ vk: VK.MENU, up: false }]);
      try { f.SetForegroundWindow(hwnd); } finally { sendKeys([{ vk: VK.MASK, up: false }, { vk: VK.MASK, up: true }, { vk: VK.MENU, up: true }]); }
    },
    async click(p) {
      const back = cursorPos();
      const { dx, dy } = absoluteInput(p, virtualScreen());
      const base = W32.MOUSEEVENTF_ABSOLUTE | W32.MOUSEEVENTF_VIRTUALDESK | W32.MOUSEEVENTF_MOVE;
      const ev = (flags: number) => ({ type: W32.INPUT_MOUSE, u: { mi: { dx, dy, mouseData: 0, dwFlags: base | flags, time: 0, dwExtraInfo: FLOW_EXTRA } } });
      sendRaw([ev(0), ev(W32.MOUSEEVENTF_LEFTDOWN)]);
      await sleep(12);
      sendRaw([ev(W32.MOUSEEVENTF_LEFTUP)]);
      if (Math.hypot(back.x - p.x, back.y - p.y) > 1) { await sleep(12); f.SetCursorPos(back.x, back.y); }
    },
    pressEnter() { sendKeys([{ vk: VK.RETURN, up: false }, { vk: VK.RETURN, up: true }]); },
  };
}
