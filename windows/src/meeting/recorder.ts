// Meeting recording: two tracks (microphone = ich.wav, system audio = andere.wav), kept time-aligned, plus live
// segments for the running transcript. The actual capture is behind `CaptureBackend` – on Windows a hidden Electron
// page (getUserMedia + getDisplayMedia audio loopback), in tests a mock that feeds WAV samples.
import { EventEmitter } from 'node:events';
import path from 'node:path';
import { LiveSegmenter } from './chunking';
import { MIC_FILE, SYSTEM_FILE } from './types';
import { WavWriter } from './wavWriter';

export type Track = 'mic' | 'system';

export interface CaptureStartResult { mic: boolean; system: boolean; error?: string }

/** events: 'chunk' (track, Float32Array @16 kHz mono), 'level' (track, rms), 'error' (message), 'ended' (track) */
export interface CaptureBackend extends EventEmitter {
  start(o: { micDeviceId: string; systemAudio: boolean }): Promise<CaptureStartResult>;
  stop(): Promise<void>;
}

export interface LiveChunk { track: Track; start: number; samples: Float32Array }

export class Recorder extends EventEmitter {
  private writers: Partial<Record<Track, WavWriter>> = {};
  private segs: Partial<Record<Track, LiveSegmenter>> = {};
  private frames: Record<Track, number> = { mic: 0, system: 0 };
  private onChunk = (track: Track, s: Float32Array) => this.chunk(track, s);
  private onLevel = (track: Track, lv: number) => this.emit('level', track, lv);
  private onError = (msg: string) => this.emit('error', msg);
  tracks = { mic: false, system: false };
  running = false;

  constructor(private backend: CaptureBackend, private folder: string) { super(); }

  async start(o: { micDeviceId: string; systemAudio: boolean }): Promise<CaptureStartResult> {
    this.backend.on('chunk', this.onChunk);
    this.backend.on('level', this.onLevel);
    this.backend.on('error', this.onError);
    // writers exist before the first chunk can arrive
    this.writers.mic = new WavWriter(path.join(this.folder, MIC_FILE));
    this.writers.system = o.systemAudio ? new WavWriter(path.join(this.folder, SYSTEM_FILE)) : undefined;
    for (const t of ['mic', 'system'] as Track[]) this.segs[t] = new LiveSegmenter((start, samples) => this.emit('live', { track: t, start, samples } satisfies LiveChunk));
    this.running = true;
    let r: CaptureStartResult;
    try { r = await this.backend.start(o); } catch (e) { r = { mic: false, system: false, error: e instanceof Error ? e.message : String(e) }; }
    this.tracks = { mic: r.mic, system: r.system && !!this.writers.system };
    if (!r.mic) { await this.stop(); return r; }
    if (!this.tracks.system && this.writers.system) { this.writers.system.close(); this.writers.system = undefined; }
    return r;
  }

  private chunk(track: Track, s: Float32Array) {
    if (!this.running) return;
    const w = this.writers[track];
    if (!w) return;
    // system audio can start late or pause during silence (loopback delivers nothing) → pad to the mic timeline
    if (track === 'system' && this.frames.system < this.frames.mic - 16000) {
      const gap = this.frames.mic - this.frames.system;
      w.pad(this.frames.mic);
      this.segs.system?.feed(new Float32Array(gap));
      this.frames.system = this.frames.mic;
    }
    w.write(s);
    this.frames[track] += s.length;
    this.segs[track]?.feed(s);
  }

  get seconds() { return this.frames.mic / 16000; }

  async stop(): Promise<{ mic: boolean; system: boolean; seconds: number }> {
    if (!this.running) return { ...this.tracks, seconds: this.seconds };
    try { await this.backend.stop(); } catch { /* */ }
    this.running = false;
    this.backend.off('chunk', this.onChunk);
    this.backend.off('level', this.onLevel);
    this.backend.off('error', this.onError);
    for (const t of ['mic', 'system'] as Track[]) this.segs[t]?.flush();
    if (this.writers.system && this.frames.system > 0) this.writers.system.pad(this.frames.mic);
    this.writers.mic?.close(); this.writers.system?.close();
    // a system track that never received a sample is not a track
    const system = this.tracks.system && this.frames.system > 0;
    this.writers = {};
    return { mic: this.tracks.mic && this.frames.mic > 0, system, seconds: this.seconds };
  }
}

/** test double: plays given samples in 100 ms blocks (fast) */
export class MockCapture extends EventEmitter implements CaptureBackend {
  constructor(private data: Partial<Record<Track, Float32Array>>, private opts: { failMic?: boolean; failSystem?: boolean } = {}) { super(); }
  async start(o: { micDeviceId: string; systemAudio: boolean }): Promise<CaptureStartResult> {
    if (this.opts.failMic) return { mic: false, system: false, error: 'NotAllowedError' };
    const system = o.systemAudio && !this.opts.failSystem && !!this.data.system;
    const tracks: Track[] = system ? ['mic', 'system'] : ['mic'];
    const n = Math.max(...tracks.map((t) => this.data[t]?.length ?? 0));
    queueMicrotask(() => {
      for (let i = 0; i < n; i += 1600) {
        for (const t of tracks) {
          const d = this.data[t];
          if (d && i < d.length) this.emit('chunk', t, d.subarray(i, Math.min(d.length, i + 1600)));
        }
      }
    });
    return { mic: true, system };
  }
  async stop() { await new Promise((r) => setTimeout(r, 5)); }
}
