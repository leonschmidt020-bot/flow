import { describe, expect, it } from 'vitest';
import { energySegments, measureLevel, normalise } from '../../src/asr/engine';
import { diag } from '../../src/main/dictation';

const sr = 16000;
function tone(sec: number, amp: number, at = 0, total = sec) {
  const s = new Float32Array(Math.round(total * sr));
  for (let i = Math.round(at * sr); i < Math.round((at + sec) * sr) && i < s.length; i++) s[i] = amp * Math.sin((2 * Math.PI * 220 * i) / sr);
  return s;
}

describe('input level (quiet laptop array mics)', () => {
  it('measures peak and RMS in dBFS', () => {
    const l = measureLevel(tone(1, 0.1));
    expect(l.peakDb).toBeCloseTo(-20, 0);
    expect(l.rmsDb).toBeCloseTo(-23, 0);
  });
  it('lifts a quiet recording to about −6 dBFS, at most +30 dB', () => {
    const q = normalise(tone(1, Math.pow(10, -25 / 20), 0.5, 2));
    expect(q.gain).toBeGreaterThan(8);
    expect(measureLevel(q.out).peakDb).toBeCloseTo(-6, 0);
    const veryQuiet = normalise(tone(1, 0.003, 0.5, 2));
    expect(veryQuiet.gain).toBeCloseTo(31.6, 1);
  });
  it('leaves loud recordings and near-silence untouched', () => {
    expect(normalise(tone(1, 0.7)).gain).toBe(1);
    const sil = tone(1, 0.0005);
    expect(normalise(sil).out).toBe(sil);
  });
  it('energy spans find speech the VAD might miss – also right at t = 0', () => {
    const s = tone(1.2, 0.02, 0, 3);
    const spans = energySegments(s);
    expect(spans.length).toBe(1);
    expect(spans[0]!.start).toBe(0);
    expect(spans[0]!.length / sr).toBeGreaterThan(1.1);
    expect(energySegments(new Float32Array(sr * 2))).toEqual([]);
  });
  it('log line diagnostics carry level, speech and mic start (no content)', () => {
    const d = diag({ speechSec: 2.34, peakDb: -31.2, rmsDb: -44, gain: 18, fallback: true }, { lastStart: { latencyMs: 640, warm: false } });
    expect(d).toBe('speech 2.3 s, level peak -31.2 / rms -44 dBFS (×18.0), no-vad, start 640 ms cold');
  });
});

describe('Win32 calls: no JS booleans for BOOL/int parameters (koffi throws, the catch hid it: „app ?“)', () => {
  it('no koffi call passes true/false', async () => {
    const { readFileSync, readdirSync, statSync } = await import('node:fs');
    const path = await import('node:path');
    const files: string[] = [];
    const walk = (d: string) => { for (const f of readdirSync(d)) { const p = path.join(d, f); if (statSync(p).isDirectory()) walk(p); else if (p.endsWith('.ts')) files.push(p); } };
    walk(path.resolve(__dirname, '../../src'));
    const bad: string[] = [];
    for (const f of files) {
      const src = readFileSync(f, 'utf8');
      for (const m of src.matchAll(/\b(?:a|f|api)\.(OpenProcess|AttachThreadInput|ShowWindow|SetWindowPos|EnableWindow|BringWindowToTop|PostMessageW|SendMessageW)\(([^)]*)\)/g)) {
        if (/\b(true|false)\b/.test(m[2]!)) bad.push(`${path.basename(f)}: ${m[0]}`);
      }
    }
    expect(bad).toEqual([]);
  });
});

describe('normalisation ignores pure noise', () => {
  it('white noise at −34 dBFS is not lifted', () => {
    let seed = 3;
    const n = new Float32Array(3 * sr);
    for (let i = 0; i < n.length; i++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; n[i] = ((seed / 0x7fffffff) - 0.5) * 0.04; }
    expect(normalise(n).gain).toBe(1);
    expect(energySegments(n)).toEqual([]);
  });
});
