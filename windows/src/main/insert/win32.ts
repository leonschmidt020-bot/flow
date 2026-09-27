// Windows-only native bits via koffi → user32/kernel32 (no compiled addon of our own).
//   SendInput (Ctrl+V, Start-menu mask key), foreground process name.
/* eslint-disable @typescript-eslint/no-explicit-any */
import type { KeySender } from './inserter';

export const VK = { CONTROL: 0x11, LCONTROL: 0xa2, RCONTROL: 0xa3, V: 0x56, SHIFT: 0x10, MENU: 0x12, LWIN: 0x5b, RWIN: 0x5c, MASK: 0xe8 } as const;
export const INPUT_KEYBOARD = 1;
export const KEYEVENTF_KEYUP = 0x0002;
/** marks our own injected events (dwExtraInfo) */
export const FLOW_EXTRA = 0x464c4f57; // 'FLOW'

let koffi: any = null;
function k(): any {

  if (!koffi) koffi = require('koffi');
  return koffi;
}

/** struct layout (also checked by a unit test: sizeof(INPUT) must be 40 on x64) */
export function defineTypes(kf: any = k()) {
  const KEYBDINPUT = kf.struct('FLOW_KEYBDINPUT', { wVk: 'uint16', wScan: 'uint16', dwFlags: 'uint32', time: 'uint32', dwExtraInfo: 'uintptr_t' });
  const MOUSEINPUT = kf.struct('FLOW_MOUSEINPUT', { dx: 'int32', dy: 'int32', mouseData: 'uint32', dwFlags: 'uint32', time: 'uint32', dwExtraInfo: 'uintptr_t' });
  const HARDWAREINPUT = kf.struct('FLOW_HARDWAREINPUT', { uMsg: 'uint32', wParamL: 'uint16', wParamH: 'uint16' });
  const U = kf.union('FLOW_INPUT_U', { mi: MOUSEINPUT, ki: KEYBDINPUT, hi: HARDWAREINPUT });
  const INPUT = kf.struct('FLOW_INPUT', { type: 'uint32', u: U });
  return { KEYBDINPUT, MOUSEINPUT, HARDWAREINPUT, INPUT };
}

export const PROTOS = {
  SendInput: 'uint32_t __stdcall SendInput(uint32_t cInputs, FLOW_INPUT *pInputs, int cbSize)',
  GetForegroundWindow: 'void * __stdcall GetForegroundWindow()',
  GetWindowThreadProcessId: 'uint32_t __stdcall GetWindowThreadProcessId(void *hWnd, _Out_ uint32_t *pid)',
  GetAsyncKeyState: 'int16_t __stdcall GetAsyncKeyState(int vKey)',
  OpenProcess: 'void * __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)',
  CloseHandle: 'int __stdcall CloseHandle(void *h)',
  QueryFullProcessImageNameW: 'int __stdcall QueryFullProcessImageNameW(void *h, uint32_t flags, void *buf, _Inout_ uint32_t *size)',
} as const;

let api: null | { SendInput: any; INPUT: any; GetForegroundWindow: any; GetWindowThreadProcessId: any; OpenProcess: any; CloseHandle: any; QueryFullProcessImageNameW: any; GetAsyncKeyState: any } = null;

function load() {
  if (api) return api;
  const kf = k();
  const { INPUT } = defineTypes(kf);
  const user32 = kf.load('user32.dll');
  const kernel32 = kf.load('kernel32.dll');
  api = {
    INPUT,
    SendInput: user32.func(PROTOS.SendInput),
    GetForegroundWindow: user32.func(PROTOS.GetForegroundWindow),
    GetWindowThreadProcessId: user32.func(PROTOS.GetWindowThreadProcessId),
    GetAsyncKeyState: user32.func(PROTOS.GetAsyncKeyState),
    OpenProcess: kernel32.func(PROTOS.OpenProcess),
    CloseHandle: kernel32.func(PROTOS.CloseHandle),
    QueryFullProcessImageNameW: kernel32.func(PROTOS.QueryFullProcessImageNameW),
  };
  return api;
}

const key = (vk: number, up: boolean) => ({ type: INPUT_KEYBOARD, u: { ki: { wVk: vk, wScan: 0, dwFlags: up ? KEYEVENTF_KEYUP : 0, time: 0, dwExtraInfo: FLOW_EXTRA } } });

export function sendKeys(events: { vk: number; up: boolean }[]): number {
  const a = load();
  const arr = events.map((e) => key(e.vk, e.up));
  const size = k().sizeof(a.INPUT);
  try {
    return a.SendInput(arr.length, arr, size);
  } catch {
    // older koffi builds: no array→pointer conversion; send one by one
    let n = 0;
    for (const e of arr) n += a.SendInput(1, e, size);
    return n;
  }
}

/** Is a virtual key physically down right now? */
export function isKeyDown(vk: number): boolean {
  try { return (load().GetAsyncKeyState(vk) & 0x8000) !== 0; } catch { return false; }
}

export class Win32KeySender implements KeySender {
  async paste() {
    // release modifiers the user might still hold (Alt/Shift/Win would turn Ctrl+V into something else)
    const up: { vk: number; up: boolean }[] = [];
    for (const vk of [VK.SHIFT, VK.MENU, VK.LWIN, VK.RWIN, VK.RCONTROL]) if (isKeyDown(vk)) up.push({ vk, up: true });
    if (up.length) sendKeys(up);
    sendKeys([{ vk: VK.LCONTROL, up: false }, { vk: VK.V, up: false }, { vk: VK.V, up: true }, { vk: VK.LCONTROL, up: true }]);
  }
}

/** Inject an unassigned key while Win is held, so releasing Win does not open the Start menu. */
export function sendStartMenuMask() {
  try { sendKeys([{ vk: VK.MASK, up: false }, { vk: VK.MASK, up: true }]); } catch { /* not fatal */ }
}

/** "WINWORD.EXE" of the foreground window, or '' */
export function foregroundExe(): string {
  try {
    const a = load();
    const hwnd = a.GetForegroundWindow();
    if (!hwnd) return '';
    const pid = [0];
    a.GetWindowThreadProcessId(hwnd, pid);
    if (!pid[0]) return '';
    const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const h = a.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid[0]);
    if (!h) return '';
    try {
      const buf = Buffer.alloc(2048);
      const len = [1024];
      if (!a.QueryFullProcessImageNameW(h, 0, buf, len)) return '';
      const full = buf.toString('utf16le', 0, (len[0] ?? 0) * 2);
      return full.split('\\').pop() ?? '';
    } finally {
      a.CloseHandle(h);
    }
  } catch {
    return '';
  }
}
