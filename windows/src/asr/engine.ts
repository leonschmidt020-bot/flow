// Speech recognition with sherpa-onnx (offline Parakeet/Whisper) + Silero VAD for trimming/chunking.
import path from 'node:path';
import { MODELS, type ModelId } from './models';
import { modelFiles, vadPath } from './download';

// sherpa-onnx-node has no TS types
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Sherpa = any;
let sherpaMod: Sherpa | null = null;
export function loadSherpa(): Sherpa {

  if (!sherpaMod) sherpaMod = require('sherpa-onnx-node');
  return sherpaMod;
}

export type AsrLanguage = 'auto' | 'de' | 'en';
export const SAMPLE_RATE = 16000;

export interface TranscribeResult {
  text: string; ms: number; audioSec: number; speechSec: number; segments: number;
  /** input level before normalisation (dBFS) and the gain applied */
  peakDb?: number; rmsDb?: number; gain?: number;
  /** VAD missed speech the energy detector saw → decoded without VAD trimming */
  fallback?: boolean;
}

/** one decoder pass without VAD – tokens with start times (s, relative to the samples) where the model provides them */
export interface RawDecode { text: string; tokens: string[]; timestamps: number[]; durations: number[] }

export interface Engine {
  readonly model: ModelId;
  transcribe(samples: Float32Array, language?: AsrLanguage): Promise<TranscribeResult>;
  /** used by the meeting notetaker (long recordings are chunked there) */
  decodeRaw(samples: Float32Array): Promise<RawDecode>;
  dispose(): void;
}

export interface EngineOptions { root: string; model: ModelId; numThreads?: number; language?: AsrLanguage }

function recognizerConfig(o: EngineOptions, language: AsrLanguage) {
  const m = MODELS[o.model];
  const f = modelFiles(o.root, o.model);
  const threads = o.numThreads ?? defaultThreads();
  if (m.kind === 'transducer') {
    return {
      featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
      modelConfig: {
        transducer: { encoder: f.encoder, decoder: f.decoder, joiner: f.joiner },
        tokens: f.tokens, numThreads: threads, provider: 'cpu', debug: 0, modelType: 'nemo_transducer',
      },
      decodingMethod: 'greedy_search',
    };
  }
  return {
    featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
    modelConfig: {
      whisper: { encoder: f.encoder, decoder: f.decoder, language: language === 'auto' ? '' : language, task: 'transcribe', tailPaddings: -1 },
      tokens: f.tokens, numThreads: threads, provider: 'cpu', debug: 0,
    },
    decodingMethod: 'greedy_search',
  };
}

export function defaultThreads(): number {

  const n = require('node:os').availableParallelism?.() ?? 4;
  return Math.max(1, Math.min(4, n - 1));
}

/** VAD segments [startSample, samples] */
export function vadSegments(sherpa: Sherpa, vadModel: string, samples: Float32Array): { start: number; samples: Float32Array }[] {
  const vad = new sherpa.Vad({
    sileroVad: { model: vadModel, threshold: 0.45, minSilenceDuration: 0.5, minSpeechDuration: 0.2, windowSize: 512, maxSpeechDuration: 20 },
    sampleRate: SAMPLE_RATE, debug: false, numThreads: 1,
  }, 60);
  const out: { start: number; samples: Float32Array }[] = [];
  const W = 512;
  const drain = () => {
    while (!vad.isEmpty()) {
      const seg = vad.front(false);
      out.push({ start: seg.start, samples: new Float32Array(seg.samples) });
      vad.pop();
    }
  };
  for (let i = 0; i + W <= samples.length; i += W) {
    vad.acceptWaveform(samples.subarray(i, i + W));
    drain();
  }
  vad.flush();
  drain();
  return out;
}

