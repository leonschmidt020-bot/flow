// Chunking for long recordings. Two paths:
//  • live (while recording): an energy-based segmenter cuts the stream at ~0.7 s pauses (LiveSegmenter.swift port)
//  • final: Silero VAD over the whole track → speech regions → ≤ 25 s chunks cut in pauses (planChunks from the
//    dictation engine) → each chunk decoded with token times, shifted by the chunk start.
// The VAD loop yields to the event loop every few seconds of audio, so the Electron main process stays responsive.
import { planChunks, SAMPLE_RATE, type RawDecode } from '../asr/engine';
import { wordsFromDecode } from './merge';
import type { Word } from './types';

export class LiveSegmenter {
  private readonly frame = 480; // 30 ms
  private pending: number[] = [];
  private current: number[] = [];
  private currentStart = 0;
  private position = 0;
  private silenceFrames = 0;
  private speechFrames = 0;
  private noiseFloor = 0.004;
  constructor(private onSegment: (startSec: number, samples: Float32Array) => void, private sr = SAMPLE_RATE) {}

  feed(s: Float32Array) {
    for (let i = 0; i < s.length; i++) this.pending.push(s[i]!);
    while (this.pending.length >= this.frame) {
      const f = this.pending.splice(0, this.frame);
      let sum = 0;
      for (const x of f) sum += x * x;
      const rms = Math.sqrt(sum / this.frame);
      const speech = rms > Math.max(0.006, this.noiseFloor * 3);
      if (!speech) this.noiseFloor = this.noiseFloor * 0.995 + rms * 0.005;
      if (speech) {
        if (this.current.length === 0) this.currentStart = Math.max(0, this.position - this.frame * 8);
        this.silenceFrames = 0; this.speechFrames++;
        for (const x of f) this.current.push(x);
      } else if (this.current.length > 0) {
        this.silenceFrames++;
        for (const x of f) this.current.push(x);
        if (this.silenceFrames >= 23) this.flush(); // ~0.7 s pause
      }
      if (this.current.length > this.sr * 25) this.flush();
      this.position += this.frame;
    }
  }

  flush() {
    if (this.speechFrames >= 10 && this.current.length > this.sr / 2) this.onSegment(this.currentStart / this.sr, Float32Array.from(this.current));
    this.current = []; this.silenceFrames = 0; this.speechFrames = 0;
  }
}

/** minimal VAD surface (sherpa-onnx Vad) – injectable for tests */
export interface VadLike {
  acceptWaveform(s: Float32Array): void;
  isEmpty(): boolean;
  front(copy?: boolean): { start: number; samples: Float32Array | number[] };
  pop(): void;
  flush(): void;
}

const tick = () => new Promise<void>((r) => setImmediate(r));

/** speech regions [start, length] in samples; yields every ~4 s of audio */
export async function vadRegions(vad: VadLike, samples: Float32Array, onProgress?: (p: number) => void): Promise<{ start: number; length: number }[]> {
  const out: { start: number; length: number }[] = [];
  const W = 512;
  const drain = () => { while (!vad.isEmpty()) { const seg = vad.front(false); out.push({ start: seg.start, length: seg.samples.length }); vad.pop(); } };
  let sinceYield = 0;
  for (let i = 0; i + W <= samples.length; i += W) {
    vad.acceptWaveform(samples.subarray(i, i + W));
    drain();
    sinceYield += W;
    if (sinceYield >= SAMPLE_RATE * 4) { sinceYield = 0; onProgress?.(i / samples.length); await tick(); }
  }
  vad.flush();
  drain();
  return out;
}

/** [a, b) sample ranges to decode */
export function planMeetingChunks(total: number, regions: { start: number; length: number }[]): [number, number][] {
  return planChunks(total, regions);
}

/**
 * Long-form transcription with word times: VAD → chunks → decodeRaw per chunk. `onProgress` 0…1
 * (VAD = first 10 %, decoding = the rest, by audio length).
 */
export async function transcribeLong(samples: Float32Array, deps: { vad: VadLike; decode: (s: Float32Array) => Promise<RawDecode> },
  onProgress?: (p: number) => void, signal?: AbortSignal): Promise<Word[]> {
  const regions = await vadRegions(deps.vad, samples, (p) => onProgress?.(p * 0.1));
  const chunks = planMeetingChunks(samples.length, regions);
  const total = chunks.reduce((n, [a, b]) => n + (b - a), 0) || 1;
  let done = 0;
  const words: Word[] = [];
  for (const [a, b] of chunks) {
    if (signal?.aborted) throw new Error('aborted');
    const r = await deps.decode(samples.subarray(a, b));
    words.push(...wordsFromDecode(r, a / SAMPLE_RATE, (b - a) / SAMPLE_RATE));
    done += b - a;
    onProgress?.(0.1 + 0.9 * (done / total));
  }
  return words;
}
