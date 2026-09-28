// Notetaker integration test (real models, no Electron, no microphone, no clipboard):
// imports test/fixtures/meeting/two_voices.wav (two macOS voices taking turns) through the real MeetingController –
// WAV decode → Parakeet with token times → sherpa-onnx diarization (pyannote + TitaNet) → speaker segments →
// „Prompt für Agent“ package – and checks: exactly 2 speakers, turns attributed correctly, WER, package files.
//   npm run test:meeting        (models in FLOW_MODEL_CACHE, default windows/.cache/models; downloaded if missing)
import { mkdtempSync, readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ensureModel } from '../src/asr/download';
import { createEngine } from '../src/asr/engine';
import { applyRules } from '../src/core/textCleaner';
import { wer } from '../src/core/wer';
import { MeetingController } from '../src/meeting/controller';
import { ensureDiarizationModels } from '../src/meeting/diarizer';
import { MockCapture } from '../src/meeting/recorder';
import { PACKAGE_DIR } from '../src/meeting/types';

const ROOT = path.resolve(__dirname, '..');
const cache = process.env.FLOW_MODEL_CACHE ?? path.join(ROOT, '.cache', 'models');
const MIN_TURN_ACC = Number(process.env.FLOW_DIAR_MIN ?? 0.85);
const MAX_WER = Number(process.env.FLOW_MEETING_WER ?? 0.15);

async function main() {
  const fx = path.join(ROOT, 'test', 'fixtures', 'meeting');
  const truth = JSON.parse(readFileSync(path.join(fx, 'two_voices.json'), 'utf8')) as { speakers: number; turns: { speaker: string; start: number; end: number; text: string }[] };
  console.log(`Meeting test · cache ${cache} · ${process.platform}-${process.arch}`);
  await ensureModel(cache, 'parakeet-v3', (p) => { if (p.phase !== 'download') console.log(`  asr ${p.phase}`); });
  await ensureDiarizationModels(cache, (p) => { if (p.phase !== 'download') console.log(`  diarization ${p.phase}`); });
  const engine = await createEngine({ root: cache, model: 'parakeet-v3' });
  const root = mkdtempSync(path.join(os.tmpdir(), 'flow-meeting-it-'));
  let clipboard = '';
  const toasts: string[] = [];
  const c = new MeetingController({
    root, modelsRoot: cache, platform: process.platform, locale: () => 'de', micDeviceId: () => '',
    clean: (t) => applyRules(t, { removeFillers: true, voiceCommands: false, dictionary: [] }),
    asr: () => engine, waitAsr: async () => engine, capture: () => new MockCapture({}),
    copyText: (t) => { clipboard = t; },
    pill: { meeting: () => {}, task: () => {}, card: () => {}, toast: (t) => toasts.push(t), level: () => {} },
    log: (...a) => { if (process.env.FLOW_DEBUG) console.log('   ·', ...a); },
  });
  c.init();
  const t0 = Date.now();
  const r = c.importFile(path.join(fx, 'two_voices.wav'));
  if (!r.ok) throw new Error('import refused');
  await c.idle();
  const ms = Date.now() - t0;
  const m = c.store.meetings[0]!;
  if (m.status !== 'done') throw new Error(`status ${m.status}: ${m.progressNote}`);

  // speakers
  const keys = [...new Set(m.segments.map((s) => s.speaker))];
  // per truth turn: the speaker label covering most of it; the mapping A/B → S? must be consistent
  const label = (t: { start: number; end: number }) => {
    const acc = new Map<string, number>();
    for (const s of m.segments) { const o = Math.min(t.end, s.end) - Math.max(t.start, s.start); if (o > 0) acc.set(s.speaker, (acc.get(s.speaker) ?? 0) + o); }
    return [...acc].sort((a, b) => b[1] - a[1])[0]?.[0] ?? '?';
  };
  const labels = truth.turns.map(label);
  const map = new Map<string, string>();
  for (let i = 0; i < truth.turns.length; i++) if (!map.has(truth.turns[i]!.speaker)) map.set(truth.turns[i]!.speaker, labels[i]!);
  const correct = truth.turns.filter((t, i) => map.get(t.speaker) === labels[i]).length;
  const distinct = new Set(map.values()).size === map.size;
  const turnAcc = distinct ? correct / truth.turns.length : 0;
  // time-weighted: speech time of each truth turn covered by a segment of the right speaker
  let good = 0, total = 0;
  for (const t of truth.turns) {
    total += t.end - t.start;
    for (const s of m.segments) if (s.speaker === map.get(t.speaker)) good += Math.max(0, Math.min(t.end, s.end) - Math.max(t.start, s.start));
  }
  const timeAcc = good / total;
  const hyp = m.segments.map((s) => s.text).join(' ');
  const ref = truth.turns.map((t) => t.text).join(' ');
  const e = wer(ref, hyp);

  // package + prompt
  const pr = await c.copyPrompt(m.id);
  const dir = path.join(root, m.id, PACKAGE_DIR);
  const tr = readFileSync(path.join(dir, 'transkript.md'), 'utf8');
  const pkgOk = pr.ok && existsSync(path.join(dir, 'meeting.md')) && tr.trimEnd().endsWith('— Ende des Transkripts —')
    && clipboard.includes(path.join(dir, 'transkript.md')) && clipboard.includes(`${m.segments.length} Abschnitte`) && toasts.includes('Prompt kopiert ✓');

  console.log(`\n  processed ${(m.duration).toFixed(1)} s of audio in ${ms} ms (RTF ${(ms / 1000 / m.duration).toFixed(3)})`);
  console.log(`  speakers found: ${keys.length} (${keys.join(', ')}) · expected ${truth.speakers}`);
  console.log(`  turns attributed correctly: ${correct}/${truth.turns.length} (${labels.join(' ')}) · time-weighted ${(timeAcc * 100).toFixed(1)} %`);
  console.log(`  WER ${(e * 100).toFixed(1)} %`);
  for (const s of m.segments) console.log(`    [${s.start.toFixed(1).padStart(5)}–${s.end.toFixed(1).padStart(5)}] ${s.speaker}: ${s.text}`);
  console.log(`  package: ${pkgOk ? 'ok' : 'FAILED'} · prompt ${clipboard.length} chars`);
  mkdirSync(path.join(ROOT, '.cache'), { recursive: true });
  writeFileSync(path.join(ROOT, '.cache', 'meeting-results.json'), JSON.stringify({ platform: `${process.platform}-${process.arch}`, speakers: keys.length, turnAcc, timeAcc, wer: e, ms, segments: m.segments, prompt: clipboard }, null, 1));
  const ok = keys.length === truth.speakers && turnAcc >= MIN_TURN_ACC && e <= MAX_WER && pkgOk;
  console.log(ok ? '  PASS' : `  FAIL (need ${truth.speakers} speakers, turn accuracy ≥ ${MIN_TURN_ACC}, WER ≤ ${MAX_WER}, package ok)`);
  c.dispose();
  process.exit(ok ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