/** level of a recording: peak and RMS (over the louder half of 20 ms frames, so pauses don't drag it down), dBFS */
export function measureLevel(s: Float32Array, sr = SAMPLE_RATE): { peak: number; rms: number; peakDb: number; rmsDb: number } {
  let peak = 0;
  for (let i = 0; i < s.length; i++) { const v = Math.abs(s[i]!); if (v > peak) peak = v; }
  const F = Math.round(0.02 * sr);
  const frames: number[] = [];
  for (let i = 0; i + F <= s.length; i += F) { let e = 0; for (let j = i; j < i + F; j++) e += s[j]! * s[j]!; frames.push(e / F); }
  frames.sort((a, b) => b - a);
  const top = frames.slice(0, Math.max(1, Math.ceil(frames.length / 2)));
  const rms = Math.sqrt(top.reduce((a, b) => a + b, 0) / Math.max(1, top.length));
  const db = (x: number) => Math.round(20 * Math.log10(Math.max(x, 1e-9)) * 10) / 10;
  return { peak, rms, peakDb: db(peak), rmsDb: db(rms) };
}

/** NORMALISE_* – quiet laptop array mics (often −30 … −40 dBFS) made the VAD drop words: lift the recording so its peak
 *  sits near −6 dBFS, at most +30 dB; near-silence (peak below −54 dBFS) stays untouched (no noise turned into „speech“). */
export const NORMALISE_TARGET = 0.5, NORMALISE_MAX_GAIN = 31.6, NORMALISE_FLOOR = 0.002;
export function normalise(s: Float32Array): { out: Float32Array; gain: number } {
  const { peak } = measureLevel(s);
  if (peak < NORMALISE_FLOOR || peak >= NORMALISE_TARGET) return { out: s, gain: 1 };
  // only noise, no speech (loudest 20 ms frame hardly above the floor) → don't turn room noise into „speech“
  if (dynamicRange(s) < 6) return { out: s, gain: 1 };
  const gain = Math.min(NORMALISE_MAX_GAIN, NORMALISE_TARGET / peak);
  if (gain < 1.05) return { out: s, gain: 1 };
  const out = new Float32Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = Math.max(-1, Math.min(1, s[i]! * gain));
  return { out, gain };
}

/** loudest 20 ms frame RMS ÷ noise floor (10th percentile) */
export function dynamicRange(s: Float32Array, sr = SAMPLE_RATE): number {
  const F = Math.round(0.02 * sr);
  const e: number[] = [];
  for (let i = 0; i + F <= s.length; i += F) { let x = 0; for (let j = i; j < i + F; j++) x += s[j]! * s[j]!; e.push(Math.sqrt(x / F)); }
  if (e.length < 5) return 1;
  e.sort((a, b) => a - b);
  return e[e.length - 1]! / Math.max(e[Math.floor(e.length * 0.1)]!, 1e-6);
}

/** seconds of audio with clear energy above the recording's own noise floor (20 ms frames) – speech the VAD should
 *  have found; also gives segments for the fallback when the VAD found (almost) nothing */
export function energySegments(s: Float32Array, sr = SAMPLE_RATE): { start: number; length: number }[] {
  const F = Math.round(0.02 * sr);
  const e: number[] = [];
  for (let i = 0; i + F <= s.length; i += F) { let x = 0; for (let j = i; j < i + F; j++) x += s[j]! * s[j]!; e.push(Math.sqrt(x / F)); }
  if (!e.length) return [];
  const sorted = [...e].sort((a, b) => a - b);
  const floor = Math.max(sorted[Math.floor(sorted.length * 0.1)]!, 0.0005);
  const thr = Math.max(floor * 4, 0.003);
  const out: { start: number; length: number }[] = [];
  let a = -1, quiet = 0;
  for (let k = 0; k <= e.length; k++) {
    const on = k < e.length && e[k]! > thr;
    if (on) { if (a < 0) a = k; quiet = 0; continue; }
    if (a < 0) continue;
    if (k < e.length && ++quiet < 15) continue; // bridge pauses < 0.3 s
    const end = k - (k < e.length ? quiet - 1 : 0);
    if ((end - a) * F >= 0.15 * sr) out.push({ start: a * F, length: (end - a) * F });
    a = -1; quiet = 0;
  }
  return out;
}

