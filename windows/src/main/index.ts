// Flow – main process entry.
//   flags: --no-hotkey (never install the global keyboard hook / shortcuts), --hidden (autostart),
//          --dev (open hub), --render-check=<dir> (offscreen PNGs, then quit), --smoke=<wav> (end-to-end self test, then quit)
import { hardExit } from './hardExit';
import { app, BrowserWindow, clipboard, ipcMain, screen, session, shell, systemPreferences, globalShortcut } from 'electron';
import path from 'node:path';
import os from 'node:os';
import { existsSync, mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { paths } from './paths';
import { initLog, log, logText } from './log';
import { APP_ID, RELEASE, VERSION } from './config';
import { JsonFile } from './store';
import { DEFAULTS, migrateSettings, patchSettings, type Settings } from '../shared/settings';
import { t } from '../shared/i18n';
import type { HubState } from '../shared/hubState';
import { History } from './history';
import { AsrService } from './asrService';
import { Mic } from './mic';
import { Pill, createHub } from './windows';
import { FlowTray } from './tray';
import { HotkeyService } from './hotkeyService';
import { Dictation } from './dictation';
import { electronClipboard, memoryClipboard } from './clipboardPort';
import type { KeySender, InsertPhase } from './insert/inserter';
import { initUpdater, checkForUpdates, scheduleUpdates } from './updater';
import { initClipVault } from '../clipvault/main';
import type { ClipVaultHandle, FlowClipboardWrite } from '../clipvault/contract';
import { runRenderCheck } from './renderCheck';
import { initMeeting, type MeetingHandle } from '../meeting/main';
import { applyRules } from '../core/textCleaner';
import type { DisplayMap } from '../core/mouseTarget';
import { LearnQueue, rememberEntry, type Suggestion } from '../core/learner';
import { MouseTarget } from './mouse/mouseTarget';
import { HighlightWindow } from './mouse/highlightWindow';
import type { NativeWindows } from './mouse/native';
import { CorrectionLearner } from './learn/correctionLearner';
import { UiaClient, powershellSpawner } from './uia/uiaClient';
import { noUia, type UiaPort } from './uia/types';

const argv = process.argv.slice(1);
const flag = (n: string) => argv.includes(`--${n}`) || argv.some((a) => a.startsWith(`--${n}=`));
const flagValue = (n: string) => argv.find((a) => a.startsWith(`--${n}=`))?.split('=').slice(1).join('=');
const NO_HOTKEY = flag('no-hotkey') || flag('render-check') || flag('smoke');
const IS_WIN = process.platform === 'win32';

if (process.env.FLOW_USER_DATA) app.setPath('userData', process.env.FLOW_USER_DATA);
else if (flag('render-check') || flag('smoke')) {
  // throw-away profile for self tests (inside the repo's .cache when run from windows/)
  const base = existsSync(path.join(process.cwd(), 'package.json')) ? path.join(process.cwd(), '.cache') : os.tmpdir();
  mkdirSync(base, { recursive: true });
  app.setPath('userData', mkdtempSync(path.join(base, 'userdata-')));
}
app.setAppUserModelId(APP_ID);

if (flag('render-check')) {
  app.whenReady().then(() => runRenderCheck(flagValue('render-check') || path.join(process.cwd(), '.cache', 'render'))).catch((e) => { console.error(e); app.exit(1); });
} else if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  void app.whenReady().then(main).catch((e) => { log('fatal', e); console.error(e); app.exit(1); });
}

