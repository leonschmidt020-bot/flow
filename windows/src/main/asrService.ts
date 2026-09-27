// Owns model download + the loaded recognizer; reports status to the UI.
import { EventEmitter } from 'node:events';
import { ensureModel, isModelReady } from '../asr/download';
import { createEngine, type Engine } from '../asr/engine';
import type { ModelId } from '../asr/models';
import { log } from './log';

export type AsrStatus = 'missing' | 'downloading' | 'verifying' | 'extracting' | 'loading' | 'ready' | 'error';
export interface AsrState { model: ModelId; status: AsrStatus; progress: number; bytesPerSec: number; error: string; installed: Record<ModelId, boolean> }

export class AsrService extends EventEmitter {
  private engine: Engine | null = null;
  private job: Promise<void> | null = null;
  private abort: AbortController | null = null;
  state: AsrState;

  constructor(private root: string, model: ModelId) {
    super();
    this.state = { model, status: 'missing', progress: 0, bytesPerSec: 0, error: '', installed: this.installed() };
  }

  private installed(): Record<ModelId, boolean> {
    return { 'parakeet-v3': isModelReady(this.root, 'parakeet-v3'), 'whisper-turbo': isModelReady(this.root, 'whisper-turbo') };
  }
  private set(p: Partial<AsrState>) {
    this.state = { ...this.state, ...p, installed: this.installed() };
    this.emit('change', this.state);
  }

  /** an engine is usable (possibly the previous model while a new one downloads) */
  get ready() { return !!this.engine; }
  getEngine(): Engine | null { return this.engine; }

  /** load if installed; download only when `download` is true */
  async start(model: ModelId, download: boolean): Promise<void> {
    if (this.job && this.state.model === model) return this.job;
    this.abort?.abort();
    // the old engine keeps working until the new one is loaded
    this.set({ model, status: isModelReady(this.root, model) ? 'loading' : 'missing', progress: 0, error: '' });
    if (!isModelReady(this.root, model) && !download) return;
    const ac = new AbortController();
    this.abort = ac;
    this.job = (async () => {
      try {
        await ensureModel(this.root, model, (p) => {
          if (ac.signal.aborted) return;
          if (p.phase === 'download') this.set({ status: 'downloading', progress: p.total ? p.received / p.total : 0, bytesPerSec: p.bytesPerSec });
          else if (p.phase === 'verify') this.set({ status: 'verifying', progress: 1 });
          else if (p.phase === 'extract') this.set({ status: 'extracting', progress: 1 });
        }, ac.signal);
        if (ac.signal.aborted) return;
        this.set({ status: 'loading' });
        const t0 = Date.now();
        const eng = await createEngine({ root: this.root, model });
        if (ac.signal.aborted) { eng.dispose(); return; }
        this.engine?.dispose();
        this.engine = eng;
        log(`asr: ${model} loaded in ${Date.now() - t0} ms`);
        // warm-up: first inference allocates buffers
        await eng.transcribe(new Float32Array(16000)).catch(() => undefined);
        this.set({ status: 'ready', progress: 1, error: '' });
        this.emit('ready', model);
      } catch (e) {
        if (ac.signal.aborted) return;
        log('asr error', e);
        this.set({ status: 'error', error: e instanceof Error ? e.message : String(e) });
      } finally {
        if (this.abort === ac) this.job = null;
      }
    })();
    return this.job;
  }

  dispose() { this.abort?.abort(); this.engine?.dispose(); this.engine = null; }
}
