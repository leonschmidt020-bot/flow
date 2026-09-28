// Electron glue for the notetaker: IPC for the hub, Ctrl+Alt+M, pill port, tray entries, capture backend, decoder.
// index.ts only calls initMeeting() and forwards a few events – keeps the merge with the dictation code small.
import { BrowserWindow, dialog, globalShortcut, ipcMain, shell, type MenuItemConstructorOptions } from 'electron';
import path from 'node:path';
import type { Engine } from '../asr/engine';
import { findClaude } from './claude';
import { MeetingController, type PillPort } from './controller';
import { nameHint, regProbe } from './detect';
import { AUDIO_EXTS } from './decode';
import { ElectronCapture } from './electronCapture';
import { clock } from './format';
import { mt, type MLoc } from './i18n';
import type { MeetingSettings } from './settings';

export interface MeetingInit {
  userData: string;
  modelsRoot: string;
  preloadPath: string;
  capturePage: string;
  noHotkey: boolean;
  locale: () => MLoc;
  micDeviceId: () => string;
  clean: (text: string) => string;
  asr: () => Engine | null;
  waitAsr: () => Promise<Engine>;
  copyText: (text: string) => Promise<void> | void;
  pill: PillPort;
  openHub: (page?: string) => void;
  hubs: () => BrowserWindow[];
  log: (...a: unknown[]) => void;
  onTrayChange: () => void;
}

export interface MeetingHandle {
  controller: MeetingController;
  trayItems(): MenuItemConstructorOptions[];
  /** pill clicks that belong to the notetaker; returns true when handled */
  pillClick(what: string): boolean;
  importFiles(files: string[]): void;
  dispose(): Promise<void>;
}

export function initMeeting(o: MeetingInit): MeetingHandle {
  const capture = new ElectronCapture({ preload: o.preloadPath, page: o.capturePage }, o.log);
  const c = new MeetingController({
    root: path.join(o.userData, 'meetings'), modelsRoot: o.modelsRoot, platform: process.platform, locale: o.locale, micDeviceId: o.micDeviceId,
    clean: o.clean, asr: o.asr, waitAsr: o.waitAsr, capture: () => capture, chromiumDecode: (f) => capture.decode(f), copyText: o.copyText,
    pill: o.pill, log: o.log, claudeBin: () => findClaude(),
    // Windows: microphone consent store via koffi every 3 s (reg.exe as fallback); window titles only for naming
    callProbe: process.platform === 'win32' ? (require('./micRegistry') as typeof import('./micRegistry')).windowsProbe(regProbe) : undefined,
    ownExe: process.execPath,
    callName: process.platform === 'win32' ? (call) => nameHint(call, (require('./micRegistry') as typeof import('./micRegistry')).windowTitles(call.exe)) : undefined,
  });
  c.init();

  // hub state: throttled push
  let timer: NodeJS.Timeout | null = null;
  c.on('change', () => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      const st = c.hubState();
      for (const w of o.hubs()) if (!w.isDestroyed()) w.webContents.send('meeting:state', st);
      o.onTrayChange();
    }, 200);
  });

  // Ctrl+Alt+M
  const ACC = 'Control+Alt+M';
  let registered = false;
  const applyHotkey = () => {
    if (o.noHotkey) return;
    const want = c.settings.hotkey;
    if (want && !registered) { try { registered = globalShortcut.register(ACC, () => void c.toggle()); } catch { registered = false; } if (!registered) o.log('meeting hotkey unavailable'); }
    else if (!want && registered) { globalShortcut.unregister(ACC); registered = false; }
  };
  applyHotkey();

  const importFiles = (files: string[]) => {
    for (const f of files) {
      const r = c.importFile(f);
      if (r.ok) o.openHub('notetaker');
    }
  };

  ipcMain.handle('meeting:state', () => c.hubState());
  ipcMain.handle('meeting:get', (_e, id: string) => c.get(String(id)) ?? null);
  ipcMain.handle('meeting:start', () => c.start(null));
  ipcMain.handle('meeting:stop', () => c.stop());
  ipcMain.handle('meeting:import', (_e, files: string[]) => importFiles((Array.isArray(files) ? files : []).map(String)));
  ipcMain.handle('meeting:pickFile', async (e) => {
    const win = BrowserWindow.fromWebContents(e.sender) ?? undefined;
    const r = await (win ? dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'], filters: [{ name: 'Audio/Video', extensions: AUDIO_EXTS }] })
      : dialog.showOpenDialog({ properties: ['openFile', 'multiSelections'], filters: [{ name: 'Audio/Video', extensions: AUDIO_EXTS }] }));
    if (!r.canceled) importFiles(r.filePaths);
  });
  ipcMain.handle('meeting:rename', (_e, id: string, title: string) => c.rename(String(id), String(title)));
  ipcMain.handle('meeting:renameSpeaker', (_e, id: string, key: string, name: string) => c.renameSpeaker(String(id), String(key), String(name)));
  ipcMain.handle('meeting:keep', (_e, id: string, keep: boolean) => c.setKeep(String(id), !!keep));
  ipcMain.handle('meeting:delete', (_e, id: string) => c.delete(String(id)));
  ipcMain.handle('meeting:reprocess', (_e, id: string) => c.reprocess(String(id)));
  ipcMain.handle('meeting:summarize', (_e, id: string) => c.summarize(String(id)));
  ipcMain.handle('meeting:copyPrompt', (_e, id: string) => c.copyPrompt(String(id)).then((r) => ({ ok: r.ok })));
  ipcMain.handle('meeting:copyTranscript', (_e, id: string) => c.copyTranscript(String(id)));
  ipcMain.handle('meeting:openFolder', (_e, id: string) => { if (c.get(String(id))) return shell.openPath(c.store.folder(String(id))); return undefined; });
  ipcMain.handle('meeting:setSettings', (_e, p: Partial<MeetingSettings>) => { const s = c.setSettings(p ?? {}); applyHotkey(); return s; });

  return {
    controller: c,
    trayItems() {
      const L = o.locale();
      const at = c.recordingStartedAt;
      return [
        at ? { label: mt(L, 'trayStop', { t: clock((Date.now() - at) / 1000) }), click: () => void c.stop() } : { label: mt(L, 'trayStart'), click: () => void c.start(null) },
        { label: mt(L, 'trayNotetaker'), click: () => o.openHub('notetaker') },
      ];
    },
    pillClick(what) {
      if (what === 'meetingStop') { void c.stop(); return true; }
      if (what === 'meetingOpen') { o.openHub('notetaker' + (c.store.meetings.find((m) => m.status === 'recording') ? ':' + c.store.meetings.find((m) => m.status === 'recording')!.id : '')); return true; }
      if (what === 'cardYes' || what === 'cardNo') { c.cardAnswer(what === 'cardYes'); return true; }
      return false;
    },
    importFiles,
    async dispose() {
      if (c.isRecording) await c.stop().catch(() => undefined);
      c.dispose();
      capture.destroy();
    },
  };
}

