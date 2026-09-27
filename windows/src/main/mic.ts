// Microphone capture in a hidden renderer (getUserMedia → AudioWorklet @ 16 kHz mono), streamed to main.
import { BrowserWindow, ipcMain, type IpcMainEvent } from 'electron';
import { EventEmitter } from 'node:events';
import { paths } from './paths';
import { log } from './log';

export interface MicDevice { deviceId: string; label: string }

export class Mic extends EventEmitter {
  private win: BrowserWindow | null = null;
  private chunks: Float32Array[] = [];
  private recording = false;
  private readyP: Promise<void> | null = null;
  private gen = 0;
  lastError = '';

  private ensure(): Promise<void> {
    if (this.readyP && this.win && !this.win.isDestroyed()) return this.readyP;
    this.win = new BrowserWindow({
      show: false, width: 200, height: 100, skipTaskbar: true, focusable: false,
      webPreferences: { preload: paths.preload('mic'), contextIsolation: true, sandbox: false, backgroundThrottling: false },
    });
    this.readyP = this.win.loadFile(paths.renderer('mic', 'mic.html')).then(() => undefined);
    return this.readyP;
  }

  init() {
    ipcMain.on('mic:chunk', (_e: IpcMainEvent, buf: Float32Array | ArrayBuffer) => {
      if (!this.recording) return;
      this.chunks.push(buf instanceof Float32Array ? buf : new Float32Array(buf));
    });
    ipcMain.on('mic:level', (_e, lv: number) => this.emit('level', lv));
    ipcMain.on('mic:error', (_e, err: { name: string; message: string }) => {
      this.lastError = err.name || err.message;
      log('mic error', err);
      this.emit('error', err);
    });
    ipcMain.on('mic:stopped', () => this.emit('stopped'));
    ipcMain.on('mic:started', (_e, info: { label: string; sampleRate: number }) => { log('mic started', info); this.emit('started', info); });
  }

  warm() { void this.ensure(); }

  async start(deviceId: string): Promise<void> {
    const g = ++this.gen;
    await this.ensure();
    if (g !== this.gen) return; // cancelled while the capture page was loading
    this.chunks = [];
    this.recording = true;
    this.win?.webContents.send('mic:start', { deviceId });
  }

  /** stop and return all samples (16 kHz mono) */
  async stop(): Promise<Float32Array> {
    this.gen++;
    if (!this.recording) return new Float32Array(0);
    // the worklet flushes its last partial block, then the page reports 'stopped' (IPC keeps order)
    const stopped = new Promise<void>((r) => { const t = setTimeout(r, 600); this.once('stopped', () => { clearTimeout(t); r(); }); });
    this.win?.webContents.send('mic:stop');
    await stopped;
    this.recording = false;
    const n = this.chunks.reduce((a, c) => a + c.length, 0);
    const out = new Float32Array(n);
    let o = 0;
    for (const c of this.chunks) { out.set(c, o); o += c.length; }
    this.chunks = [];
    return out;
  }

  cancel() {
    this.gen++;
    this.recording = false;
    this.chunks = [];
    this.win?.webContents.send('mic:stop');
  }

  /** level meter for the settings page (no recording) */
  async monitor(on: boolean, deviceId: string) {
    await this.ensure();
    this.win?.webContents.send(on ? 'mic:monitor' : 'mic:stop', { deviceId });
  }

  async devices(): Promise<MicDevice[]> {
    await this.ensure();
    try { return (await this.win!.webContents.executeJavaScript('window.__flowDevices()')) as MicDevice[]; } catch { return []; }
  }

  get isRecording() { return this.recording; }
  destroy() { this.win?.destroy(); this.win = null; }
}
