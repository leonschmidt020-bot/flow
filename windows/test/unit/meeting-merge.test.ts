// Diarization result → speaker segments, recogniser tokens → words, chunking of long audio, the processor logic.
import { describe, expect, it } from 'vitest';
import { assignWords, groupWords, mergeAdjacent, removeEcho, speakerKeyMap, speechSeconds, wordsFromDecode } from '../../src/meeting/merge';
import { LiveSegmenter, planMeetingChunks, transcribeLong, vadRegions, type VadLike } from '../../src/meeting/chunking';
import { processTracks, type ProcessDeps } from '../../src/meeting/processor';
import type { Segment, Turn, Word } from '../../src/meeting/types';

const w = (word: string, start: number, end = start + 0.3): Word => ({ word, start, end });
const seg = (speaker: string, start: number, end: number, text: string): Segment => ({ id: `${speaker}${start}`, speaker, start, end, text });

describe('tokens → words', () => {
  it('word pieces and punctuation glue to the previous word; times are shifted by the chunk start', () => {
    const r = { text: 'Guten Morgen, heute', tokens: [' G', 'uten', ' Mor', 'gen', ',', ' heute'], timestamps: [0.24, 0.56, 0.8, 1.04, 1.28, 1.36], durations: [0.32, 0.24, 0.24, 0.24, 0, 0.3] };
    const out = wordsFromDecode(r, 10, 2);
    expect(out.map((x) => x.word)).toEqual(['Guten', 'Morgen,', 'heute']);
    expect(out[0]!.start).toBeCloseTo(10.24);
    expect(out[0]!.end).toBeCloseTo(10.8);
    expect(out[1]!.start).toBeCloseTo(10.8);
    expect(out[2]!.end).toBeCloseTo(11.66);
  });
  it('SentencePiece "▁" marks and a first token without space', () => {
    const out = wordsFromDecode({ text: '', tokens: ['Hal', 'lo', '▁Welt'], timestamps: [0, 0.2, 0.5], durations: [] }, 0, 1);
    expect(out.map((x) => x.word)).toEqual(['Hallo', 'Welt']);
    expect(out[0]!.end).toBeCloseTo(0.5); // next token start when no durations
  });
  it('models without timestamps (Whisper): words spread evenly over the chunk', () => {
    const out = wordsFromDecode({ text: 'eins zwei drei vier', tokens: [], timestamps: [], durations: [] }, 5, 4);
    expect(out.map((x) => [x.word, x.start, x.end])).toEqual([['eins', 5, 6], ['zwei', 6, 7], ['drei', 7, 8], ['vier', 8, 9]]);
  });
});

