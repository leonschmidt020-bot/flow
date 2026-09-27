import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('flowMic', {
  onStart: (cb: (o: { deviceId: string }) => void) => ipcRenderer.on('mic:start', (_e, o) => cb(o)),
  onMonitor: (cb: (o: { deviceId: string }) => void) => ipcRenderer.on('mic:monitor', (_e, o) => cb(o)),
  onStop: (cb: () => void) => ipcRenderer.on('mic:stop', () => cb()),
  chunk: (samples: Float32Array) => ipcRenderer.send('mic:chunk', samples),
  level: (rms: number) => ipcRenderer.send('mic:level', rms),
  started: (info: unknown) => ipcRenderer.send('mic:started', info),
  stopped: () => ipcRenderer.send('mic:stopped'),
  error: (e: { name: string; message: string }) => ipcRenderer.send('mic:error', e),
});
