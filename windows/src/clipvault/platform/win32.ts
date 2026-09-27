// Windows bindings via koffi (user32 / kernel32 / shell32 / crypt32). Loaded lazily; if koffi or a DLL is
// missing, ClipVault falls back to the generic platform (copy works, no auto-paste, no DPAPI).
//
// Only runs on Windows – on the Mac dev machine this file is never executed (tests use fakes).
import { createRequire } from 'node:module';
import type { ClipboardFlags } from '../core/sensitive';
import type { IndexCodec } from '../core/store';
import type { Platform, WindowRef } from './types';

/* Minimal typing of the koffi surface we use (koffi ships its own .d.ts; we don't depend on it at compile time). */
interface KoffiLib { func(decl: string): (...args: unknown[]) => unknown }
interface Koffi {
  load(dll: string): KoffiLib;
  struct(name: string, def: Record<string, string>): unknown;
}

const CF_UNICODETEXT = 13;
const CF_HDROP = 15;
const GMEM_MOVEABLE = 0x0002;
const GMEM_ZEROINIT = 0x0040;
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
const CRYPTPROTECT_UI_FORBIDDEN = 0x1;
const INPUT_KEYBOARD = 1;
const KEYEVENTF_KEYUP = 0x0002;
const VK_CONTROL = 0x11;
const VK_SHIFT = 0x10;
const VK_MENU = 0x12;
const VK_V = 0x56;
const ENTROPY = Buffer.from('ClipVault-Flow-Windows|v1', 'utf8');

function sleep(ms: number) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { /* ignore */ }
}