describe('diarization turns → segments', () => {
  const turns: Turn[] = [{ speaker: 1, start: 0.5, end: 6 }, { speaker: 0, start: 6.8, end: 13 }, { speaker: 1, start: 14, end: 18 }];
  it('speaker ids are renamed S1, S2 … in order of first appearance', () => {
    expect([...speakerKeyMap(turns)]).toEqual([['1', 'S1'], ['0', 'S2']]);
  });
  it('each word goes to the turn containing its midpoint; same speaker + short pause → one segment', () => {
    const words = [w('Guten', 1), w('Morgen', 1.5), w('Danke', 7), w('gern', 7.6), w('Gut', 14.2), w('so', 14.8)];
    const out = assignWords(words, turns);
    expect(out.map((s) => [s.speaker, s.text])).toEqual([['S1', 'Guten Morgen'], ['S2', 'Danke gern'], ['S1', 'Gut so']]);
    expect(out[1]!.start).toBe(7);
    expect(out[1]!.end).toBeCloseTo(7.9);
  });
  it('words in a gap between turns go to the nearest turn', () => {
    const out = assignWords([w('hm', 6.2, 6.4), w('ja', 13.4, 13.6)], turns);
    expect(out.map((s) => s.speaker)).toEqual(['S1', 'S2']);
  });
  it('overlapping turns: the longer turn wins', () => {
    const out = assignWords([w('x', 7.0, 7.2)], [{ speaker: 'a', start: 6.8, end: 7.7 }, { speaker: 'b', start: 6.85, end: 13 }]);
    expect(out[0]!.speaker).toBe('S2');
  });
  it('same speaker but ≥ 1.5 s pause starts a new segment; no turns → everything S1', () => {
    expect(assignWords([w('a', 0), w('b', 3)], [{ speaker: 0, start: 0, end: 5 }]).length).toBe(2);
    expect(assignWords([w('a', 0)], []).map((s) => s.speaker)).toEqual(['S1']);
  });
  it('the cleaner runs per segment and empty segments disappear', () => {
    const out = assignWords([w('ähm', 1), w('Hallo', 7)], turns, (t) => t.replace(/ähm/g, '').trim());
    expect(out.map((s) => s.text)).toEqual(['Hallo']);
  });
  it('groupWords splits own speech at pauses ≥ 1.2 s', () => {
    expect(groupWords([w('a', 0), w('b', 0.5), w('c', 3)], 'me').map((s) => s.text)).toEqual(['a b', 'c']);
  });
  it('echo: own segments that repeat what the others said at the same time are dropped', () => {
    const others = [seg('S1', 10, 14, 'Der Umzug findet am zwölften Oktober statt')];
    const mine = [seg('me', 10.5, 13, 'Umzug findet zwölften Oktober'), seg('me', 20, 22, 'Das passt mir gut')];
    expect(removeEcho(mine, others).map((s) => s.text)).toEqual(['Das passt mir gut']);
  });
  it('mergeAdjacent joins the same speaker within 2 s and sorts by time', () => {
    const out = mergeAdjacent([seg('S1', 5, 6, 'b'), seg('S1', 0, 4, 'a'), seg('S2', 6.5, 7, 'c'), seg('S2', 10, 11, 'd')]);
    expect(out.map((s) => [s.speaker, s.text])).toEqual([['S1', 'a b'], ['S2', 'c'], ['S2', 'd']]);
  });
  it('speechSeconds counts loud 30-ms frames', () => {
    const s = new Float32Array(32000);
    for (let i = 0; i < 16000; i++) s[i] = 0.1 * Math.sin(i / 5);
    expect(speechSeconds(s)).toBeGreaterThan(0.9);
    expect(speechSeconds(s)).toBeLessThan(1.1);
  });
});

/** fake Silero: speech wherever |x| > 0.05, emitted as regions */
function fakeVad(): VadLike {
  const out: { start: number; samples: Float32Array }[] = [];
  let pos = 0, cur: number[] = [], curStart = 0, silent = 0;
  const close = () => { if (cur.length) out.push({ start: curStart, samples: Float32Array.from(cur) }); cur = []; silent = 0; };
  return {
    acceptWaveform(s) {
      for (let i = 0; i < s.length; i++, pos++) {
        const loud = Math.abs(s[i]!) > 0.05;
        if (loud) { if (!cur.length) curStart = pos; cur.push(s[i]!); silent = 0; }
        else if (cur.length) { if (++silent > 8000) close(); else cur.push(s[i]!); }
      }
    },
    isEmpty: () => out.length === 0, front: () => out[0]!, pop: () => { out.shift(); }, flush: close,
  };
}
const tone = (sec: number) => { const a = new Float32Array(sec * 16000); for (let i = 0; i < a.length; i++) a[i] = 0.2 * Math.sin(i / 3); return a; };
const concat = (...xs: Float32Array[]) => { const o = new Float32Array(xs.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of xs) { o.set(x, p); p += x.length; } return o; };