/**
 * Plan what to decode: silence trimmed; short dictations stay one piece (better context),
 * long ones are split at pauses into ≤ ~25 s chunks.
 */
export function planChunks(total: number, segs: { start: number; length: number }[], sr = SAMPLE_RATE): [number, number][] {
  if (segs.length === 0) return [];
  const pad = Math.round(0.35 * sr);
  const maxLen = 25 * sr;
  const chunks: [number, number][] = [];
  let a = Math.max(0, segs[0]!.start - pad);
  let lastEnd = segs[0]!.start + segs[0]!.length; // end of speech in the current chunk
  for (const s of segs.slice(1)) {
    const end = s.start + s.length;
    if (Math.min(total, end + pad) - a <= maxLen) { lastEnd = end; continue; }
    // split in the pause: never overlap (overlapping audio would be transcribed twice)
    const cut = Math.min(lastEnd + pad, Math.round((lastEnd + s.start) / 2));
    chunks.push([a, Math.max(cut, lastEnd)]);
    a = Math.max(cut, s.start - pad, lastEnd);
    lastEnd = end;
  }
  chunks.push([a, Math.min(total, lastEnd + pad)]);
  return chunks;
}

export async function createEngine(o: EngineOptions): Promise<Engine> {
  const sherpa = loadSherpa();
  let language: AsrLanguage = o.language ?? 'auto';
  const rec = await sherpa.OfflineRecognizer.createAsync(recognizerConfig(o, language));
  const vadModel = vadPath(o.root);
  const decodeFull = async (s: Float32Array) => {
    const stream = rec.createStream();
    stream.acceptWaveform({ samples: s, sampleRate: SAMPLE_RATE });
    return rec.decodeAsync(stream);
  };
  const decode = async (s: Float32Array): Promise<string> => String((await decodeFull(s))?.text ?? '').trim();
  return {
    model: o.model,
    async transcribe(samples, lang) {
      const t0 = Date.now();
      if (lang && lang !== language && MODELS[o.model].kind === 'whisper') {
        language = lang;
        rec.setConfig(recognizerConfig(o, language));
      }
      const lvl = measureLevel(samples);
      const { out: x, gain } = normalise(samples);
      const segs = vadSegments(sherpa, vadModel, x);
      const vadSpans = segs.map((s) => ({ start: s.start, length: s.samples.length }));
      const speechSec = segs.reduce((n, s) => n + s.samples.length, 0) / SAMPLE_RATE;
      // fallback: the VAD heard clearly less speech than there is energy (quiet/odd mics) → plan from the energy spans
      const energy = energySegments(x);
      const energySec = energy.reduce((n, s) => n + s.length, 0) / SAMPLE_RATE;
      const fallback = energySec >= 0.3 && speechSec < energySec * 0.5;
      const plan = planChunks(x.length, fallback ? energy : vadSpans);
      const parts: string[] = [];
      for (const [a, b] of plan) {
        const t = await decode(x.subarray(a, b));
        if (t) parts.push(t);
      }
      return {
        text: parts.join(' ').replace(/\s+/g, ' ').trim(), ms: Date.now() - t0, audioSec: samples.length / SAMPLE_RATE,
        speechSec: fallback ? energySec : speechSec, segments: plan.length, peakDb: lvl.peakDb, rmsDb: lvl.rmsDb, gain, fallback,
      };
    },
    async decodeRaw(samples) {
      const r = await decodeFull(samples);
      const arr = (v: unknown) => (Array.isArray(v) ? v : []);
      return { text: String(r?.text ?? '').trim(), tokens: arr(r?.tokens).map(String), timestamps: arr(r?.timestamps).map(Number), durations: arr(r?.durations).map(Number) };
    },
    dispose() { /* native handles are released by GC */ },
  };
}

export const modelRootDefault = (userData: string) => path.join(userData, 'models');
