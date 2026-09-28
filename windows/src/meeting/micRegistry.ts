// Windows-only: reads the microphone consent store with advapi32 via koffi (RegOpenKeyExW / RegEnumKeyExW /
// RegQueryValueExW) – no child process per 3-s poll. Also a best-effort window-title lookup (user32 EnumWindows)
// used only to name a detected call. Loaded lazily; never imported on other platforms.
/* eslint-disable @typescript-eslint/no-explicit-any */
import { micUser, type MicUser, type Probe } from './detect';

const HKCU = -2147483647; // (HKEY)(LONG)0x80000001, sign-extended
const KEY_READ = 0x20019;
const SUBKEY = 'Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone';

/** prototype strings – parsed by a unit test on any OS */
export const ENUM_PROC = 'int __stdcall FlowEnumWindowsProc(void *hwnd, intptr_t lParam)';
export const PROTOS = {
  RegOpenKeyExW: 'long __stdcall RegOpenKeyExW(intptr_t hKey, str16 subKey, uint32_t options, uint32_t sam, _Out_ intptr_t *result)',
  RegEnumKeyExW: 'long __stdcall RegEnumKeyExW(intptr_t hKey, uint32_t index, void *name, _Inout_ uint32_t *cchName, void *reserved, void *cls, void *cchCls, void *ft)',
  RegQueryValueExW: 'long __stdcall RegQueryValueExW(intptr_t hKey, str16 name, void *reserved, _Out_ uint32_t *type, _Out_ uint64_t *data, _Inout_ uint32_t *cbData)',
  RegCloseKey: 'long __stdcall RegCloseKey(intptr_t hKey)',
  EnumWindows: 'int __stdcall EnumWindows(FlowEnumWindowsProc *cb, intptr_t lParam)',
  IsWindowVisible: 'int __stdcall IsWindowVisible(void *hwnd)',
  GetWindowTextW: 'int __stdcall GetWindowTextW(void *hwnd, void *buf, int max)',
  GetWindowThreadProcessId: 'uint32_t __stdcall GetWindowThreadProcessId(void *hwnd, _Out_ uint32_t *pid)',
  OpenProcess: 'void * __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)',
  CloseHandle: 'int __stdcall CloseHandle(void *h)',
  QueryFullProcessImageNameW: 'int __stdcall QueryFullProcessImageNameW(void *h, uint32_t flags, void *buf, _Inout_ uint32_t *size)',
} as const;

let api: any = null;
function load() {
  if (api) return api;
  const koffi = require('koffi');
  const adv = koffi.load('advapi32.dll');
  const user32 = koffi.load('user32.dll');
  const kernel32 = koffi.load('kernel32.dll');
  const EnumProc = koffi.proto(ENUM_PROC);
  api = {
    koffi, EnumProc,
    open: adv.func(PROTOS.RegOpenKeyExW),
    enumKey: adv.func(PROTOS.RegEnumKeyExW),
    query: adv.func(PROTOS.RegQueryValueExW),
    close: adv.func(PROTOS.RegCloseKey),
    EnumWindows: user32.func(PROTOS.EnumWindows),
    IsWindowVisible: user32.func(PROTOS.IsWindowVisible),
    GetWindowTextW: user32.func(PROTOS.GetWindowTextW),
    GetWindowThreadProcessId: user32.func(PROTOS.GetWindowThreadProcessId),
    OpenProcess: kernel32.func(PROTOS.OpenProcess),
    CloseHandle: kernel32.func(PROTOS.CloseHandle),
    QueryFullProcessImageNameW: kernel32.func(PROTOS.QueryFullProcessImageNameW),
  };
  return api;
}

function subkeys(a: any, h: number): string[] {
  const out: string[] = [];
  const buf = Buffer.alloc(1024);
  for (let i = 0; i < 4096; i++) {
    const len = [512];
    const rc = a.enumKey(h, i, buf, len, null, null, null, null);
    if (rc !== 0) break; // ERROR_NO_MORE_ITEMS (259) or anything else
    out.push(buf.toString('utf16le', 0, len[0]! * 2));
  }
  return out;
}

function qword(a: any, h: number, name: string): bigint {
  const type = [0], data = [0n], cb = [8];
  const rc = a.query(h, name, null, type, data, cb);
  if (rc !== 0 || type[0] !== 11 /* REG_QWORD */) return 0n;
  return BigInt(data[0]!);
}

function readEntry(a: any, parent: number, name: string, keyPath: string, out: MicUser[]) {
  const hk: [number] = [0];
  if (a.open(parent, name, 0, KEY_READ, hk) !== 0) return;
  try {
    const start = qword(a, hk[0], 'LastUsedTimeStart'), stop = qword(a, hk[0], 'LastUsedTimeStop');
    if (start > 0n || stop > 0n) out.push(micUser(keyPath, start, stop));
  } finally { a.close(hk[0]); }
}

export const koffiProbe: Probe = async () => {
  const a = load();
  const root: [number] = [0];
  if (a.open(HKCU, SUBKEY, 0, KEY_READ, root) !== 0) return [];
  const out: MicUser[] = [];
  try {
    for (const name of subkeys(a, root[0])) {
      if (name === 'NonPackaged') {
        const np: [number] = [0];
        if (a.open(root[0], name, 0, KEY_READ, np) !== 0) continue;
        try { for (const exe of subkeys(a, np[0])) readEntry(a, np[0], exe, `${SUBKEY}\\NonPackaged\\${exe}`, out); } finally { a.close(np[0]); }
      } else readEntry(a, root[0], name, `${SUBKEY}\\${name}`, out);
    }
  } finally { a.close(root[0]); }
  return out;
};

/** visible top-level window titles of processes whose exe name matches `exe` (lower-case), best effort */
export function windowTitles(exe: string): string[] {
  try {
    const a = load();
    const titles: string[] = [];
    const buf = Buffer.alloc(1024);
    const img = Buffer.alloc(1040);
    const cb = a.koffi.register((hwnd: any) => {
      if (!a.IsWindowVisible(hwnd)) return 1;
      const n = a.GetWindowTextW(hwnd, buf, 512);
      if (n <= 0) return 1;
      const pid = [0];
      a.GetWindowThreadProcessId(hwnd, pid);
      const hp = a.OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, 0, pid[0]);
      if (!hp) return 1;
      try {
        const size = [520];
        if (a.QueryFullProcessImageNameW(hp, 0, img, size)) {
          const p = img.toString('utf16le', 0, size[0]! * 2);
          if ((p.split('\\').pop() ?? '').toLowerCase() === exe) titles.push(buf.toString('utf16le', 0, n * 2));
        }
      } finally { a.CloseHandle(hp); }
      return 1;
    }, a.koffi.pointer(a.EnumProc));
    try { a.EnumWindows(cb, 0); } finally { a.koffi.unregister(cb); }
    return titles;
  } catch {
    return [];
  }
}

/** koffi probe, falling back to reg.exe if advapi32 cannot be bound */
export function windowsProbe(fallback: Probe): Probe {
  let broken = false;
  return async () => {
    if (!broken) { try { return await koffiProbe(); } catch { broken = true; } }
    return fallback();
  };
}
