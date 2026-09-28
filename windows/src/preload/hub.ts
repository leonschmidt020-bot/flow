import { contextBridge, ipcRenderer, webUtils } from 'electron';

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
  meeting: {
    state: () => ipcRenderer.invoke('meeting:state'),
    get: (id: string) => ipcRenderer.invoke('meeting:get', id),
    start: () => ipcRenderer.invoke('meeting:start'),
    stop: () => ipcRenderer.invoke('meeting:stop'),
    pickFile: () => ipcRenderer.invoke('meeting:pickFile'),
    // File.path is gone since Electron 32 → webUtils
    dropFiles: (files: File[]) => ipcRenderer.invoke('meeting:import', files.map((f) => webUtils.getPathForFile(f)).filter(Boolean)),
    rename: (id: string, title: string) => ipcRenderer.invoke('meeting:rename', id, title),
    renameSpeaker: (id: string, key: string, name: string) => ipcRenderer.invoke('meeting:renameSpeaker', id, key, name),
    setKeep: (id: string, keep: boolean) => ipcRenderer.invoke('meeting:keep', id, keep),
    delete: (id: string) => ipcRenderer.invoke('meeting:delete', id),
    reprocess: (id: string) => ipcRenderer.invoke('meeting:reprocess', id),
    summarize: (id: string) => ipcRenderer.invoke('meeting:summarize', id),
    copyPrompt: (id: string) => ipcRenderer.invoke('meeting:copyPrompt', id),
    copyTranscript: (id: string) => ipcRenderer.invoke('meeting:copyTranscript', id),
    openFolder: (id: string) => ipcRenderer.invoke('meeting:openFolder', id),
    setSettings: (p: unknown) => ipcRenderer.invoke('meeting:setSettings', p),
    onState: (cb: (s: unknown) => void) => on('meeting:state', cb),
  },
  prompts: {
    list: () => ipcRenderer.invoke('prompts:list'),
    delete: (id: string) => ipcRenderer.invoke('prompts:delete', id),
    copy: (id: string, which: 'prompt' | 'original') => ipcRenderer.invoke('prompts:copy', id, which),
    onChanged: (cb: () => void) => on('prompts:changed', () => cb()),
  },
  clipvault: {
    invoke: (name: string, ...args: unknown[]) => ipcRenderer.invoke('clipvault:' + name, ...args),
    on: (name: string, cb: (p: unknown) => void) => on('clipvault:event:' + name, cb),
  },
});
