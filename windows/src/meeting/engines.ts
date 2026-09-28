// Glue to the native engines (plain Node – used by the controller and by scripts/test-meeting.ts).
import { vadPath } from '../asr/download';
import { loadSherpa, SAMPLE_RATE, type Engine } from '../asr/engine';
import { transcribeLong, type VadLike } from './chunking';
import type { Word } from './types';

/** Silero VAD tuned for meetings (slightly longer pauses than dictation, 20 s max per region) */
export function createVad(modelsRoot: string): VadLike {
  const sherpa = loadSherpa();
  return new sherpa.Vad({
    sileroVad: { model: vadPath(modelsRoot), threshold: 0.45, minSilenceDuration: 0.5, minSpeechDuration: 0.25, windowSize: 512, maxSpeechDuration: 20 },
    sampleRate: SAMPLE_RATE, debug: false, numThreads: 1,
  }, 60) as VadLike;
}

export function timedTranscriber(engine: Engine, modelsRoot: string) {
  return (samples: Float32Array, onProgress: (p: number) => void, signal?: AbortSignal): Promise<Word[]> =>
    transcribeLong(samples, { vad: createVad(modelsRoot), decode: (s) => engine.decodeRaw(s) }, onProgress, signal);
}
