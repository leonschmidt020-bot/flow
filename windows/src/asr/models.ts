// Model manifest – the ONE place that knows where speech models come from.
// All assets are official sherpa-onnx GitHub release assets (k2-fsa/sherpa-onnx, tag "asr-models").
// sha256 values are taken from the GitHub release asset digests (or computed once, see README).

const BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/';

export type ModelId = 'parakeet-v3' | 'whisper-turbo';

export interface ArchiveModel {
  id: ModelId;
  label: string;
  url: string;
  archive: string;
  /** folder inside the archive */
  dir: string;
  size: number;
  sha256: string | null;
  kind: 'transducer' | 'whisper';
  files: Record<string, string>;
  /** languages the model can transcribe */
  languages: string;
}

export const MODELS: Record<ModelId, ArchiveModel> = {
  'parakeet-v3': {
    id: 'parakeet-v3',
    label: 'NVIDIA Parakeet TDT 0.6B v3 (int8)',
    url: BASE + 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    archive: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    dir: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    size: 487170055,
    sha256: '5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf',
    kind: 'transducer',
    files: { encoder: 'encoder.int8.onnx', decoder: 'decoder.int8.onnx', joiner: 'joiner.int8.onnx', tokens: 'tokens.txt' },
    languages: '25 European languages incl. German + English (automatic)',
  },
  'whisper-turbo': {
    id: 'whisper-turbo',
    label: 'OpenAI Whisper large-v3-turbo (int8)',
    url: BASE + 'sherpa-onnx-whisper-turbo.tar.bz2',
    archive: 'sherpa-onnx-whisper-turbo.tar.bz2',
    dir: 'sherpa-onnx-whisper-turbo',
    size: 563790207,
    // no GitHub digest for this (2024) asset – sha256 computed from the official asset on 2026-09-27
    sha256: 'b11acbbcd660b44a8e0df33724feb5aaa709cf65668f2823d59f656312544f22',
    kind: 'whisper',
    files: { encoder: 'turbo-encoder.int8.onnx', decoder: 'turbo-decoder.int8.onnx', tokens: 'turbo-tokens.txt' },
    languages: '99 languages, language can be fixed (de/en)',
  },
};

export const VAD = {
  url: BASE + 'silero_vad.onnx',
  file: 'silero_vad.onnx',
  size: 643854,
  sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
};

export const DEFAULT_MODEL: ModelId = 'parakeet-v3';
