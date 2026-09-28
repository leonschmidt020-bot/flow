// Electron side of the meeting capture (Windows): a hidden page records the microphone (getUserMedia) and the
// system audio (getDisplayMedia with audio: 'loopback' – WASAPI loopback of the default output device). The video
// track that getDisplayMedia always delivers is stopped at once in the page; no frame is ever read.
// The same hidden page decodes imported files with Chromium's built-in decoder when no ffmpeg is installed.
// Only this file touches Electron capture APIs; everything else talks to the `CaptureBackend` interface.
import { BrowserWindow, desktopCapturer, ipcMain, session, type IpcMainEvent } from 'electron';
import { EventEmitter } from 'node:events';
import { readFile } from 'node:fs/promises';
import type { CaptureBackend, CaptureStartResult, Track } from './recorder';

export interface CapturePaths { preload: string; page: string }

export class ElectronCapture extends EventEmitter implements CaptureBackend {
  private win: BrowserWindow | null = null;
  private ready: Promise<void> | null = null;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private seq = 0;
  private allowDisplay = false;

  constructor(private p: CapturePaths, private log: (...a: unknown[]) => void) {
    super();
    ipcMain.on('meeting:cap:chunk', (e: IpcMainEvent, track: Track, buf: Float32Array | ArrayBuffer) => {
      if (e.sender !== this.win?.webContents) return;
      this.emit('chunk', track, buf instanceof Float32Array ? buf : new Float32Array(buf));
    });
    ipcMain.on('meeting:cap:level', (e, track: Track, lv: number) => { if (e.sender === this.win?.webContents) this.emit('level', track, lv); });
    ipcMain.on('meeting:cap:error', (e, msg: string) => { if (e.sender === this.win?.webContents) { this.log('meeting capture error', msg); this.emit('error', msg); } });
    ipcMain.on('meeting:cap:ended', (e, track: Track) => { if (e.sender === this.win?.webContents) this.emit('ended', track); });
    ipcMain.on('meeting:cap:reply', (e, id: number, ok: boolean, payload: unknown) => {
      if (e.sender !== this.win?.webContents) return;
      const p = this.pending.get(id);
      if (!p) return;
      this.pending.delete(id);
      if (ok) p.resolve(payload); else p.reject(new Error(String(payload)));
    });
  }

  private ensure(): Promise<void> {
    if (this.ready && this.win && !this.win.isDestroyed()) return this.ready;
    this.win = new BrowserWindow({
      show: false, width: 200, height: 100, skipTaskbar: true, focusable: false,
      webPreferences: { preload: this.p.preload, contextIsolation: true, sandbox: false, backgroundThrottling: false },
    });
    // getDisplayMedia from our hidden page → whole-screen source + loopback audio, without the system picker.
    // Only while a recording is being started, and only for this page; everything else is denied.
    session.defaultSession.setDisplayMediaRequestHandler((req, cb) => {
      const ours = this.win && !this.win.isDestroyed() && req.frame?.url === this.win.webContents.getURL();
      if (!ours || !this.allowDisplay || process.platform !== 'win32') { cb({}); return; }
      desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } })
        .then((s) => (s[0] ? cb({ video: s[0], audio: 'loopback' }) : cb({})))
        .catch(() => cb({}));
    }, { useSystemPicker: false });
    this.ready = this.win.loadFile(this.p.page).then(() => undefined);
    return this.ready;
  }

  private call<T>(ch: string, ...args: unknown[]): Promise<T> {
    const id = ++this.seq;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.win?.webContents.send(ch, id, ...args);
    });
  }

  async start(o: { micDeviceId: string; systemAudio: boolean }): Promise<CaptureStartResult> {
    await this.ensure();
    this.allowDisplay = o.systemAudio && process.platform === 'win32';
    try {
      return await this.call<CaptureStartResult>('meeting:cap:start', { micDeviceId: o.micDeviceId, systemAudio: this.allowDisplay });
    } finally {
      this.allowDisplay = false;
    }
  }

  async stop(): Promise<void> {
    if (!this.win || this.win.isDestroyed()) return;
    await Promise.race([this.call('meeting:cap:stop'), new Promise((r) => setTimeout(r, 1500))]);
  }

  /** Chromium's decoder (Web Audio decodeAudioData, resampled to 16 kHz mono) */
  async decode(file: string): Promise<Float32Array> {
    await this.ensure();
    const buf = await readFile(file);
    const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
    const out = await this.call<Float32Array | ArrayBuffer>('meeting:cap:decode', ab);
    return out instanceof Float32Array ? out : new Float32Array(out);
  }

  destroy() { this.win?.destroy(); this.win = null; this.ready = null; }
}
