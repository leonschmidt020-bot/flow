import { contextBridge, ipcRenderer, webUtils } from 'electron';

contextBridge.exposeInMainWorld('flowPill', {
  onState: (cb: (s: unknown) => void) => ipcRenderer.on('pill:state', (_e, s) => cb(s)),
  onLevel: (cb: (lv: number) => void) => ipcRenderer.on('pill:level', (_e, lv) => cb(lv)),
  onToast: (cb: (t: unknown) => void) => ipcRenderer.on('pill:toast', (_e, t) => cb(t)),
  setInteractive: (on: boolean) => ipcRenderer.send('pill:interactive', on),
  click: (what: string) => ipcRenderer.send('pill:click', what),
  /** dropped files → paths (File.path is gone since Electron 32) */
  drop: (files: File[]) => ipcRenderer.send('pill:drop', files.map((f) => webUtils.getPathForFile(f)).filter(Boolean)),
  ready: () => ipcRenderer.send('pill:ready'),
});
