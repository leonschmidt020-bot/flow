import { contextBridge, ipcRenderer } from 'electron';

const on = (ch: string, cb: (p: unknown) => void) => {
  const f = (_e: unknown, p: unknown) => cb(p);
  ipcRenderer.on(ch, f);
  return () => ipcRenderer.removeListener(ch, f);
};

contextBridge.exposeInMainWorld('flow', {
  getState: () => ipcRenderer.invoke('hub:getState'),
  setSettings: (patch: unknown) => ipcRenderer.invoke('hub:setSettings', patch),
  deleteHistory: (id: string) => ipcRenderer.invoke('hub:history:delete', id),
  clearHistory: () => ipcRenderer.invoke('hub:history:clear'),
  copy: (text: string) => ipcRenderer.invoke('hub:copy', text),
  downloadModel: (model: string) => ipcRenderer.invoke('hub:model:download', model),
  micDevices: () => ipcRenderer.invoke('hub:mic:devices'),
  micMonitor: (on: boolean) => ipcRenderer.invoke('hub:mic:monitor', on),
  open: (what: 'micSettings' | 'dataFolder' | 'homepage') => ipcRenderer.invoke('hub:open', what),
  checkUpdates: () => ipcRenderer.invoke('hub:checkUpdates'),
  onState: (cb: (s: unknown) => void) => on('hub:state', cb),
  onLevel: (cb: (lv: unknown) => void) => on('hub:level', cb),
  onNavigate: (cb: (page: unknown) => void) => on('hub:navigate', cb),
  clipvault: {
    invoke: (name: string, ...args: unknown[]) => ipcRenderer.invoke('clipvault:' + name, ...args),
    on: (name: string, cb: (p: unknown) => void) => on('clipvault:event:' + name, cb),
  },
});
