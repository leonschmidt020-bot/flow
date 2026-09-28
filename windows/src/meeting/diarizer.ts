// Speaker diarization with sherpa-onnx (offline): pyannote segmentation-3.0 + NeMo TitaNet-small speaker embeddings,
// clustered by sherpa-onnx. Both models are official sherpa-onnx GitHub release assets, downloaded on first use with
// size + sha256 check (same downloader as the speech model). Plain Node (no Electron) so the integration test uses it.
//
// Choice of embedding model (27.09.2026, test/fixtures/meeting/two_voices.wav, 2 voices, 8 turns): TitaNet-small,
// 3D-Speaker ERes2Net-base and CAM++ zh_en found 2 speakers with every turn right for clustering thresholds 0.3–0.9;
// CAM++ VoxCeleb (en) split the same audio into 3–6 speakers. TitaNet-small (40 MB, CC-BY-4.0 like Parakeet) is
// trained on English + multilingual VoxCeleb data and was the most threshold-robust → default.
import { existsSync, promises as fsp } from 'node:fs';
import path from 'node:path';
import { downloadFile, extractTarBz2, type OnProgress } from '../asr/download';
import { loadSherpa } from '../asr/engine';
import type { Turn } from './types';

const SEG_BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/';
const EMB_BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/'; // sic (upstream tag name)

export const DIARIZATION = {
  segmentation: {
    label: 'pyannote segmentation-3.0 (sherpa-onnx)',
    url: SEG_BASE + 'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
    archive: 'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
    dir: 'sherpa-onnx-pyannote-segmentation-3-0',
    file: 'model.onnx',
    size: 6958444,
    // no GitHub digest for this asset – sha256 computed from the official asset on 2026-09-27
    sha256: '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488',
    license: 'MIT (pyannote.audio)',
  },
  embedding: {
    label: 'NVIDIA NeMo TitaNet small (sherpa-onnx)',
    url: EMB_BASE + 'nemo_en_titanet_small.onnx',
    file: 'nemo_en_titanet_small.onnx',
    size: 40257283,
    // from the release's checksum.txt
    sha256: 'ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e',
    license: 'CC-BY-4.0',
  },
  /** sherpa-onnx fast clustering: larger = fewer speakers */
  threshold: 0.5,
} as const;

export const diarizationFiles = (root: string) => ({
  segmentation: path.join(root, DIARIZATION.segmentation.dir, DIARIZATION.segmentation.file),
  embedding: path.join(root, DIARIZATION.embedding.file),
});

export function isDiarizationReady(root: string): boolean {
  const f = diarizationFiles(root);
  return existsSync(f.segmentation) && existsSync(f.embedding);
}

/** download + extract what is missing (idempotent, resumable, checksummed) */
export async function ensureDiarizationModels(root: string, onProgress?: OnProgress, signal?: AbortSignal): Promise<void> {
  await fsp.mkdir(root, { recursive: true });
  const f = diarizationFiles(root);
  const S = DIARIZATION.segmentation, E = DIARIZATION.embedding;
  const total = S.size + E.size;
  if (!existsSync(f.embedding)) {
    await downloadFile(E.url, f.embedding, { sha256: E.sha256, size: E.size, signal,
      onProgress: (p) => onProgress?.({ ...p, total, received: p.received }) });
  }
  if (!existsSync(f.segmentation)) {
    const archive = path.join(root, 'downloads', S.archive);
    if (!existsSync(archive)) await downloadFile(S.url, archive, { sha256: S.sha256, size: S.size, signal,
      onProgress: (p) => onProgress?.({ ...p, total, received: E.size + p.received }) });
    onProgress?.({ phase: 'extract', received: total, total, bytesPerSec: 0 });
    const tmp = path.join(root, `.extract-seg-${process.pid}`);
    await fsp.rm(tmp, { recursive: true, force: true });
    await fsp.mkdir(tmp, { recursive: true });
    try {
      await extractTarBz2(archive, tmp);
      const src = path.join(tmp, S.dir);
      if (!existsSync(path.join(src, S.file))) throw new Error(`archive is missing ${S.file}`);
      await fsp.rm(path.join(root, S.dir), { recursive: true, force: true });
      await fsp.rename(src, path.join(root, S.dir));
    } finally {
      await fsp.rm(tmp, { recursive: true, force: true });
    }
    await fsp.rm(archive, { force: true });
  }
  onProgress?.({ phase: 'done', received: total, total, bytesPerSec: 0 });
}

export interface Diarizer {
  /** turns in seconds; `onProgress` 0…1 */
  diarize(samples: Float32Array, onProgress?: (p: number) => void): Promise<Turn[]>;
}

/** sherpa-onnx implementation; runs off the main thread (native async worker) */
export function createDiarizer(root: string, o: { threshold?: number; numSpeakers?: number; numThreads?: number } = {}): Diarizer {
  const sherpa = loadSherpa();
  const f = diarizationFiles(root);
  const sd = new sherpa.OfflineSpeakerDiarization({
    segmentation: { pyannote: { model: f.segmentation }, numThreads: o.numThreads ?? 2, debug: 0 },
    embedding: { model: f.embedding, numThreads: o.numThreads ?? 2, debug: 0 },
    clustering: { numClusters: o.numSpeakers ?? -1, threshold: o.threshold ?? DIARIZATION.threshold },
    minDurationOn: 0.3,
    minDurationOff: 0.5,
  });
  // the JS wrapper only exposes the blocking process(); the addon has the async variant (progress: done, total)
  const addon = require('sherpa-onnx-node/addon.js');
  return {
    async diarize(samples, onProgress) {
      if (samples.length < 16000) return [];
      const run = addon.offlineSpeakerDiarizationProcessAsync;
      const res: { start: number; end: number; speaker: number }[] = typeof run === 'function'
        ? await run(sd.handle, samples, (done: number, total: number) => { onProgress?.(total ? done / total : 0); return 0; })
        : sd.process(samples);
      return res.map((r) => ({ speaker: r.speaker, start: r.start, end: r.end })).sort((a, b) => a.start - b.start);
    },
  };
}
