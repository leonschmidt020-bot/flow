// Sicheres Beenden. Unter Windows blieb electron.exe nach app.exit() hängen (CI 27.09.2026: „SMOKE OK“, danach eine
// Stunde bis zum Abbruch) – vermutlich Threads der nativen Spracherkennung beim Entladen der DLLs. Hängt das schon IN
// app.exit(), hilft kein JS-Timer mehr. Deshalb unter Windows gar nicht erst app.exit(): nach kurzer Pause (Ausgaben
// und Dateien sind vorher geschrieben) direkt TerminateProcess(GetCurrentProcess(), code) – überspringt das Entladen.
// So bleiben bei Nutzern keine unsichtbaren Flow-Prozesse zurück (und der Updater kann beim Beenden installieren).
/* eslint-disable @typescript-eslint/no-explicit-any */
import { app } from 'electron';

export function hardExit(code: number, delayMs = 250): void {
  if (process.platform !== 'win32') { app.exit(code); return; }
  setTimeout(() => terminateSelf(code), delayMs);
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
