import { describe, expect, it } from 'vitest';
import { mkdtempSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { wer, normWords } from '../../src/core/wer';
import { planChunks } from '../../src/asr/engine';
import { downloadFile, ChecksumError } from '../../src/asr/download';
import { encodeWav16, parseWav } from '../../src/asr/wav';
import { MODELS, VAD } from '../../src/asr/models';

describe('WER', () => {
  it('normalises case, punctuation and number words', () => {
    expect(normWords('Um zehn Uhr, okay?')).toEqual(['um', '10', 'uhr', 'okay']);
    expect(wer('Das Meeting ist um zehn Uhr.', 'das meeting ist um 10 uhr')).toBe(0);
    expect(wer('a b c d', 'a x c')).toBe(0.5);
  });
});

describe('chunk planning (VAD)', () => {
  const sr = 16000;
  it('no speech → nothing to decode', () => expect(planChunks(sr * 3, [])).toEqual([]));
  it('short dictation stays one piece, silence trimmed with padding', () => {
    expect(planChunks(sr * 10, [{ start: sr * 2, length: sr * 1 }, { start: sr * 4, length: sr * 2 }])).toEqual([[sr * 2 - 5600, sr * 6 + 5600]]);
  });
  it('long dictation split at pauses into ≤ 25 s chunks', () => {
    const segs = Array.from({ length: 10 }, (_, i) => ({ start: i * 6 * sr, length: 5 * sr }));
    const plan = planChunks(60 * sr, segs);
    expect(plan.length).toBeGreaterThan(1);
    for (const [a, b] of plan) expect(b - a).toBeLessThanOrEqual(25 * sr + 8000);
    // no overlap, no speech lost
    for (let i = 1; i < plan.length; i++) expect(plan[i]![0]).toBeGreaterThanOrEqual(plan[i - 1]![1]);
    for (const sg of segs) expect(plan.some(([a, b]) => a <= sg.start && sg.start + sg.length <= b)).toBe(true);
  });
  it('back-to-back segments (VAD max length split) do not overlap', () => {
    const plan = planChunks(60 * sr, [{ start: 0, length: 20 * sr }, { start: 20 * sr, length: 20 * sr }, { start: 40 * sr, length: 10 * sr }]);
    for (let i = 1; i < plan.length; i++) expect(plan[i]![0]).toBeGreaterThanOrEqual(plan[i - 1]![1]);
    expect(plan[0]![0]).toBe(0);
  });
});

describe('WAV', () => {
  it('encode/parse round trip', () => {
    const s = new Float32Array([0, 0.5, -0.5, 0.25]);
    const w = parseWav(encodeWav16(s, 16000));
    expect(w.sampleRate).toBe(16000);
    expect(Array.from(w.samples).map((x) => Math.round(x * 100) / 100)).toEqual([0, 0.5, -0.5, 0.25]);
  });
});

describe('model manifest', () => {
  it('official sherpa-onnx release assets with checksums', () => {
    for (const m of Object.values(MODELS)) expect(m.url).toMatch(/^https:\/\/github\.com\/k2-fsa\/sherpa-onnx\/releases\/download\//);
    expect(MODELS['parakeet-v3'].sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(VAD.sha256).toMatch(/^[0-9a-f]{64}$/);
  });
});

// fake server for the downloader: supports Range, can fail mid-way
function fakeFetch(data: Buffer, o: { failAfter?: number; ignoreRange?: boolean } = {}) {
  let calls = 0;
  const ranges: string[] = [];
  const f = (async (_url: string, init?: { headers?: Record<string, string> }) => {
    calls++;
    const range = init?.headers?.Range;
    ranges.push(range ?? '');
    let start = 0;
    if (range && !o.ignoreRange) start = Number(/bytes=(\d+)-/.exec(range)![1]);
    let body = data.subarray(start);
    const failing = o.failAfter !== undefined && calls === 1;
    if (failing) body = body.subarray(0, o.failAfter);
    const pieces: Uint8Array[] = [];
    for (let i = 0; i < body.length; i += 10_000) pieces.push(new Uint8Array(body.subarray(i, i + 10_000)));
    const stream = new ReadableStream({
      async pull(c) {
        const next = pieces.shift();
        if (next) { c.enqueue(next); await new Promise((r) => setTimeout(r, 1)); return; }
        if (failing) c.error(new Error('connection reset')); else c.close();
      },
    });
    return new Response(stream, { status: start > 0 ? 206 : 200, headers: { 'content-length': String(data.length - start) } });
  }) as unknown as typeof fetch;
  return { f, get calls() { return calls; }, ranges };
}

describe('downloader', () => {
  const data = Buffer.from(Array.from({ length: 200_000 }, (_, i) => i % 251));
  const sha = createHash('sha256').update(data).digest('hex');
  it('resumes with a Range request after a broken connection and verifies sha256', async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-dl-'));
    const dest = path.join(dir, 'model.bin');
    const ff = fakeFetch(data, { failAfter: 70_000 });
    await downloadFile('https://example.invalid/model.bin', dest, { sha256: sha, size: data.length, fetchImpl: ff.f, retries: 2 });
    expect(readFileSync(dest).equals(data)).toBe(true);
    expect(ff.ranges[1]).toMatch(/^bytes=\d+-$/);
    expect(existsSync(dest + '.part')).toBe(false);
  });
  it('continues an existing .part file from a previous app run', async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-dl-'));
    const dest = path.join(dir, 'model.bin');
    writeFileSync(dest + '.part', data.subarray(0, 123_456));
    const ff = fakeFetch(data);
    await downloadFile('https://example.invalid/model.bin', dest, { sha256: sha, size: data.length, fetchImpl: ff.f });
    expect(ff.ranges[0]).toBe('bytes=123456-');
    expect(readFileSync(dest).equals(data)).toBe(true);
  });
  it('server ignoring Range (200) → restarts cleanly', async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-dl-'));
    const dest = path.join(dir, 'model.bin');
    writeFileSync(dest + '.part', data.subarray(0, 5000));
    const ff = fakeFetch(data, { ignoreRange: true });
    await downloadFile('https://example.invalid/model.bin', dest, { sha256: sha, size: data.length, fetchImpl: ff.f });
    expect(readFileSync(dest).equals(data)).toBe(true);
  });
  it('checksum mismatch → error, no file', async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-dl-'));
    const dest = path.join(dir, 'model.bin');
    const ff = fakeFetch(data);
    await expect(downloadFile('https://example.invalid/model.bin', dest, { sha256: '0'.repeat(64), size: data.length, fetchImpl: ff.f, retries: 0 }))
      .rejects.toBeInstanceOf(ChecksumError);
    expect(existsSync(dest)).toBe(false);
    expect(existsSync(dest + '.part')).toBe(false);
  });
});
