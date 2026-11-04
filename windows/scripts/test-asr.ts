// Headless ASR test: downloads the model into a cache dir (resumable, checksummed) and transcribes the
// synthetic TTS WAVs in test/fixtures/asr. Fails if WER is above the limits. Runs on macOS and Windows (CI).
//   npm run test:asr                 (Parakeet v3, default)
//   FLOW_ASR_MODEL=whisper-turbo npm run test:asr
//   FLOW_MODEL_CACHE=<dir>           (default: windows/.cache/models)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { ensureModel } from '../src/asr/download';
import { createEngine, SAMPLE_RATE, type AsrLanguage } from '../src/asr/engine';
import { MODELS, type ModelId } from '../src/asr/models';
import { readWav } from '../src/asr/wav';
import { wer } from '../src/core/wer';

const ROOT = path.resolve(__dirname, '..');
const cache = process.env.FLOW_MODEL_CACHE ?? path.join(ROOT, '.cache', 'models');
const model = (process.env.FLOW_ASR_MODEL ?? 'parakeet-v3') as ModelId;
const LIMIT_AVG = Number(process.env.FLOW_WER_AVG ?? 0.12);
const LIMIT_ONE = Number(process.env.FLOW_WER_MAX ?? 0.25);
/** quiet + noisy: one sentence may lose a few more words (noise, not level, is the limit there) */
const LIMIT_HARD_ONE = Number(process.env.FLOW_WER_HARD_MAX ?? 0.35);

