// Recogniser tokens → words with times, diarization turns → speaker segments (port of MeetingProcessor in
// MeetingController.swift: assign / group / removeEcho / mergeAdjacent / speakerKeyMap). Pure, unit-tested.
import type { RawDecode } from '../asr/engine';
import type { Segment, Turn, Word } from './types';

let idSeq = 0;
export const segId = () => `g${Date.now().toString(36)}${(idSeq++).toString(36)}`;

/**
 * sherpa-onnx tokens (" Mor", "gen", ",") + start times → words. A token that begins with a space or "▁" starts a new
 * word; punctuation and word pieces are glued to the previous word. `offset` = chunk start in seconds.
 * Models without timestamps (Whisper) → the words are spread evenly over the chunk.
 */
export function wordsFromDecode(r: RawDecode, offset: number, chunkSec: number): Word[] {
  const out: Word[] = [];
  const n = r.tokens.length;
  if (n > 0 && r.timestamps.length === n) {
    for (let i = 0; i < n; i++) {
      const raw = r.tokens[i]!;
      const t = r.timestamps[i]!;
      const d = r.durations[i] ?? 0;
      const end = offset + t + (d > 0 ? d : i + 1 < n ? Math.max(0, r.timestamps[i + 1]! - t) : 0.08);
      const startsWord = /^[\s▁]/.test(raw) || out.length === 0;
      const piece = raw.replace(/▁/g, ' ').trim();
      if (!piece) continue;
      const last = out[out.length - 1];
      if (startsWord || !last) out.push({ word: piece, start: offset + t, end });
      else { last.word += piece; last.end = Math.max(last.end, end); }
    }
    return out;
  }
  const words = r.text.split(/\s+/).filter(Boolean);
  const step = words.length ? chunkSec / words.length : 0;
  return words.map((w, i) => ({ word: w, start: offset + i * step, end: offset + (i + 1) * step }));
}

/** diarizer ids in order of first appearance → S1, S2, … */
export function speakerKeyMap(turns: readonly Turn[]): Map<string, string> {
  const map = new Map<string, string>();
  for (const t of [...turns].sort((a, b) => a.start - b.start)) {
    const k = String(t.speaker);
    if (!map.has(k)) map.set(k, `S${map.size + 1}`);
  }
  return map;
}

/**
 * Each word goes to the turn that contains its midpoint (or the nearest one). Consecutive words of the same speaker
 * with less than 1.5 s pause form one segment.
 */
export function assignWords(words: readonly Word[], turns: readonly Turn[], clean: (s: string) => string = (s) => s): Segment[] {
  if (turns.length === 0) return groupWords(words, 'S1', clean);
  const keyMap = speakerKeyMap(turns);
  const sorted = [...turns].sort((a, b) => a.start - b.start);
  const out: Segment[] = [];
  for (const w of words) {
    const mid = (w.start + w.end) / 2;
    let best = sorted[0]!, bestD = Infinity, bestLen = -1;
    for (const t of sorted) {
      const d = mid < t.start ? t.start - mid : mid > t.end ? mid - t.end : 0;
      // overlapping turns (both contain the word): the longer one wins – short blips are usually wrong
      if (d < bestD || (d === 0 && bestD === 0 && t.end - t.start > bestLen)) { bestD = d; best = t; bestLen = t.end - t.start; }
    }
    const key = keyMap.get(String(best.speaker)) ?? 'S1';
    const last = out[out.length - 1];
    if (last && last.speaker === key && w.start - last.end < 1.5) { last.text += ' ' + w.word; last.end = w.end; }
    else out.push({ id: segId(), speaker: key, start: w.start, end: w.end, text: w.word });
  }
  return finish(out, clean);
}

/** single speaker (own microphone): words → segments at pauses ≥ 1.2 s */
export function groupWords(words: readonly Word[], speaker: string, clean: (s: string) => string = (s) => s): Segment[] {
  const out: Segment[] = [];
  for (const w of words) {
    const last = out[out.length - 1];
    if (last && w.start - last.end < 1.2) { last.text += ' ' + w.word; last.end = w.end; }
    else out.push({ id: segId(), speaker, start: w.start, end: w.end, text: w.word });
  }
  return finish(out, clean);
}

function finish(segs: Segment[], clean: (s: string) => string): Segment[] {
  return segs.map((s) => ({ ...s, text: clean(s.text).trim() })).filter((s) => s.text.length > 0);
}

/** Without headphones the microphone hears the others too – drop own segments that mostly repeat what they said. */
export function removeEcho(mine: readonly Segment[], others: readonly Segment[]): Segment[] {
  const words = (s: string) => new Set(s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 2));
  return mine.filter((seg) => {
    const a = words(seg.text);
    if (a.size === 0) return false;
    const b = new Set<string>();
    for (const o of others) if (o.start < seg.end + 1 && o.end > seg.start - 1) for (const w of words(o.text)) b.add(w);
    let common = 0;
    for (const w of a) if (b.has(w)) common++;
    return common / a.size < 0.5;
  });
}

/** same speaker, < 2 s apart, not too long → one segment */
export function mergeAdjacent(segs: readonly Segment[]): Segment[] {
  const out: Segment[] = [];
  for (const s of [...segs].sort((a, b) => a.start - b.start)) {
    const last = out[out.length - 1];
    if (last && last.speaker === s.speaker && s.start - last.end < 2.0 && last.text.length < 600) {
      last.text += ' ' + s.text; last.end = Math.max(last.end, s.end);
    } else out.push({ ...s });
  }
  return out;
}

/** 30 ms frames above -40 dBFS → rough seconds of speech (decides „online“ vs. in-person meeting) */
export function speechSeconds(s: Float32Array, sr = 16000): number {
  const f = Math.round(sr * 0.03);
  let n = 0;
  for (let i = 0; i + f <= s.length; i += f) {
    let sum = 0;
    for (let j = i; j < i + f; j++) sum += s[j]! * s[j]!;
    if (Math.sqrt(sum / f) > 0.01) n++;
  }
  return (n * f) / sr;
}