describe('chunking', () => {
  it('VAD regions are found (yielding loop) and chunks stay ≤ 25 s, cut in pauses, never overlap', async () => {
    const audio = concat(new Float32Array(16000), tone(12), new Float32Array(16000), tone(10), new Float32Array(16000), tone(14), new Float32Array(16000));
    const regions = await vadRegions(fakeVad(), audio);
    expect(regions.length).toBe(3);
    const chunks = planMeetingChunks(audio.length, regions);
    for (const [a, b] of chunks) expect(b - a).toBeLessThanOrEqual(25 * 16000);
    for (let i = 1; i < chunks.length; i++) expect(chunks[i]![0]).toBeGreaterThanOrEqual(chunks[i - 1]![1]);
    // every region is inside a chunk
    for (const r of regions) expect(chunks.some(([a, b]) => r.start >= a && r.start + r.length <= b)).toBe(true);
  });
  it('transcribeLong shifts word times by the chunk position and reports progress to 1', async () => {
    const audio = concat(new Float32Array(3 * 16000), tone(2), new Float32Array(26 * 16000), tone(2));
    const seen: number[] = [];
    const words = await transcribeLong(audio, {
      vad: fakeVad(),
      decode: async () => ({ text: 'Hallo', tokens: [' Hallo'], timestamps: [0.4], durations: [0.3] }),
    }, (p) => seen.push(p));
    expect(words.length).toBe(2);
    expect(words[0]!.start).toBeCloseTo(3 - 0.35 + 0.4, 1);
    expect(words[1]!.start).toBeGreaterThan(30);
    expect(seen[seen.length - 1]).toBeCloseTo(1);
  });
  it('LiveSegmenter cuts the stream at pauses and reports start times', () => {
    const got: [number, number][] = [];
    const s = new LiveSegmenter((t, x) => got.push([t, x.length / 16000]));
    const audio = concat(new Float32Array(16000), tone(2), new Float32Array(16000), tone(1));
    for (let i = 0; i < audio.length; i += 1600) s.feed(audio.subarray(i, i + 1600));
    s.flush();
    expect(got.length).toBe(2);
    expect(got[0]![0]).toBeGreaterThan(0.6);
    expect(got[0]![0]).toBeLessThan(1.01);
    expect(got[1]![0]).toBeGreaterThan(3.5);
  });
});

describe('processTracks', () => {
  const deps = (log: string[]): ProcessDeps => ({
    transcribe: async (s) => { log.push(`transcribe ${Math.round(s.length / 16000)}`); return s[0] === 1 ? [w('Mein', 1), w('Beitrag', 1.4)] : [w('Hallo', 1), w('zusammen', 1.5), w('Antwort', 7)]; },
    diarize: async (s) => { log.push(`diarize ${Math.round(s.length / 16000)}`); return [{ speaker: 0, start: 0.5, end: 3 }, { speaker: 1, start: 6, end: 9 }]; },
    clean: (t) => t,
    note: (k) => log.push(`note ${k}`),
  });
  const speech = (sec: number, first = 0) => { const a = tone(sec); a[0] = first; return a; };

  it('online call: system track diarized, own mic = "me"', async () => {
    const log: string[] = [];
    const out = await processTracks({ system: () => speech(10), mic: () => speech(3, 1) }, deps(log));
    expect(out.map((s) => [s.speaker, s.text])).toEqual([['S1', 'Hallo zusammen'], ['me', 'Mein Beitrag'], ['S2', 'Antwort']]);
    expect(log.filter((l) => !l.startsWith('note'))).toEqual(['diarize 10', 'transcribe 10', 'transcribe 3']);
  });
  it('in person / import (one track): that track is diarized', async () => {
    const log: string[] = [];
    const out = await processTracks({ mic: () => speech(10) }, deps(log));
    expect(out.map((s) => s.speaker)).toEqual(['S1', 'S2']);
    expect(log).toContain('note diarizeRoom');
  });
  it('silent system track (< 4 s speech) → treated as in person', async () => {
    const log: string[] = [];
    await processTracks({ system: () => new Float32Array(16000 * 30), mic: () => speech(10) }, deps(log));
    expect(log.filter((l) => !l.startsWith('note'))).toEqual(['diarize 10', 'transcribe 10']);
  });
});