async function main() {
  if (!MODELS[model]) throw new Error(`unknown model ${model}`);
  console.log(`ASR test · model ${MODELS[model].label} · cache ${cache} · ${process.platform}-${process.arch}`);
  let lastPct = -1;
  await ensureModel(cache, model, (p) => {
    if (p.phase === 'download' && p.total) {
      const pct = Math.floor((p.received / p.total) * 100);
      if (pct >= lastPct + 10) { lastPct = pct; console.log(`  download ${pct} % (${(p.bytesPerSec / 1e6).toFixed(1)} MB/s)`); }
    } else if (p.phase !== 'download') console.log(`  ${p.phase}`);
  });
  const t0 = Date.now();
  const engine = await createEngine({ root: cache, model });
  console.log(`  model loaded in ${Date.now() - t0} ms`);
  const manifest = JSON.parse(readFileSync(path.join(ROOT, 'test', 'fixtures', 'asr', 'manifest.json'), 'utf8')) as {
    items: { id: string; lang: 'de' | 'en'; text: string }[];
  };
  const rows: { id: string; lang: string; wer: number; ms: number; audio: number; segments: number; text: string }[] = [];
  for (const it of manifest.items) {
    const w = readWav(path.join(ROOT, 'test', 'fixtures', 'asr', it.id + '.wav'));
    if (w.sampleRate !== SAMPLE_RATE) throw new Error(`${it.id}: expected 16 kHz`);
    // like a real dictation: 0.6 s silence before and after
    const pad = new Float32Array(Math.round(0.6 * SAMPLE_RATE));
    const s = new Float32Array(pad.length * 2 + w.samples.length);
    s.set(w.samples, pad.length);
    const lang: AsrLanguage = model === 'whisper-turbo' ? it.lang : 'auto';
    const r = await engine.transcribe(s, lang);
    const e = wer(it.text, r.text);
    rows.push({ id: it.id, lang: it.lang, wer: e, ms: r.ms, audio: r.audioSec, segments: r.segments, text: r.text });
    console.log(`  ${e <= LIMIT_ONE ? '✓' : '✗'} ${it.id.padEnd(18)} WER ${(e * 100).toFixed(1).padStart(5)} %  ${r.ms} ms for ${r.audioSec.toFixed(1)} s (${r.segments} chunk${r.segments === 1 ? '' : 's'})`);
    if (e > 0) console.log(`      → ${r.text}`);
  }
  // Hard cases (Windows laptops with array mics, 11/2026): very quiet input (peak −25 dBFS, faint noise floor) and speech
  // that starts right at t = 0 (the mic opened late) – the FIRST word must still be recognised.
  const hard: { id: string; wer: number; first: boolean; text: string; fallback: boolean }[] = [];
  const firstWord = (s: string) => (s.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean)[0] ?? '');
  for (const it of manifest.items) {
    const w = readWav(path.join(ROOT, 'test', 'fixtures', 'asr', it.id + '.wav'));
    let pk = 0; for (const v of w.samples) pk = Math.max(pk, Math.abs(v));
    const gain = Math.pow(10, -25 / 20) / Math.max(pk, 1e-6);
    const tail = Math.round(0.6 * SAMPLE_RATE);
    const s = new Float32Array(w.samples.length + tail);
    let seed = 11;
    for (let i = 0; i < s.length; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      s[i] = (i < w.samples.length ? w.samples[i]! * gain : 0) + ((seed / 0x7fffffff) - 0.5) * 0.0006; // white noise ≈ −75 dBFS RMS (SNR ≈ 35 dB – white noise costs Parakeet a few words)
    }
    const lang: AsrLanguage = model === 'whisper-turbo' ? it.lang : 'auto';
    const r = await engine.transcribe(s, lang);
    const e = wer(it.text, r.text);
    const fw = firstWord(it.text);
    const first = !!fw && firstWord(r.text) === fw;
    hard.push({ id: it.id, wer: e, first, text: r.text, fallback: !!r.fallback });
    console.log(`  ${e <= LIMIT_HARD_ONE && first ? '✓' : '✗'} leise+t0 ${it.id.padEnd(18)} WER ${(e * 100).toFixed(1).padStart(5)} %  erstes Wort ${first ? 'ok' : `FEHLT („${fw}“)`}${r.fallback ? ' · ohne VAD' : ''}`);
    if (e > 0 || !first) console.log(`      → ${r.text}`);
  }
  const hardAvg = hard.reduce((n, r) => n + r.wer, 0) / Math.max(1, hard.length);
  console.log(`  WER leise+t0 ${(hardAvg * 100).toFixed(1)} % · erstes Wort ${hard.filter((h) => h.first).length}/${hard.length}`);
  // silence + faint noise must give no text (VAD)
  const noise = new Float32Array(3 * SAMPLE_RATE);
  let seed = 7;
  for (let i = 0; i < noise.length; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; noise[i] = ((seed / 0x7fffffff) - 0.5) * 0.002; }
  const sil = await engine.transcribe(noise, 'auto');
  // louder room noise (peak ≈ −34 dBFS, a quiet laptop room): the level normalisation must not turn it into words
  const room = new Float32Array(3 * SAMPLE_RATE);
  for (let i = 0; i < room.length; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; room[i] = ((seed / 0x7fffffff) - 0.5) * 0.04; }
  const roomR = await engine.transcribe(room, 'auto');
  const silenceOk = sil.text === '' && roomR.text === '';
  console.log(`  ${sil.text === '' ? '✓' : '✗'} silence            → "${sil.text}"`);
  console.log(`  ${roomR.text === '' ? '✓' : '✗'} room noise −34 dB  → "${roomR.text}"${roomR.gain && roomR.gain > 1 ? ` (×${roomR.gain.toFixed(1)})` : ''}`);
  const by = (l: string) => rows.filter((r) => r.lang === l);
  const avg = (a: typeof rows) => a.reduce((n, r) => n + r.wer, 0) / Math.max(1, a.length);
  const de = avg(by('de')), en = avg(by('en'));
  const rtf = rows.reduce((n, r) => n + r.ms, 0) / 1000 / rows.reduce((n, r) => n + r.audio, 0);
  console.log(`\n  WER Deutsch ${(de * 100).toFixed(1)} % · English ${(en * 100).toFixed(1)} % · real-time factor ${rtf.toFixed(3)}`);
  mkdirSync(path.join(ROOT, '.cache'), { recursive: true });
  writeFileSync(path.join(ROOT, '.cache', `asr-results-${model}.json`), JSON.stringify({ model, platform: `${process.platform}-${process.arch}`, de, en, rtf, rows, hard, hardAvg, silence: sil.text }, null, 1));
  const hardOk = process.env.FLOW_ASR_HARD === '0' || (hardAvg <= LIMIT_AVG && hard.every((r) => r.wer <= LIMIT_HARD_ONE && r.first));
  const ok = silenceOk && hardOk && de <= LIMIT_AVG && en <= LIMIT_AVG && rows.every((r) => r.wer <= LIMIT_ONE);
  console.log(ok ? '  PASS' : `  FAIL (limits: avg ≤ ${LIMIT_AVG}, each ≤ ${LIMIT_ONE}, silence empty, quiet+t0: first word)`);
  engine.dispose();
  process.exit(ok ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
