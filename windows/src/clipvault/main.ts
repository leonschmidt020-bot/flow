// ClipVault for Flow (Windows) – main-process entry. Contract: INTERFACE.md / contract.ts.
//
// Data: <userDataDir>/clipvault/ (see core/store.ts). Hotkey: Ctrl+Shift+V via ctx.registerHotkey.
// No telemetry; network only when the user switches sync on AND enters their own worker URL.
import { BrowserWindow, dialog, ipcMain, nativeImage, net, powerMonitor, shell, safeStorage, type IpcMainInvokeEvent } from 'electron';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { ClipVaultContext, ClipVaultHandle } from './contract';
import { Store, type IndexCodec } from './core/store';
import { ClipboardWatcher } from './core/watcher';
import { loadSettings, saveSettings, sanitizeSettings, type Settings } from './core/settings';
import { buildList, toView, fileUrl } from './core/view';
import type { TypeFilter, ItemView } from './core/types';
import { genericPlatform, type Platform } from './platform/types';
import { loadWin32Platform } from './platform/win32';
import { ElectronClipboardAdapter, loadFineFromDisk, writeFilesToClipboard, writeImageToClipboard, writeTextToClipboard } from './electron/clipboardAdapter';
import { PanelWindow } from './electron/panelWindow';
import { SharedVault } from './sync/vault';
import { SyncEngine, type SecretBox, type WsFactory, type FetchLike, type SyncSnapshot } from './sync/engine';
import { soleURL } from './core/badges';
import { tr } from './ui/i18n';
import type { SharedItem } from './sync/wire';

type Handler = (e: IpcMainInvokeEvent, ...args: any[]) => unknown; // eslint-disable-line @typescript-eslint/no-explicit-any

