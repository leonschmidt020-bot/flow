#!/usr/bin/env node
// Generates the synthetic two-speaker meeting for the diarization test with macOS `say`:
// two clearly different voices take turns (0.7 s pause between turns) → test/fixtures/meeting/two_voices.wav
// (16 kHz mono PCM16) + two_voices.json (ground truth: who spoke when, and what). The WAV is committed, so CI on
// Windows uses the very same audio. macOS only. Neutral content, no personal data.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') { console.error('make-meeting-fixture: needs macOS (say + afconvert)'); process.exit(1); }
const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'test', 'fixtures', 'meeting');
mkdirSync(dir, { recursive: true });

const A = 'Anna';                           // female voice
const B = 'Reed (Deutsch (Deutschland))';   // male voice
const turns = [
  [A, 'Guten Morgen zusammen. Heute sprechen wir über den Umzug des Büros und den neuen Zeitplan.'],
  [B, 'Danke. Der Umzug ist für den zwölften Oktober geplant, die Kisten kommen eine Woche vorher.'],
  [A, 'Gut. Wer kümmert sich um die Drucker und das Netzwerk im neuen Gebäude?'],
  [B, 'Das übernimmt das Technikteam. Die Leitungen werden am Montag geprüft.'],
  [A, 'Und wie sieht es mit den Kosten aus? Bleiben wir im Budget?'],
  [B, 'Ja, wir liegen etwa fünf Prozent unter der Planung, weil die Möbel günstiger waren.'],
  [A, 'Sehr schön. Dann schicke ich heute Nachmittag die Einladung für die nächste Besprechung.'],
  [B, 'Perfekt, bis dahin sammle ich die offenen Fragen aus dem Team.'],
];

const SR = 16000;
const GAP = Math.round(0.7 * SR);
const LEAD = Math.round(0.5 * SR);
const readPcm16 = (f) => {
  const b = readFileSync(f);
  let off = 12;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4), size = b.readUInt32LE(off + 4);
    if (id === 'data') { const n = size / 2; const out = new Int16Array(n); for (let i = 0; i < n; i++) out[i] = b.readInt16LE(off + 8 + i * 2); return out; }
    off += 8 + size + (size % 2);
  }
  throw new Error('no data chunk');
};

const parts = [];
const truth = [];
let pos = LEAD;
parts.push(new Int16Array(LEAD));
turns.forEach(([voice, text], i) => {
  const aiff = path.join(dir, `_t${i}.aiff`), wav = path.join(dir, `_t${i}.wav`);
  execFileSync('say', ['-v', voice, '-r', '180', '-o', aiff, text]);
  execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', aiff, wav]);
  const pcm = readPcm16(wav);
  rmSync(aiff); rmSync(wav);
  truth.push({ speaker: voice === A ? 'A' : 'B', voice, start: +(pos / SR).toFixed(3), end: +((pos + pcm.length) / SR).toFixed(3), text });
  parts.push(pcm, new Int16Array(GAP));
  pos += pcm.length + GAP;
});
const total = parts.reduce((n, p) => n + p.length, 0);
const buf = Buffer.alloc(44 + total * 2);
buf.write('RIFF', 0); buf.writeUInt32LE(36 + total * 2, 4); buf.write('WAVE', 8);
buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
buf.write('data', 36); buf.writeUInt32LE(total * 2, 40);
let o = 44;
for (const p of parts) for (let i = 0; i < p.length; i++, o += 2) buf.writeInt16LE(p[i], o);
writeFileSync(path.join(dir, 'two_voices.wav'), buf);
writeFileSync(path.join(dir, 'two_voices.json'), JSON.stringify({
  generator: 'macOS say + afconvert (16 kHz mono PCM16), scripts/make-meeting-fixture.mjs',
  durationSec: +(total / SR).toFixed(3), speakers: 2, turns: truth,
}, null, 1));
// the same audio as AAC/m4a – exercises the import decoders (ffmpeg or Electron's built-in one) in the app smoke test
execFileSync('afconvert', ['-f', 'm4af', '-d', 'aac', path.join(dir, 'two_voices.wav'), path.join(dir, 'two_voices.m4a')]);
console.log(`✓ two_voices.wav + .m4a · ${(total / SR).toFixed(1)} s · ${truth.length} turns`);