export function loadWin32Platform(log: (...a: unknown[]) => void = () => {}): Platform | null {
  if (process.platform !== 'win32') return null;
  let koffi: Koffi;
  try {
    koffi = createRequire(__filename)('koffi') as Koffi;
  } catch (e) {
    log('[clipvault] koffi not available – generic clipboard mode', (e as Error).message);
    return null;
  }
  try {
    const user32 = koffi.load('user32.dll');
    const kernel32 = koffi.load('kernel32.dll');
    const shell32 = koffi.load('shell32.dll');
    const crypt32 = koffi.load('crypt32.dll');
    koffi.struct('CV_DATA_BLOB', { cbData: 'uint32_t', pbData: 'void *' });

    const GetClipboardSequenceNumber = user32.func('uint32_t __stdcall GetClipboardSequenceNumber()') as () => number;
    const RegisterClipboardFormatW = user32.func('uint32_t __stdcall RegisterClipboardFormatW(str16 name)') as (n: string) => number;
    const IsClipboardFormatAvailable = user32.func('int __stdcall IsClipboardFormatAvailable(uint32_t fmt)') as (f: number) => number;
    const OpenClipboard = user32.func('int __stdcall OpenClipboard(intptr_t hwnd)') as (h: WindowRef) => number;
    const CloseClipboard = user32.func('int __stdcall CloseClipboard()') as () => number;
    const EmptyClipboard = user32.func('int __stdcall EmptyClipboard()') as () => number;
    const GetClipboardData = user32.func('void * __stdcall GetClipboardData(uint32_t fmt)') as (f: number) => unknown;
    const SetClipboardData = user32.func('void * __stdcall SetClipboardData(uint32_t fmt, void *mem)') as (f: number, m: unknown) => unknown;
    const GetClipboardOwner = user32.func('intptr_t __stdcall GetClipboardOwner()') as () => WindowRef;
    const GetWindowThreadProcessId = user32.func('uint32_t __stdcall GetWindowThreadProcessId(intptr_t hwnd, _Out_ uint32_t *pid)') as (h: WindowRef, out: number[]) => number;
    const GetForegroundWindow = user32.func('intptr_t __stdcall GetForegroundWindow()') as () => WindowRef;
    const SetForegroundWindow = user32.func('int __stdcall SetForegroundWindow(intptr_t hwnd)') as (h: WindowRef) => number;
    const IsWindow = user32.func('int __stdcall IsWindow(intptr_t hwnd)') as (h: WindowRef) => number;
    const AttachThreadInput = user32.func('int __stdcall AttachThreadInput(uint32_t a, uint32_t b, int attach)') as (a: number, b: number, c: number) => number;
    const SendInput = user32.func('uint32_t __stdcall SendInput(uint32_t n, uint8_t *inputs, int cb)') as (n: number, b: Buffer, cb: number) => number;
    const GetAsyncKeyState = user32.func('int16_t __stdcall GetAsyncKeyState(int vk)') as (vk: number) => number;
    const GetCurrentThreadId = kernel32.func('uint32_t __stdcall GetCurrentThreadId()') as () => number;
    const OpenProcess = kernel32.func('void * __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)') as (a: number, i: number, p: number) => unknown;
    const CloseHandle = kernel32.func('int __stdcall CloseHandle(void *h)') as (h: unknown) => number;
    const QueryFullProcessImageNameW = kernel32.func('int __stdcall QueryFullProcessImageNameW(void *h, uint32_t flags, _Out_ uint8_t *buf, _Inout_ uint32_t *size)') as (h: unknown, f: number, b: Buffer, s: number[]) => number;
    const GlobalAlloc = kernel32.func('void * __stdcall GlobalAlloc(uint32_t flags, size_t bytes)') as (f: number, n: number) => unknown;
    const GlobalFree = kernel32.func('void * __stdcall GlobalFree(void *h)') as (h: unknown) => unknown;
    const GlobalLock = kernel32.func('void * __stdcall GlobalLock(void *h)') as (h: unknown) => unknown;
    const GlobalUnlock = kernel32.func('int __stdcall GlobalUnlock(void *h)') as (h: unknown) => number;
    const GlobalSize = kernel32.func('size_t __stdcall GlobalSize(void *h)') as (h: unknown) => number;
    const LocalFree = kernel32.func('void * __stdcall LocalFree(void *h)') as (h: unknown) => unknown;
    const CopyToBuffer = kernel32.func('void __stdcall RtlMoveMemory(_Out_ uint8_t *dst, void *src, size_t n)') as (d: Buffer, s: unknown, n: number) => void;
    const CopyFromBuffer = kernel32.func('void __stdcall RtlMoveMemory(void *dst, uint8_t *src, size_t n)') as (d: unknown, s: Buffer, n: number) => void;
    const DragQueryFileW = shell32.func('uint32_t __stdcall DragQueryFileW(void *hdrop, uint32_t i, _Out_ uint8_t *buf, uint32_t cch)') as (h: unknown, i: number, b: Buffer | null, n: number) => number;
    const CryptProtectData = crypt32.func('int __stdcall CryptProtectData(CV_DATA_BLOB *inp, str16 desc, CV_DATA_BLOB *entropy, void *res, void *prompt, uint32_t flags, _Out_ CV_DATA_BLOB *out)') as (...a: unknown[]) => number;
    const CryptUnprotectData = crypt32.func('int __stdcall CryptUnprotectData(CV_DATA_BLOB *inp, void *desc, CV_DATA_BLOB *entropy, void *res, void *prompt, uint32_t flags, _Out_ CV_DATA_BLOB *out)') as (...a: unknown[]) => number;

    const fmt = {
      exclude: RegisterClipboardFormatW('ExcludeClipboardContentFromMonitorProcessing'),
      canInclude: RegisterClipboardFormatW('CanIncludeInClipboardHistory'),
      viewerIgnore: RegisterClipboardFormatW('Clipboard Viewer Ignore'),
      dropEffect: RegisterClipboardFormatW('Preferred DropEffect'),
    };

    const withClipboard = <T>(owner: WindowRef, fn: () => T): T | null => {
      for (let i = 0; i < 5; i++) {
        if (OpenClipboard(owner)) {
          try { return fn(); } finally { CloseClipboard(); }
        }
        sleep(8);
      }
      return null;
    };

    /** copy a Buffer into a new movable global block */
    const toGlobal = (data: Buffer): unknown => {
      const h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, data.length);
      if (!h) return null;
      const p = GlobalLock(h);
      if (!p) { GlobalFree(h); return null; }
      CopyFromBuffer(p, data, data.length);
      GlobalUnlock(h);
      return h;
    };

    const blob = (data: Buffer) => {
      const h = toGlobal(data.length ? data : Buffer.alloc(1));
      return { mem: h, s: { cbData: data.length, pbData: h ? GlobalLock(h) : null } };
    };
    const freeBlob = (b: { mem: unknown }) => { if (b.mem) { GlobalUnlock(b.mem); GlobalFree(b.mem); } };

    const dpapiCall = (data: Buffer, protect: boolean): Buffer => {
      const inp = blob(data);
      const ent = blob(ENTROPY);
      const out: { cbData?: number; pbData?: unknown } = {};
      try {
        const ok = protect
          ? CryptProtectData(inp.s, 'ClipVault', ent.s, null, null, CRYPTPROTECT_UI_FORBIDDEN, out)
          : CryptUnprotectData(inp.s, null, ent.s, null, null, CRYPTPROTECT_UI_FORBIDDEN, out);
        if (!ok || !out.pbData) throw new Error(protect ? 'CryptProtectData failed' : 'CryptUnprotectData failed');
        const res = Buffer.alloc(out.cbData ?? 0);
        if (res.length) CopyToBuffer(res, out.pbData, res.length);
        LocalFree(out.pbData);
        return res;
      } finally {
        freeBlob(inp);
        freeBlob(ent);
      }
    };

    const dpapi: IndexCodec = {
      name: 'dpapi',
      protect: (p) => dpapiCall(p, true),
      unprotect: (b) => dpapiCall(b, false),
    };
    // self-test once: if DPAPI doesn't round-trip, don't offer it
    let dpapiOk = false;
    try { dpapiOk = dpapi.unprotect(dpapi.protect(Buffer.from('cv-selftest'))).toString() === 'cv-selftest'; } catch { dpapiOk = false; }

    const processOf = (hwnd: WindowRef): string | null => {
      if (!hwnd) return null;
      const pid = [0];
      GetWindowThreadProcessId(hwnd, pid);
      if (!pid[0]) return null;
      const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid[0]);
      if (!h) return null;
      try {
        const buf = Buffer.alloc(1040);
        const size = [520];
        if (!QueryFullProcessImageNameW(h, 0, buf, size)) return null;
        return buf.toString('utf16le', 0, (size[0] ?? 0) * 2);
      } finally {
        CloseHandle(h);
      }
    };

    const keyInput = (vk: number, up: boolean): Buffer => {
      const b = Buffer.alloc(40); // sizeof(INPUT) on x64
      b.writeUInt32LE(INPUT_KEYBOARD, 0);
      b.writeUInt16LE(vk, 8);        // wVk
      b.writeUInt16LE(0, 10);        // wScan
      b.writeUInt32LE(up ? KEYEVENTF_KEYUP : 0, 12);
      return b;
    };

    const platform: Platform = {
      name: 'win32',
      clipboardSequence: () => GetClipboardSequenceNumber() >>> 0,
      clipboardFlags: (): ClipboardFlags => {
        const f: ClipboardFlags = {};
        if (IsClipboardFormatAvailable(fmt.exclude)) f.excludeFromMonitor = true;
        if (IsClipboardFormatAvailable(fmt.viewerIgnore)) f.viewerIgnore = true;
        if (IsClipboardFormatAvailable(fmt.canInclude)) {
          const v = withClipboard(0, () => {
            const h = GetClipboardData(fmt.canInclude);
            if (!h || GlobalSize(h) < 4) return 1;
            const p = GlobalLock(h);
            if (!p) return 1;
            const b = Buffer.alloc(4);
            CopyToBuffer(b, p, 4);
            GlobalUnlock(h);
            return b.readUInt32LE(0);
          });
          f.canIncludeInHistory = v ?? 0; // couldn't read it -> treat as "not allowed" (safe side)
        }
        try { f.ownerProcess = processOf(GetClipboardOwner()); } catch { /* ignore */ }
        return f;
      },
      readFileList: () => {
        if (!IsClipboardFormatAvailable(CF_HDROP)) return [];
        return withClipboard(0, () => {
          const h = GetClipboardData(CF_HDROP);
          if (!h) return [];
          const n = DragQueryFileW(h, 0xffffffff, null, 0);
          const out: string[] = [];
          for (let i = 0; i < n && i < 1000; i++) {
            const len = DragQueryFileW(h, i, null, 0);
            const buf = Buffer.alloc((len + 1) * 2);
            DragQueryFileW(h, i, buf, len + 1);
            out.push(buf.toString('utf16le', 0, len * 2));
          }
          return out;
        }) ?? [];
      },
      writeFileList: (paths, owner) => {
        if (!paths.length) return false;
        const list = Buffer.from(paths.join('\0') + '\0\0', 'utf16le');
        const head = Buffer.alloc(20);
        head.writeUInt32LE(20, 0); // pFiles
        head.writeInt32LE(1, 16);  // fWide
        const drop = toGlobal(Buffer.concat([head, list]));
        const effect = Buffer.alloc(4);
        effect.writeUInt32LE(1, 0); // DROPEFFECT_COPY
        const eff = toGlobal(effect);
        const text = toGlobal(Buffer.from(paths.join('\r\n') + '\0', 'utf16le'));
        const ok = withClipboard(owner ?? 0, () => {
          EmptyClipboard();
          const a = SetClipboardData(CF_HDROP, drop);
          if (eff) SetClipboardData(fmt.dropEffect, eff);
          if (text) SetClipboardData(CF_UNICODETEXT, text);
          return !!a;
        });
        if (!ok) { for (const h of [drop, eff, text]) if (h) GlobalFree(h); }
        return !!ok;
      },
      foregroundWindow: () => {
        const h = GetForegroundWindow();
        return h ? h : null;
      },
      restoreForeground: (w) => {
        if (!w || !IsWindow(w)) return false;
        if (SetForegroundWindow(w)) return true;
        // focus-stealing rules: temporarily attach to the target thread's input queue
        const pid = [0];
        const target = GetWindowThreadProcessId(w, pid);
        const me = GetCurrentThreadId();
        AttachThreadInput(me, target, 1);
        const ok = !!SetForegroundWindow(w);
        AttachThreadInput(me, target, 0);
        return ok;
      },
      sendPaste: () => {
        // release modifiers the user may still hold (Shift/Alt from the hotkey), then Ctrl+V
        const pre: Buffer[] = [];
        for (const vk of [VK_SHIFT, VK_MENU]) if (GetAsyncKeyState(vk) & 0x8000) pre.push(keyInput(vk, true));
        const seq = Buffer.concat([...pre, keyInput(VK_CONTROL, false), keyInput(VK_V, false), keyInput(VK_V, true), keyInput(VK_CONTROL, true)]);
        const n = seq.length / 40;
        return SendInput(n, seq, 40) === n;
      },
      dpapi: dpapiOk ? dpapi : null,
    };
    if (!dpapiOk) log('[clipvault] DPAPI self-test failed – encryption at rest unavailable');
    return platform;
  } catch (e) {
    log('[clipvault] win32 bindings failed – generic clipboard mode', (e as Error).message);
    return null;
  }
}