async function main() {
  if (process.platform === 'darwin' && flag('smoke')) app.dock?.hide();
  initLog(paths.logs);
  log(`Flow ${VERSION} starting (${process.platform}-${process.arch}, electron ${process.versions.electron})${NO_HOTKEY ? ' [no-hotkey]' : ''}`);

  // ── settings ──
  const settingsFile = new JsonFile<Settings>(paths.settings);
  const loaded = settingsFile.load(() => DEFAULTS);
  let settings = migrateSettings(loaded.value);
  if (loaded.source !== 'file') log(`settings loaded from ${loaded.source}`);
  settingsFile.save(settings);
  const getSettings = () => settings;

  // mic permission only for our own pages
  const ours = (url: string) => url.startsWith('file://');
  session.defaultSession.setPermissionRequestHandler((wc, perm, cb) => cb((perm === 'media' || perm === 'display-capture') && ours(wc.getURL())));
  session.defaultSession.setPermissionCheckHandler((wc, perm) => perm === 'media' && !!wc && ours(wc.getURL()));

  // ── services ──
  const history = new History(paths.history, () => settings.historyRetentionDays);
  const asr = new AsrService(paths.models, settings.engine);
  const mic = new Mic();
  mic.init();
  const pill = new Pill();
  pill.visible = !flag('smoke');
  pill.create();
  pill.state({ mode: 'idle', alwaysVisible: settings.pillAlwaysVisible });

  let micError = '';
  if (IS_WIN) {
    try { if (systemPreferences.getMediaAccessStatus('microphone') === 'denied') micError = 'denied'; } catch { /* */ }
  }

  // ClipVault gets told about our own clipboard writes
  let writing = false;
  const cvListeners = new Set<(w: FlowClipboardWrite) => void>();
  const onClipboardWrite = (phase: InsertPhase, text: string) => { for (const l of cvListeners) { try { l({ phase, text }); } catch { /* */ } } };

  let keys: KeySender;
  let foregroundExe = () => '';
  let startMenuMask = () => {};
  if (IS_WIN) {

    const w32 = require('./insert/win32') as typeof import('./insert/win32');
    keys = new w32.Win32KeySender();
    foregroundExe = w32.foregroundExe;
    startMenuMask = w32.sendStartMenuMask;
  } else {
    keys = { paste: () => log('paste (no-op on this platform)') };
  }
  // Flow only writes the real clipboard on Windows; dev runs elsewhere use an in-memory clipboard.
  const clip = IS_WIN && !flag('smoke') ? electronClipboard : memoryClipboard();

  // ── hub ──
  let hub: BrowserWindow | null = null;
  let paused = false;
  const openHub = (page?: string) => {
    if (!hub || hub.isDestroyed()) {
      hub = createHub({ show: !flag('smoke'), offscreen: flag('smoke') });
      hub.on('closed', () => { hub = null; void mic.monitor(false, ''); });
      if (page) hub.webContents.once('did-finish-load', () => hub?.webContents.send('hub:navigate', page));
    } else {
      if (hub.isMinimized()) hub.restore();
      hub.show(); hub.focus();
      if (page) hub.webContents.send('hub:navigate', page);
    }
  };
  const buildState = (): HubState => ({
    settings,
    history: history.records.slice(0, 400).map((r) => ({ id: r.id, date: r.date, text: r.text, app: r.app, words: r.words, durationSec: r.durationSec })),
    totalDictations: history.records.length,
    wordsToday: history.wordsToday(),
    wordsTotal: history.records.reduce((n, r) => n + r.words, 0),
    asr: asr.state,
    micError,
    version: VERSION,
    platform: process.platform,
    paused,
    hotkeysDisabled: NO_HOTKEY,
  });
  let pushTimer: NodeJS.Timeout | null = null;
  const pushState = () => {
    if (pushTimer) return;
    pushTimer = setTimeout(() => { pushTimer = null; if (hub && !hub.isDestroyed()) hub.webContents.send('hub:state', buildState()); }, 60);
  };

  // ── „Text dorthin, wo die Maus ist“ + word learner (Windows only; UI Automation via a PowerShell helper) ──
  let hotkeys: HotkeyService | null = null;
  let native: NativeWindows | null = null;
  let uiaClient: UiaClient | null = null;
  let uia: UiaPort = noUia;
  let highlight: HighlightWindow | null = null;
  let mouse: MouseTarget | null = null;
  let learner: CorrectionLearner | null = null;
  const learnQueue = new LearnQueue();
  let onLearnCandidate: (s: Suggestion[]) => void = () => {};
  const displays = (): DisplayMap[] => screen.getAllDisplays().map((d) => ({
    dip: d.bounds, scale: d.scaleFactor,
    phys: IS_WIN ? screen.dipToScreenRect(null, d.bounds) : { x: d.bounds.x * d.scaleFactor, y: d.bounds.y * d.scaleFactor, width: d.bounds.width * d.scaleFactor, height: d.bounds.height * d.scaleFactor },
  }));
  if (IS_WIN && !flag('smoke')) {
    try {
      const { createWin32Native } = require('./mouse/win32Windows') as typeof import('./mouse/win32Windows');
      native = createWin32Native();
    } catch (e) { log('mouse-target: native layer unavailable', e); }
    uiaClient = new UiaClient({ spawn: powershellSpawner(paths.helper('flow-uia.ps1')), log });
    uia = uiaClient;
  }
  if (native) {
    const nw = native;
    highlight = new HighlightWindow();
    mouse = new MouseTarget({
      native: nw, uia, highlight, settings: () => settings, ownPid: process.pid, displays, log,
      text: (k) => t(settings.locale, k === 'label' ? 'mtLabel' : k === 'toastNormal' ? 'mtToastNormal' : 'mtToastFocusFailed'),
      markInjecting: (ms) => hotkeys?.injecting(ms),
      hotkeyHeld: () => hotkeys?.comboHeld() ?? false,
    });
    learner = new CorrectionLearner({
      uia, log,
      foreground: () => { try { const w = nw.foreground(); return w ? { pid: w.pid, exe: w.exe } : null; } catch { return null; } },
      onCandidate: (s) => onLearnCandidate(s),
      isRejected: (o, n) => learnQueue.rejected.has(`${o}\u0001${n}`),
    });
  }

  // ── hotkey + dictation ──
  const dictation = new Dictation({
    mic, asr, pill, history, settings: getSettings, clipboard: clip, keys, foregroundExe,
    waitKeysReleased: () => hotkeys?.waitReleased() ?? Promise.resolve(),
    markInjecting: (ms) => hotkeys?.injecting(ms),
    onClipboardWrite,
    setWriting: (v) => { writing = v; },
    mouse, learner,
    foregroundProcess: () => { try { const w = native?.foreground(); return w ? { pid: w.pid, exe: w.exe } : null; } catch { return null; } },
  });
  dictation.on('state', (s) => { if (s === 'idle') { hotkeys?.machine.forceIdle(); pushState(); } });
  mic.on('level', (lv: number) => { pill.level(lv); if (hub && !hub.isDestroyed()) hub.webContents.send('hub:level', lv); });
  mic.on('error', (e: { name: string }) => {
    micError = e.name || 'error';
    pill.toast(t(settings.locale, 'toastMicError'), 'error');
    dictation.cancel();
    pushState();
  });
  mic.on('started', () => { if (micError) { micError = ''; pushState(); } });
  let meeting: MeetingHandle | null = null;
  pill.onClick = (what) => {
    if (meeting?.pillClick(what)) return; // notetaker: meeting stop/open, meeting card buttons
    if (what === 'stop') void dictation.stop(false); else if (what === 'cancel') { dictation.cancel(); hotkeys?.machine.forceIdle(); }
  };
  pill.onDrop = (files) => meeting?.importFiles(files);

  if (!NO_HOTKEY) {
    hotkeys = new HotkeyService(settings.hotkey, {
      onStart: () => {
        if (paused) return;
        // the UI Automation helper needs ~1 s to start – start it with the first key press, not at release
        if (settings.mouseTarget || settings.learnFromEdits) uiaClient?.warm();
        void dictation.start();
      },
      onStop: () => void dictation.stop(),
      onCancel: () => dictation.cancel(),
      onHandsFree: () => dictation.handsFree(),
    }, settings.doubleTapHandsFree);
    hotkeys.onComboDown = () => { if (IS_WIN && hotkeys?.usesWin) { hotkeys.injecting(60); startMenuMask(); } };
    if (!hotkeys.start()) log('global hotkey unavailable');
  }

  // ── ASR ──
  asr.on('change', pushState);
  asr.on('change', (st) => {
    if (st.status === 'downloading') pill.state({ mode: 'loading', progress: st.progress, label: `${settings.locale === 'de' ? 'Sprachmodell' : 'Speech model'} · ${Math.round(st.progress * 100)} %` });
    else if (st.status === 'verifying' || st.status === 'extracting') pill.state({ mode: 'loading', progress: 1, label: t(settings.locale, st.status === 'verifying' ? 'modelVerifying' : 'modelExtracting') });
    else if (dictation.state === 'idle') pill.state({ mode: 'idle' });
  });
  asr.on('ready', () => {
    if (!settings.onboardingDone) { settings = patchSettings(settings, { onboardingDone: true }); settingsFile.save(settings); pill.toast(t(settings.locale, 'toastDownloadDone'), 'success'); }
  });
  const firstRun = !settings.onboardingDone;
  void asr.start(settings.engine, firstRun || asr.state.installed[settings.engine]);
  mic.warm();

  // ── ClipVault ──
  let cv: ClipVaultHandle | null = null;
  try {
    cv = await initClipVault({
      app, userDataDir: paths.userData, locale: settings.locale, isDev: !app.isPackaged,
      assetsDir: path.join(paths.dist, 'clipvault', 'assets'),
      registerHotkey: (acc, handler) => {
        if (NO_HOTKEY) return null;
        try { return globalShortcut.register(acc, handler) ? () => globalShortcut.unregister(acc) : null; } catch { return null; }
      },
      onToast: (m, kind) => pill.toast(m, kind),
      isFlowWritingClipboard: () => writing,
      onFlowClipboardWrite: (cb) => { cvListeners.add(cb); return () => cvListeners.delete(cb); },
      sendToUi: (ch, payload) => { for (const w of BrowserWindow.getAllWindows()) if (!w.isDestroyed()) w.webContents.send('clipvault:event:' + ch, payload); },
      log: (...a) => log('[clipvault]', ...a),
    });
  } catch (e) {
    log('clipvault init failed', e);
  }

  // ── tray ──
  const tray = new FlowTray({
    openHub: () => openHub(),
    openClipVault: () => (cv ? cv.openPanel() : openHub('clipvault')),
    togglePause: () => {
      paused = !paused;
      hotkeys?.machine.setEnabled(!paused);
      pill.toast(t(settings.locale, paused ? 'toastPaused' : 'toastResumed'));
      tray.update(settings.locale, settings.hotkey, paused);
      pushState();
    },
    checkUpdates: () => void checkForUpdates(),
    quit: () => app.quit(),
  });
  if (!flag('smoke')) { tray.create(); tray.update(settings.locale, settings.hotkey, paused); }

  // ── notetaker (src/meeting) ──
  try {
    meeting = initMeeting({
      userData: paths.userData, modelsRoot: paths.models, preloadPath: paths.preload('meetingCapture'), capturePage: paths.renderer('meeting', 'capture.html'),
      noHotkey: NO_HOTKEY, locale: () => settings.locale, micDeviceId: () => settings.micDeviceId,
      clean: (text) => applyRules(text, { removeFillers: settings.removeFillers, voiceCommands: false, dictionary: settings.dictionary }),
      asr: () => asr.getEngine(),
      waitAsr: () => new Promise((resolve, reject) => {
        const e = asr.getEngine();
        if (e) return resolve(e);
        if (asr.state.status === 'missing') void asr.start(settings.engine, true);
        const onReady = () => { asr.off('ready', onReady); resolve(asr.getEngine()!); };
        asr.on('ready', onReady);
        setTimeout(() => { asr.off('ready', onReady); if (!asr.getEngine()) reject(new Error(t(settings.locale, 'toastNoModel'))); }, 30 * 60_000).unref?.();
      }),
      // like the hub's copy button: the real clipboard only on Windows (dev runs elsewhere stay in memory)
      copyText: (text) => (IS_WIN && !flag('smoke') ? clipboard.writeText(text) : clip.writeText(text)),
      pill: {
        meeting: (m) => pill.state({ meeting: m }),
        task: (x) => pill.state({ task: x }),
        card: (c) => pill.state({ meetingCard: c }),
        toast: (text, kind, ms) => pill.toast(text, kind, ms),
        level: (lv) => { if (dictation.state === 'idle') pill.level(lv); },
      },
      openHub: (page) => openHub(page),
      hubs: () => (hub && !hub.isDestroyed() ? [hub] : []),
      log: (...a) => log('[meeting]', ...a),
      onTrayChange: () => tray.update(settings.locale, settings.hotkey, paused),
    });
    tray.extraItems = () => meeting?.trayItems() ?? [];
    tray.update(settings.locale, settings.hotkey, paused);
  } catch (e) {
    log('notetaker init failed', e);
  }

  // ── settings side effects ──
  const applySystem = () => {
    if (app.isPackaged && IS_WIN) app.setLoginItemSettings({ openAtLogin: settings.startWithWindows, args: ['--hidden'] });
  };
  applySystem();
  const setSettings = (patch: Partial<Settings>) => {
    const prev = settings;
    settings = patchSettings(settings, patch);
    settingsFile.save(settings);
    if (prev.hotkey !== settings.hotkey || prev.doubleTapHandsFree !== settings.doubleTapHandsFree) hotkeys?.setChoice(settings.hotkey, settings.doubleTapHandsFree);
    if (prev.engine !== settings.engine) void asr.start(settings.engine, true);
    if (prev.startWithWindows !== settings.startWithWindows) applySystem();
    if (prev.pillAlwaysVisible !== settings.pillAlwaysVisible) pill.state({ alwaysVisible: settings.pillAlwaysVisible });
    if (prev.locale !== settings.locale || prev.hotkey !== settings.hotkey) tray.update(settings.locale, settings.hotkey, paused);
    if (prev.learnFromEdits && !settings.learnFromEdits) learner?.stop();
    if (!prev.mouseTarget && settings.mouseTarget) uiaClient?.warm();
    pushState();
    return buildState();
  };

  // ── „Wort gelernt?“ card at the pill ──
  let cardId = 0;
  let cardRetry: NodeJS.Timeout | null = null;
  const showNextCard = () => {
    if (cardRetry) { clearTimeout(cardRetry); cardRetry = null; }
    const p = learnQueue.current;
    if (!p) { pill.card(null); return; }
    // pill busy (dictation running) → later
    if (dictation.state !== 'idle') { cardRetry = setTimeout(showNextCard, 2000); return; }
    const L = settings.locale;
    const many = p.options.length > 1;
    pill.card({
      id: ++cardId, title: t(L, 'learnTitle'), options: p.options, save: t(L, 'learnSave'), no: t(L, 'learnNo'), timeoutMs: many ? 20_000 : 15_000,
      text: many ? t(L, 'learnTextChoose', { old: p.old }) : t(L, 'learnText', { old: p.old, new: p.options[0] ?? '' }),
    });
  };
  onLearnCandidate = (items) => { if (learnQueue.add(items)) showNextCard(); };
  pill.onCardAnswer = (a) => {
    if (a.id !== cardId) return;
    const e = learnQueue.answer(a.save, a.choice);
    if (e) {
      setSettings({ dictionary: rememberEntry(settings.dictionary, e.heard, e.write) });
      log('Lernen: Wort ins Wörterbuch übernommen' + (logText ? ` „${e.heard}“ → „${e.write}“` : ''));
      pill.toast(t(settings.locale, 'learnSaved'), 'success', 2000);
    }
    if (learnQueue.current) cardRetry = setTimeout(showNextCard, 600); else pill.card(null);
  };

  // ── IPC (hub) ──
  ipcMain.handle('hub:getState', () => buildState());
  ipcMain.handle('hub:setSettings', (_e, patch: Partial<Settings>) => setSettings(patch ?? {}));
  ipcMain.handle('hub:history:delete', (_e, id: string) => { history.delete(String(id)); pushState(); });
  ipcMain.handle('hub:history:clear', () => { history.clear(); pushState(); });
  ipcMain.handle('hub:copy', async (_e, text: string) => { if (IS_WIN) await clipboard.writeText(String(text)); else await clip.writeText(String(text)); });
  ipcMain.handle('hub:model:download', (_e, model: string) => { void asr.start(model === 'whisper-turbo' ? 'whisper-turbo' : 'parakeet-v3', true); });
  ipcMain.handle('hub:mic:devices', () => mic.devices());
  ipcMain.handle('hub:mic:monitor', (_e, on: boolean) => mic.monitor(!!on && !mic.isRecording, settings.micDeviceId));
  ipcMain.handle('hub:checkUpdates', () => checkForUpdates());
  ipcMain.handle('hub:open', (_e, what: string) => {
    if (what === 'micSettings') return shell.openExternal(IS_WIN ? 'ms-settings:privacy-microphone' : 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone');
    if (what === 'dataFolder') return shell.openPath(paths.userData);
    if (what === 'homepage') return shell.openExternal(RELEASE.homepage);
    return undefined;
  });

  // ── updates ──
  initUpdater(() => pill.toast(t(settings.locale, 'toastUpdate'), 'success', 4000));
  scheduleUpdates(() => settings.autoUpdate);

  // ── lifecycle ──
  app.on('second-instance', () => openHub());
  app.on('window-all-closed', () => { /* stay in tray */ });
  let quitting = false;
  app.on('before-quit', (e) => {
    if (quitting) return;
    quitting = true;
    e.preventDefault();
    (async () => {
      hotkeys?.stop();
      globalShortcut.unregisterAll();
      learner?.stop();
      mouse?.endTracking();
      highlight?.destroy();
      uia.dispose();
      try { await cv?.dispose(); } catch (err) { log('clipvault dispose', err); }
      try { await meeting?.dispose(); } catch (err) { log('notetaker dispose', err); }
      settingsFile.flush();
      history.flush();
      asr.dispose();
      tray.destroy();
      pill.destroy();
      mic.destroy();
      hardExit(0);
    })();
  });

  const showHub = flag('dev') || firstRun || (!flag('hidden') && !flag('smoke'));
  if (showHub) openHub();

  if (flag('smoke')) await smoke(flagValue('smoke') ?? '', { asr, dictation, history, getHub: () => hub, openHub, meeting });
}

/** End-to-end self test without mic/hotkey/clipboard: WAV → ASR → pipeline → (no-op paste) → history → hub. */
async function smoke(wav: string, x: { asr: AsrService; dictation: Dictation; history: History; getHub: () => BrowserWindow | null; openHub: () => void; meeting: MeetingHandle | null }) {
  const out = process.env.FLOW_SMOKE_OUT ?? path.join(process.cwd(), '.cache', 'render');
  const fail = (m: string) => { console.error('SMOKE FAIL:', m); hardExit(1); };
  const deadline = Date.now() + 120_000;
  while (!x.asr.ready) {
    if (Date.now() > deadline || x.asr.state.status === 'error' || x.asr.state.status === 'missing') return fail(`asr not ready (${x.asr.state.status} ${x.asr.state.error})`);
    await new Promise((r) => setTimeout(r, 200));
  }

  const { parseWav } = require('../asr/wav') as typeof import('../asr/wav');
  const w = parseWav(readFileSync(wav));
  await x.dictation.process(w.samples);
  const rec = x.history.records[0];
  if (!rec) return fail('no history record');
  console.log('SMOKE text:', rec.text);
  x.openHub();
  const hub = x.getHub()!;
  await new Promise((r) => setTimeout(r, 1500));
  const ready = await hub.webContents.executeJavaScript('document.body.dataset.ready === "1" && document.querySelectorAll(".item").length');
  if (!ready) return fail('hub did not render history');
  const img = await hub.webContents.capturePage();
  const { writeFileSync, mkdirSync } = await import('node:fs');
  mkdirSync(out, { recursive: true });
  writeFileSync(path.join(out, 'smoke_hub.png'), img.toPNG());
  console.log('SMOKE OK', rec.text.length, 'chars, hub items:', ready);
  // --meeting-selftest=<audio file>: notetaker import through the real app (decoder, ASR, diarization, hub page)
  const mfile = flagValue('meeting-selftest');
  if (mfile && x.meeting) {
    const { meetingSelfTest } = require('../meeting/main') as typeof import('../meeting/main');
    const r = await meetingSelfTest(x.meeting, mfile, hub, out);
    if (!r.ok) return fail('meeting: ' + r.error);
  }
  x.asr.dispose();
  hardExit(0);
}