/** smoke-test helper (npm run smoke:meeting): import a file, wait, check the transcript, render the notetaker page */
export async function meetingSelfTest(m: MeetingHandle, file: string, hub: BrowserWindow, outDir: string): Promise<{ ok: boolean; error?: string }> {
  const c = m.controller;
  const t0 = Date.now();
  if (!c.importFile(path.resolve(file)).ok) return { ok: false, error: 'import refused' };
  await c.idle();
  const meeting = c.store.meetings[0];
  if (!meeting || meeting.status !== 'done') return { ok: false, error: `status ${meeting?.status}: ${meeting?.progressNote}` };
  const speakers = new Set(meeting.segments.map((s) => s.speaker)).size;
  const pr = await c.copyPrompt(meeting.id);
  console.log(`MEETING ${meeting.segments.length} segments, ${speakers} speakers, ${Date.now() - t0} ms, prompt ${pr.ok ? 'ok' : 'failed'}`);
  for (const s of meeting.segments) console.log(`  [${s.start.toFixed(1)}] ${s.speaker}: ${s.text}`);
  hub.webContents.send('hub:navigate', 'notetaker:' + meeting.id);
  await new Promise((r) => setTimeout(r, 1500));
  const rows = await hub.webContents.executeJavaScript('document.querySelectorAll(".nt-seg").length');
  const { writeFileSync, mkdirSync } = await import('node:fs');
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, 'smoke_notetaker.png'), (await hub.webContents.capturePage()).toPNG());
  if (speakers < 2) return { ok: false, error: `only ${speakers} speaker(s)` };
  if (!pr.ok) return { ok: false, error: 'prompt' };
  if (!rows) return { ok: false, error: 'notetaker page shows no transcript' };
  console.log('MEETING OK', rows, 'rows on the notetaker page');
  return { ok: true };
}
