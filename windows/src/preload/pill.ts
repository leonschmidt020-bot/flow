import { contextBridge, ipcRenderer, webUtils } from 'electron';

contextBridge.exposeInMainWorld('flowPill', {
  onState: (cb: (s: unknown) => void) => ipcRenderer.on('pill:state', (_e, s) => cb(s)),
  onLevel: (cb: (lv: number) => void) => ipcRenderer.on('pill:level', (_e, lv) => cb(lv)),
  onToast: (cb: (t: unknown) => void) => ipcRenderer.on('pill:toast', (_e, t) => cb(t)),
  setInteractive: (on: boolean) => ipcRenderer.send('pill:interactive', on),
  click: (what: string) => ipcRenderer.send('pill:click', what),
  /** dropped files → paths (File.path is gone since Electron 32) */
  drop: (files: File[]) => ipcRenderer.send('pill:drop', files.map((f) => webUtils.getPathForFile(f)).filter(Boolean)),
  onCard: (cb: (c: unknown) => void) => ipcRenderer.on('pill:card', (_e, c) => cb(c)),
  answerCard: (a: unknown) => ipcRenderer.send('pill:cardAnswer', a),
  // Agent-Prompt card
  onAgent: (cb: (m: unknown) => void) => ipcRenderer.on('pill:ap', (_e, m) => cb(m)),
  onAgentFlash: (cb: (f: unknown) => void) => ipcRenderer.on('pill:apFlash', (_e, f) => cb(f)),
  agentAction: (a: string) => ipcRenderer.send('pill:apAction', a),
  agentHover: (on: boolean) => ipcRenderer.send('pill:apHover', on),
  ready: () => ipcRenderer.send('pill:ready'),
});