export async function initClipVault(ctx: ClipVaultContext): Promise<ClipVaultHandle> {
  const dir = path.join(ctx.userDataDir, 'clipvault');
  fs.mkdirSync(dir, { recursive: true });
  const L = ctx.locale;
  const t = (k: Parameters<typeof tr>[1], ...a: (string | number)[]) => tr(L, k, ...a);
  const log = (...a: unknown[]) => ctx.log(...a);

  const platform: Platform = loadWin32Platform(log) ?? genericPlatform;
  let settings: Settings = loadSettings(dir);

  // ---- encryption at rest (optional, DPAPI on Windows) ----
  const codecFor = (s: Settings): IndexCodec | null => (s.encryptAtRest && platform.dpapi ? platform.dpapi : null);
  const limits = () => ({ maxAgeSec: settings.maxAgeDays * 86400, maxItems: settings.maxItems, quotaBytes: settings.quotaMB * 1024 * 1024 });
  const store = new Store(dir, { limits: limits(), codec: platform.dpapi ?? null, log, locale: L });
  store.load();
  // the codec above only lets us READ an encrypted index; write (index + backup) in the form the setting asks for
  if (!store.readOnly) store.setCodec(codecFor(settings));

  // ---- UI plumbing ----
  const panel = new PanelWindow({
    platform, locale: L, log,
    preload: PanelWindow.preloadPath(__dirname), // main bundle = dist/main.js -> dist/clipvault/preload.js
    html: PanelWindow.htmlPath(__dirname),
  });
  let changeTimer: ReturnType<typeof setTimeout> | null = null;
  const emit = (name: string, payload?: unknown) => {
    ctx.sendToUi(name, payload);
    const w = panel.win;
    if (w && !w.isDestroyed()) w.webContents.send('clipvault:event', name, payload);
  };
  const changed = () => {
    if (changeTimer) return;
    changeTimer = setTimeout(() => { changeTimer = null; emit('changed'); }, 120);
  };
  const offStore = store.onChange(changed);

  // ---- clipboard watcher ----
  const adapter = new ElectronClipboardAdapter(platform);
  const watcher = new ClipboardWatcher(adapter, store, {
    intervalMs: 250,
    sensitive: () => ({ skipPasswordLike: settings.skipPasswordLike, ignoredApps: settings.ignoredApps }),
    isSuppressed: () => { try { return ctx.isFlowWritingClipboard(); } catch { return false; } },
    loadFine: loadFineFromDisk,
    log,
  });
  await watcher.start();
  await watcher.pause(settings.paused);
  let offFlow: (() => void) | null = null;
  try {
    offFlow = ctx.onFlowClipboardWrite((w) => {
      if (w.phase === 'keep' && w.text.trim()) store.addText(w.text, 'Diktat');
      void watcher.skipCurrent(); // insert/restore: never history
    });
  } catch { offFlow = null; }

  // ---- sync (off by default) ----
  const me = () => settings.sync.name || (os.userInfo().username || 'Windows').replace(/^./, (c) => c.toUpperCase());
  const secretBox = (): SecretBox | null => {
    if (platform.dpapi) return { protect: platform.dpapi.protect, unprotect: platform.dpapi.unprotect };
    if (safeStorage.isEncryptionAvailable()) {
      return { protect: (b) => safeStorage.encryptString(b.toString('base64')), unprotect: (b) => Buffer.from(safeStorage.decryptString(b), 'base64') };
    }
    return null;
  };
  const vault = new SharedVault(dir, { me, codec: platform.dpapi, log }); // loaded (and re-encoded) when sync starts
  let engine: SyncEngine | null = null;
  let onlineTimer: ReturnType<typeof setInterval> | null = null;
  const offVault = vault.onChange(changed);
  const startSync = () => {
    if (engine) return;
    const box = secretBox();
    if (!box) { ctx.onToast(t('syncNoSecretStore'), 'error'); return; }
    if (!vault.loaded) { vault.load(); vault.setCodec(codecFor(settings)); }
    const fetchImpl: FetchLike = (url, init) => (typeof net?.fetch === 'function' ? net.fetch(url, init as RequestInit) : fetch(url, init as RequestInit));
    const wsImpl: WsFactory = (url, protocols) => {
      const W = (globalThis as unknown as { WebSocket?: new (u: string, p: string[]) => unknown }).WebSocket;
      if (!W) throw new Error('no WebSocket');
      return new W(url, protocols) as ReturnType<WsFactory>;
    };
    engine = new SyncEngine({
      dir, vault, secrets: box, fetch: fetchImpl, ws: wsImpl, me, log,
      onSnapshot: (s: SyncSnapshot) => emit('sync', s),
      onReceived: (items, live) => {
        for (const it of items) if (store.item(it.id)) store.setShared(it.id, !it.deleted);
        const fresh = items.find((i) => !i.deleted && i.createdBy !== me());
        if (live && fresh) ctx.onToast(t('sharedFrom', fresh.createdBy), 'info');
      },
    });
    engine.start();
    let wasOnline = net.isOnline();
    onlineTimer = setInterval(() => { const on = net.isOnline(); if (on && !wasOnline) engine?.kick(); wasOnline = on; }, 5000);
  };
  const stopSync = () => {
    engine?.stop(); engine = null;
    if (onlineTimer) clearInterval(onlineTimer);
    onlineTimer = null;
    emit('sync', null);
  };
  const onResume = () => engine?.kick();
  powerMonitor.on('resume', onResume);
  powerMonitor.on('unlock-screen', onResume);
  if (settings.sync.enabled) startSync();

  // ---- helpers ----
  const fromPanel = (e: IpcMainInvokeEvent) => !!panel.win && !panel.win.isDestroyed() && e.sender === panel.win.webContents;
  const copyItem = async (id: string): Promise<boolean> => {
    const it = store.item(id);
    if (it) {
      if (it.kind === 'text') await writeTextToClipboard(it.text ?? '');
      else if (it.kind === 'image') { const p = store.imagePath(it); if (!p || !fs.existsSync(p)) return false; await writeImageToClipboard(p); }
      else {
        const paths = store.filePaths(it);
        if (!paths.length) return false;
        await writeFilesToClipboard(platform, paths, panel.nativeHandle());
      }
      await watcher.skipCurrent(); // our own write is not a new entry
      store.touch(id);
      return true;
    }
    const s = vault.item(id);
    if (!s || s.deleted) return false;
    if (s.kind === 'text' || s.kind === 'link') await writeTextToClipboard(s.text ?? '');
    else {
      const p = vault.localPath(s);
      if (!p || !vault.isLocal(s)) { void engine?.download(s.id); ctx.onToast(t('loading'), 'info'); return false; }
      if (s.kind === 'image') await writeImageToClipboard(p); else await writeFilesToClipboard(platform, [p], panel.nativeHandle());
    }
    await watcher.skipCurrent();
    return true;
  };
  const sharedView = (s: SharedItem): ItemView => {
    const de = L === 'de';
    const local = vault.isLocal(s);
    const p = vault.localPath(s);
    return {
      id: s.id, kind: s.kind === 'link' ? 'text' : s.kind, isLink: s.kind === 'link' || !!soleURL(s.text),
      title: s.kind === 'image' ? (de ? 'Bild' : 'Image') : s.kind === 'file' ? s.fileName ?? 'Datei' : ((s.text ?? '').split('\n')[0] ?? '').slice(0, 140),
      subtitle: [s.createdBy, s.size ? `${(s.size / 1e6).toFixed(1)} MB` : '', !local ? (de ? 'nicht geladen' : 'not downloaded') : '', vault.pending.has(s.id) ? (de ? 'wartet auf Sync' : 'waiting for sync') : '', s.uploadError ?? '']
        .filter(Boolean).join(' · '),
      badges: [], ts: s.updatedAt, pinned: s.pinned, collection: '__shared__', masked: false, shared: true, source: s.createdBy,
      ...(s.kind === 'image' && local && p ? { thumbUrl: fileUrl(p, s.updatedAt), imageUrl: fileUrl(p, s.updatedAt) } : {}),
      ...(s.kind === 'file' ? { fileNames: [s.fileName ?? 'Datei'] } : {}),
      ...(s.kind === 'text' || s.kind === 'link' ? { text: s.text ?? '' } : {}),
    };
  };
  const imageAbs = (id: string): string | null => {
    const it = store.item(id);
    if (it?.kind === 'image') return store.imagePath(it);
    const s = vault.item(id);
    return s?.kind === 'image' && vault.isLocal(s) ? vault.imagePath(s.id) : null;
  };
  const filesOf = (id: string): string[] => {
    const it = store.item(id);
    if (it) return it.kind === 'file' ? store.filePaths(it) : it.kind === 'image' && store.imagePath(it) ? [store.imagePath(it)!] : [];
    const s = vault.item(id);
    const p = s ? vault.localPath(s) : null;
    return p && s && vault.isLocal(s) ? [p] : [];
  };

  const settingsView = () => ({ ...settings, dpapiAvailable: !!platform.dpapi, platform: platform.name, dataDir: dir, readOnly: store.readOnly, recovery: store.lastRecovery });

  // ---- IPC ----
  const handlers: Record<string, Handler> = {
    list: (_e, q: { query?: string; type?: TypeFilter; collection?: string | null } = {}) => {
      if (q.collection === '__shared__') {
        const needle = (q.query ?? '').toLowerCase();
        const items = vault.visible().filter((s) => !needle || `${s.text ?? ''} ${s.fileName ?? ''} ${s.createdBy}`.toLowerCase().includes(needle)).map(sharedView);
        const base = buildList(store, { locale: L, collection: null });
        return { ...base, sections: [{ key: 'shared', items }] };
      }
      return buildList(store, { ...q, locale: L });
    },
    item: (_e, id: string, reveal = false) => {
      const it = store.item(id);
      if (it) return toView(it, store, { full: true, revealSecrets: !!reveal, locale: L });
      const s = vault.item(id);
      return s ? sharedView(s) : null;
    },
    image: (_e, id: string) => {
      const p = imageAbs(id);
      if (!p) return null;
      const img = nativeImage.createFromPath(p);
      return img.isEmpty() ? null : { url: img.toDataURL(), w: img.getSize().width, h: img.getSize().height };
    },
    copy: async (_e, id: string) => {
      const ok = await copyItem(id);
      if (ok) ctx.onToast(t('copied'), 'success');
      return ok;
    },
    paste: async (e, id: string) => {
      if (!(await copyItem(id))) return false;
      if (!fromPanel(e) || !settings.pasteOnEnter) { ctx.onToast(t('copied'), 'success'); return true; }
      const pasted = await panel.pasteIntoPrevious();
      if (!pasted) ctx.onToast(t('copiedPasteManually'), 'info');
      return true;
    },
    pin: (_e, id: string, on: boolean) => {
      if (store.item(id)) return store.setPinned(id, !!on);
      const s = vault.setPinned(id, !!on);
      if (s) void engine?.enqueue(s.id);
      return !!s;
    },
    delete: (_e, id: string) => {
      if (store.item(id)) return store.delete(id);
      const ids = vault.unshare(id);
      for (const i of ids) void engine?.enqueue(i);
      return ids.length > 0;
    },
    setCollection: (_e, id: string, cid: string | null) => store.setCollection(id, cid ?? null),
    edit: (_e, id: string, text: string) => store.edit(id, String(text ?? '')),
    createCollection: (_e, name: string, secret?: boolean) => store.createCollection(String(name ?? ''), secret ? 'lock' : 'folder', secret ? true : undefined),
    renameCollection: (_e, id: string, name: string, symbol?: string) => store.renameCollection(id, name, symbol),
    deleteCollection: (_e, id: string) => store.deleteCollection(id),
    openLink: (_e, id: string) => {
      const it = store.item(id);
      const u = soleURL(it?.text ?? vault.item(id)?.text ?? null);
      if (!u) return false;
      void shell.openExternal(u);
      panel.hide(false);
      return true;
    },
    reveal: (_e, id: string) => {
      const f = filesOf(id)[0];
      if (!f) return false;
      shell.showItemInFolder(f);
      panel.hide(false);
      return true;
    },
    saveAs: async (e, id: string) => {
      const files = filesOf(id);
      const it = store.item(id);
      const isText = !files.length && (it?.kind === 'text' || ['text', 'link'].includes(vault.item(id)?.kind ?? ''));
      const suggested = files[0] ? path.basename(files[0]).replace(/^[0-9A-F-]{36}\.png$/i, 'Bild.png') : isText ? 'Text.txt' : 'Datei';
      const parent = fromPanel(e) ? panel.win! : BrowserWindow.fromWebContents(e.sender) ?? undefined;
      panel.modal = true;
      try {
        const r = parent
          ? await dialog.showSaveDialog(parent, { defaultPath: path.join(ctx.app.getPath('downloads'), suggested) })
          : await dialog.showSaveDialog({ defaultPath: path.join(ctx.app.getPath('downloads'), suggested) });
        if (r.canceled || !r.filePath) return false;
        if (files[0]) fs.copyFileSync(files[0], r.filePath);
        else if (isText) fs.writeFileSync(r.filePath, it?.text ?? vault.item(id)?.text ?? '', 'utf8');
        else return false;
        ctx.onToast(t('saved'), 'success');
        return true;
      } finally {
        panel.modal = false;
      }
    },
    settings: () => settingsView(),
    setSettings: async (_e, patch: Partial<Settings>) => {
      const before = settings;
      settings = sanitizeSettings({ ...settings, ...patch, sync: { ...settings.sync, ...(patch?.sync ?? {}) } });
      saveSettings(dir, settings);
      Object.assign(store.limits, limits());
      if (store.prune()) store.persist();
      if (before.encryptAtRest !== settings.encryptAtRest) {
        if (settings.encryptAtRest && !platform.dpapi) { settings.encryptAtRest = false; saveSettings(dir, settings); }
        store.setCodec(codecFor(settings));
        vault.setCodec(codecFor(settings));
      }
      if (before.paused !== settings.paused) await watcher.pause(settings.paused);
      if (before.sync.enabled !== settings.sync.enabled) (settings.sync.enabled ? startSync : stopSync)();
      if (before.hotkey !== settings.hotkey) bindHotkey();
      const view = settingsView();
      emit('settings', view);
      return view;
    },
    clearHistory: () => store.clearHistory(),
    hide: () => { panel.hide(true); return true; },
    viewer: (_e, on: boolean) => { panel.setViewer(!!on); return true; },
    openHub: () => { panel.hide(false); emit('open-hub'); return true; },
    // ---- sync ----
    syncStatus: () => (engine ? engine.status() : { state: 'off' }),
    syncSetup: (_e, url: string) => { if (!engine) startSync(); return engine!.setup(String(url ?? '')); },
    syncPairCreate: async () => { if (!engine) startSync(); return engine!.pairCreate(); },
    syncPairJoin: async (_e, code: string) => { if (!engine) startSync(); return engine!.pairJoin(String(code ?? '')); },
    syncPairCancel: async () => engine?.pairCancel(),
    syncUnpair: () => { engine?.unpair(); return true; },
    share: async (_e, id: string) => {
      const it = store.item(id);
      if (!it) return false;
      if (!engine) { ctx.onToast(t('syncOff'), 'info'); return false; }
      try {
        const out = vault.share(it, (rel) => store.abs(rel));
        store.setShared(id, true);
        for (const s of out) await engine.enqueue(s.id);
        ctx.onToast(t('shared'), 'success');
        return true;
      } catch (err) {
        ctx.onToast((err as Error).message, 'error');
        return false;
      }
    },
    unshare: (_e, id: string) => {
      const ids = vault.unshare(id);
      store.setShared(id, false);
      for (const i of ids) void engine?.enqueue(i);
      return ids.length > 0;
    },
    download: async (_e, id: string) => { await engine?.download(id); return true; },
  };
  for (const [name, fn] of Object.entries(handlers)) {
    ipcMain.removeHandler('clipvault:' + name);
    ipcMain.handle('clipvault:' + name, async (e, ...args) => {
      try { return await fn(e, ...args); } catch (err) { log('[clipvault] ipc', name, (err as Error).message); throw new Error((err as Error).message); }
    });
  }

  // ---- hotkey ----
  let unbind: (() => void) | null = null;
  const bindHotkey = () => {
    unbind?.();
    unbind = ctx.registerHotkey(settings.hotkey, () => panel.toggle());
    if (!unbind) log(`[clipvault] hotkey ${settings.hotkey} not available`);
  };
  bindHotkey();

  // periodic retention (history ages out even when nothing is copied)
  const pruneTimer = setInterval(() => { if (store.prune()) store.persist(); }, 10 * 60 * 1000);

  log(`[clipvault] ready (${platform.name}, ${store.items.length} entries, encryption ${store.codec ? 'on' : 'off'}, sync ${settings.sync.enabled ? 'on' : 'off'})`);

  return {
    openPanel: () => panel.show(),
    dispose: async () => {
      unbind?.();
      watcher.stop();
      clearInterval(pruneTimer);
      offStore(); offVault(); offFlow?.();
      powerMonitor.removeListener('resume', onResume);
      powerMonitor.removeListener('unlock-screen', onResume);
      await engine?.idle().catch(() => {});
      stopSync();
      for (const name of Object.keys(handlers)) ipcMain.removeHandler('clipvault:' + name);
      panel.destroy();
      if (!store.readOnly) store.persist();
    },
  };
}
