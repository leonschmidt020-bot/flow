import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('flowPill', {
  onState: (cb: (s: unknown) => void) => ipcRenderer.on('pill:state', (_e, s) => cb(s)),
  onLevel: (cb: (lv: number) => void) => ipcRenderer.on('pill:level', (_e, lv) => cb(lv)),
  onToast: (cb: (t: unknown) => void) => ipcRenderer.on('pill:toast', (_e, t) => cb(t)),
  setInteractive: (on: boolean) => ipcRenderer.send('pill:interactive', on),
  click: (what: 'cancel' | 'stop') => ipcRenderer.send('pill:click', what),
  onCard: (cb: (c: unknown) => void) => ipcRenderer.on('pill:card', (_e, c) => cb(c)),
  answerCard: (a: unknown) => ipcRenderer.send('pill:cardAnswer', a),
  ready: () => ipcRenderer.send('pill:ready'),
});
