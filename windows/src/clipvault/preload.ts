// Preload for the ClipVault quick panel (bundled by Flow to dist/clipvault/preload.js, CommonJS).
// Only the "clipvault:" IPC prefix is reachable from the page.
import { contextBridge, ipcRenderer } from 'electron';

const params = new URLSearchParams(location.search);
const listeners = new Map<string, Set<(p: unknown) => void>>();
ipcRenderer.on('clipvault:event', (_e, name: string, payload: unknown) => {
  for (const cb of listeners.get(name) ?? []) { try { cb(payload); } catch { /* page error */ } }
});

contextBridge.exposeInMainWorld('clipvault', {
  locale: params.get('locale') === 'en' ? 'en' : 'de',
  material: params.get('material') ?? 'solid',
  invoke: (name: string, ...args: unknown[]) => ipcRenderer.invoke('clipvault:' + name, ...args),
  on: (name: string, cb: (p: unknown) => void) => {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name)!.add(cb);
    return () => listeners.get(name)?.delete(cb);
  },
});
