// Sicheres Beenden. Unter Windows blieb electron.exe nach app.exit() hängen (CI 27.09.2026: „SMOKE OK“, danach eine
// Stunde bis zum Abbruch) – vermutlich Threads der nativen Spracherkennung beim Entladen der DLLs. Hängt das schon IN
// app.exit(), hilft kein JS-Timer mehr. Deshalb unter Windows gar nicht erst app.exit(): nach kurzer Pause (Ausgaben
// und Dateien sind vorher geschrieben) direkt TerminateProcess(GetCurrentProcess(), code) – überspringt das Entladen.
// So bleiben bei Nutzern keine unsichtbaren Flow-Prozesse zurück (und der Updater kann beim Beenden installieren).
/* eslint-disable @typescript-eslint/no-explicit-any */
import { app } from 'electron';

export function hardExit(code: number, delayMs = 250): void {
  if (process.platform !== 'win32') {
    // macOS/Linux: app.exit() can hang too (the self-test on macOS stayed alive after „SMOKE OK“ and later produced an
    // error dialog). A detached watchdog kills this process after 2 s if it is still there – it never outlives us by more.
    watchdog(2);
    app.exit(code);
    return;
  }
  setTimeout(() => terminateSelf(code), delayMs);
}

/** `sh -c 'sleep N; kill -9 <pid>'`, detached + unref'd; harmless if we are already gone (kill fails silently) */
export function watchdog(seconds: number, pid = process.pid): void {
  try {
    const { spawn } = require('node:child_process') as typeof import('node:child_process');
    const p = spawn('/bin/sh', ['-c', `sleep ${Math.max(1, Math.round(seconds))}; kill -9 ${Math.floor(pid)} 2>/dev/null`], { detached: true, stdio: 'ignore' });
    p.unref();
  } catch { /* no sh – nothing we can do */ }
}

function terminateSelf(code: number): void {
  try {
    const koffi: any = require('koffi');
    const k32 = koffi.load('kernel32.dll');
    const GetCurrentProcess = k32.func('void * __stdcall GetCurrentProcess()');
    const TerminateProcess = k32.func('int __stdcall TerminateProcess(void *hProcess, uint32_t uExitCode)');
    TerminateProcess(GetCurrentProcess(), code >>> 0);
  } catch {
    app.exit(code);
  }
}
