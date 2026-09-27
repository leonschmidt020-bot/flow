// Struct layout + prototype syntax of the SendInput bindings, checked on any OS (koffi parses without user32).
import { describe, expect, it } from 'vitest';
import { createRequire } from 'node:module';
import { defineTypes, PROTOS } from '../../src/main/insert/win32';

const require = createRequire(import.meta.url);
const koffi = require('koffi');

describe('win32 SendInput bindings', () => {
  const T = defineTypes(koffi);
  it('INPUT has the Windows x64 size (40 bytes) and KEYBDINPUT 24', () => {
    if (process.arch !== 'x64' && process.arch !== 'arm64') return;
    expect(koffi.sizeof(T.INPUT)).toBe(40);
    expect(koffi.sizeof(T.KEYBDINPUT)).toBe(24);
    expect(koffi.sizeof(T.MOUSEINPUT)).toBe(32);
  });
  it('all prototypes parse', () => {
    for (const [name, p] of Object.entries(PROTOS)) expect(() => koffi.proto(p), name).not.toThrow();
  });
});

describe('SendInput marshaling (JS array → contiguous INPUT[])', () => {
  const libName = process.platform === 'win32' ? 'msvcrt.dll' : process.platform === 'darwin' ? 'libc.dylib' : 'libc.so.6';
  it('4 key events land at 40-byte strides with VK, flags and our marker', () => {
    if (process.arch !== 'x64' && process.arch !== 'arm64') return;
    const libc = koffi.load(libName);
    const memcpy = libc.func('void *memcpy(void *dst, FLOW_INPUT *src, size_t n)');
    const ev = (vk: number, up: boolean) => ({ type: 1, u: { ki: { wVk: vk, wScan: 0, dwFlags: up ? 2 : 0, time: 0, dwExtraInfo: 0x464c4f57 } } });
    const dst = Buffer.alloc(160);
    memcpy(dst, [ev(0xa2, false), ev(0x56, false), ev(0x56, true), ev(0xa2, true)], 160);
    const rows = [0, 1, 2, 3].map((i) => [dst.readUInt32LE(i * 40), dst.readUInt16LE(i * 40 + 8), dst.readUInt32LE(i * 40 + 12), Number(dst.readBigUInt64LE(i * 40 + 24))]);
    expect(rows).toEqual([[1, 0xa2, 0, 0x464c4f57], [1, 0x56, 0, 0x464c4f57], [1, 0x56, 2, 0x464c4f57], [1, 0xa2, 2, 0x464c4f57]]);
  });
});

describe('uiohook key codes', () => {
  it('match the constants used by the hotkey state machine', async () => {
    const { UiohookKey } = require('uiohook-napi');
    const { K } = await import('../../src/main/hotkey/keycodes');
    for (const [name, code] of Object.entries(K)) expect(UiohookKey[name], name).toBe(code);
  });
});
