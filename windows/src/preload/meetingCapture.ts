import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('flowMeetingCap', {
  onStart: (cb: (id: number, o: { micDeviceId: string; systemAudio: boolean }) => void) => ipcRenderer.on('meeting:cap:start', (_e, id, o) => cb(id, o)),
  onStop: (cb: (id: number) => void) => ipcRenderer.on('meeting:cap:stop', (_e, id) => cb(id)),
  onDecode: (cb: (id: number, bytes: ArrayBuffer) => void) => ipcRenderer.on('meeting:cap:decode', (_e, id, bytes) => cb(id, bytes)),
  reply: (id: number, ok: boolean, payload: unknown) => ipcRenderer.send('meeting:cap:reply', id, ok, payload),
  chunk: (track: string, s: Float32Array) => ipcRenderer.send('meeting:cap:chunk', track, s),
  level: (track: string, rms: number) => ipcRenderer.send('meeting:cap:level', track, rms),
  error: (msg: string) => ipcRenderer.send('meeting:cap:error', msg),
  ended: (track: string) => ipcRenderer.send('meeting:cap:ended', track),
});
