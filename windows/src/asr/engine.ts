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

export interface TranscribeResult { text: string; ms: number; audioSec: number; speechSec: number; segments: number }

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
      const segs = vadSegments(sherpa, vadModel, samples);
      const plan = planChunks(samples.length, segs.map((s) => ({ start: s.start, length: s.samples.length })));
      const speechSec = segs.reduce((n, s) => n + s.samples.length, 0) / SAMPLE_RATE;
      const parts: string[] = [];
      for (const [a, b] of plan) {
        const t = await decode(samples.subarray(a, b));
        if (t) parts.push(t);
      }
      return { text: parts.join(' ').replace(/\s+/g, ' ').trim(), ms: Date.now() - t0, audioSec: samples.length / SAMPLE_RATE, speechSec, segments: plan.length };
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
