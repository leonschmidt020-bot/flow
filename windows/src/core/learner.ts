// Port of CorrectionLearner.swift (pure part) – learns from the user's corrections.
//
// After a dictation is pasted Flow keeps reading the focused field (UI Automation, see src/main/uia). When the user
// swaps one or two words in it (e.g. „Klot“ → „Claude“), the pill asks „Wort gelernt?“ and the pair goes into the
// dictionary. Lessons from the Mac app, all kept here:
//   • keep reading until the text is SENT: Claude Code shows the sent version as „❯ …“ in its history, a chat field
//     is emptied – the last stable reading (or the sent version) counts, not a half-typed intermediate state
//   • ask only when the SAME change stood for three readings in a row – or right away when editing is over
//     (sent, new dictation, text gone, 3 minutes up)
//   • a real word replaced by another real word („sehen“ → „gehen“) is a mishearing → ask.
//     Grammar is not: case only at the word start („ich“ → „Ich“), pure endings („gehe“ → „gehen“) and small
//     function words swapped („zur“ → „zu“, „das“ → „dass“). (Up to Mac 1.7.14 every lower-case real word counted as
//     grammar – all three corrections seen in the terminal on 26.09. were dropped.)
//   • never pair a deleted word with text that stood around the dictation before (status lines: „West → Modell“)
import { lowerBare, norm, parse, type Screen } from './terminalPrompt';

export { norm };
export type Pair = { old: string; new: string };

/** where the dictated text stood when it was pasted */
export type Place = 'field' | 'input' | 'screen';
export const PLACE_LABEL: Record<Place, string> = { field: 'Textfeld', input: 'Claude-Code-Eingabe', screen: 'Terminal-Zeilen' };

export interface Anchor {
  inserted: string;
  place: Place;
  /** 3 words each that stood right before/after the text when it was pasted */
  pre: string[];
  post: string[];
  /** messages already in the history when pasting – the newly sent one is none of these */
  sentBefore: Set<string>;
}

export type AnchorResult = { t: 'found'; anchor: Anchor } | { t: 'sentAlready' } | { t: 'notFound'; score: number };

/** one comparison with the pasted text: which words were replaced, is it already in the history (sent)? */
export interface Reading { pairs: Pair[]; sent: boolean }

/** what the UI Automation helper read from the focused element */
export interface ReadResult {
  kind: 'field' | 'terminal' | 'xterm' | 'none';
  text?: string;
  rows?: string[];
  pid?: number;
  pwd?: boolean;
}

/** words (original spelling) without pure punctuation/symbol tokens like „❯“ or „│“ */
export function words(s: string): string[] {
  return s.split(/\s+/u).filter((w) => /[\p{L}\p{N}]/u.test(w));
}

export const bare = (w: string): string => w.replace(/^\p{P}+|\p{P}+$/gu, '');
const lowerWords = (w: readonly string[]) => w.map((x) => bare(x).toLowerCase());
export const knownWords = (ins: string): Set<string> => new Set(words(ins).map(lowerBare));

/** the read result as a Screen: fields are one text, terminals are parsed rows (Claude Code box etc.) */
export function screenFromRead(r: ReadResult, known: ReadonlySet<string>): Screen {
  if (r.kind === 'terminal' || r.kind === 'xterm') return parse(r.rows ?? (r.text ?? '').split(/\r?\n/u), known);
  return { sent: [], all: norm(r.text ?? ''), collapsed: false };
}

/** is anything readable at all? (nothing = UI Automation off, window gone) */
export function readable(r: ReadResult | null): boolean {
  if (!r || r.pwd || r.kind === 'none') return false;
  if (r.rows) return r.rows.some((x) => x.trim().length > 0);
  return typeof r.text === 'string';
}

// MARK: locate & compare

/**
 * Find the spot in the screen/field text that best matches the pasted text (word by word, from the end).
 * Returns the matching words – including changed words at the start/end – and how many words are unchanged.
 */
export function locate(ins: readonly string[], scr: readonly string[], pre: readonly string[] = [], post: readonly string[] = []):
  { words: string[]; score: number; lo: number; hi: number } | null {
  const m = ins.length;
  if (m === 0 || scr.length === 0) return null;
  const a = lowerWords(ins), b = lowerWords(scr);
  const heads = new Set(a.slice(0, 3));
  let best: { score: number; lo: number; hi: number } | null = null;
  let checked = 0;
  for (let i = b.length - 1; i >= 0 && checked < 400; i--) {
    if (!heads.has(b[i]!)) continue;
    checked++;
    const hi = Math.min(b.length, i + m + 6);
    const win = b.slice(i, hi);
    // LCS with back-tracking: first/last match (index in a and in win)
    const dp: number[][] = Array.from({ length: m + 1 }, () => new Array<number>(win.length + 1).fill(0));
    for (let x = m - 1; x >= 0; x--) {
      for (let y = win.length - 1; y >= 0; y--) {
        dp[x]![y] = a[x] === win[y] ? dp[x + 1]![y + 1]! + 1 : Math.max(dp[x + 1]![y]!, dp[x]![y + 1]!);
      }
    }
    const score = dp[0]![0]!;
    if (score > 0 && (best === null || score > best.score)) {
      let x = 0, y = 0;
      let firstA = -1, firstW = -1, lastA = -1, lastW = -1;
      while (x < m && y < win.length) {
        if (a[x] === win[y]) { if (firstA < 0) { firstA = x; firstW = y; } lastA = x; lastW = y; x++; y++; }
        else if (dp[x + 1]![y]! >= dp[x]![y + 1]!) x++;
        else y++;
      }
      // take changed words before the first / after the last match along – but never beyond the text that stood
      // before/after it when pasting (otherwise „West gelöscht“ becomes „West → Modell“ from the status line)
      let lo = i + firstW;
      for (let n = 0; n < firstA; n++) {
        if (lo - 1 < 0) break;
        if (pre.length && b[lo - 1] === pre[pre.length - 1]) break;
        lo--;
      }
      let hiIdx = i + lastW + 1;
      for (let n = 0; n < m - 1 - lastA; n++) {
        if (hiIdx >= b.length) break;
        if (post.length && b[hiIdx] === post[0]) break;
        hiIdx++;
      }
      best = { score, lo, hi: hiIdx };
      if (score === m) break;
    }
  }
  if (!best || best.score < m * 0.6 || best.lo >= best.hi) return null;
  return { words: scr.slice(best.lo, best.hi), score: best.score, lo: best.lo, hi: best.hi };
}

/** Find the whole dictation in a reading and remember its borders. With a Claude Code box only the box counts; if the
 *  text is not there but in the history, it was already sent. */
export function anchor(inserted: string, s: Screen, fieldMode: boolean): AnchorResult {
  const insW = words(inserted);
  const exact = (text: string) => {
    const w = words(text);
    const f = locate(insW, w);
    return f && f.score === insW.length ? { lo: f.lo, hi: f.hi, w } : null;
  };
  const bounds = (e: { lo: number; hi: number; w: string[] }) => {
    const l = lowerWords(e.w);
    return { pre: l.slice(Math.max(0, e.lo - 3), e.lo), post: l.slice(e.hi, Math.min(l.length, e.hi + 3)) };
  };
  if (s.input !== undefined) {
    const e = exact(s.input);
    if (e) { const b = bounds(e); return { t: 'found', anchor: { inserted, place: 'input', pre: b.pre, post: b.post, sentBefore: new Set(s.sent) } }; }
    if (s.sent.some((m) => exact(m) !== null)) return { t: 'sentAlready' };
    return { t: 'notFound', score: locate(insW, words(s.input))?.score ?? 0 };
  }
  const e = exact(s.all);
  if (e) { const b = bounds(e); return { t: 'found', anchor: { inserted, place: fieldMode ? 'field' : 'screen', pre: b.pre, post: b.post, sentBefore: new Set() } }; }
  return { t: 'notFound', score: locate(insW, words(s.all))?.score ?? 0 };
}

/** replaced words in reading `s` vs. the pasted text. null = text (in that form) no longer visible.
 *  Claude Code: first the box; if it is empty, the NEWLY sent message in the history (then `sent`). */
export function reading(a: Anchor, s: Screen): Reading | null {
  if (a.place === 'input') {
    if (s.input !== undefined) { const p = pairsIn(a, s.input); if (p) return { pairs: p, sent: false }; }
    for (let i = s.sent.length - 1; i >= 0; i--) {
      const m = s.sent[i]!;
      if (a.sentBefore.has(m)) continue;
      const p = pairsIn(a, m);
      if (p) return { pairs: p, sent: true };
    }
    return null;
  }
  const p = pairsIn(a, s.all);
  return p ? { pairs: p, sent: false } : null;
}

export function pairsIn(a: Anchor, text: string): Pair[] | null {
  const insW = words(a.inserted), w = words(text);
  // a single word does not find itself after it was changed → anchor via the neighbouring words
  const region = insW.length === 1 ? regionBetween(a.pre, a.post, w) : locate(insW, w, a.pre, a.post)?.words ?? null;
  if (!region) return null;
  return replacements(a.inserted, region.join(' '));
}

/** words between the text before (pre) and after (post) – for dictations of a single word. 1–3 words or null. */
export function regionBetween(pre: readonly string[], post: readonly string[], scr: readonly string[]): string[] | null {
  const b = lowerWords(scr);
  const p = pre.slice(-2), q = post.slice(0, 2);
  if (!p.length && !q.length) return scr.length <= 3 && scr.length > 0 ? [...scr] : null;
  const eq = (at: number, x: readonly string[]) => x.every((v, k) => b[at + k] === v);
  let start = 0;
  if (p.length) {
    if (b.length < p.length) return null;
    let j = -1;
    for (let s = b.length - p.length; s >= 0; s--) if (eq(s, p)) { j = s; break; }
    if (j < 0) return null;
    start = j + p.length;
  }
  let end = b.length;
  if (q.length) {
    let k = -1;
    for (let s = start; s < Math.max(start, b.length - q.length + 1); s++) if (eq(s, q)) { k = s; break; }
    if (k < 0) return null;
    end = k;
  } else {
    end = Math.min(b.length, start + 2); // word stood at the end: look at 2 words at most (e.g. „auch fixen“)
  }
  if (end <= start || end - start > 3) return null;
  return scr.slice(start, end);
}

// MARK: Tracker – when to ask

export interface Step {
  ask: Pair[];
  grammarOnly: boolean;
  /** reason to end the observation (undefined = keep watching) */
  end?: 'abgeschickt' | 'vorbei' | 'Text nicht mehr da';
}

/** Decides over a sequence of readings when to ask (pure). Stable = the SAME change three readings in a row (the rest
 *  of the screen may change). When editing is over (sent, new dictation, time up) the last state counts right away. */
export class Tracker {
  private candidate: string[] = []; // "old\u0001new"
  private stable = 0;
  readonly learned = new Set<string>();
  /** every spelling seen for a word along the way (intermediate states while typing) */
  readonly seen = new Map<string, string[]>();
  everSaw = false;
  reads = 0;
  unreadable = 0;
  private gone = 0;
  /** log lines of this step (no content) */
  notes: string[] = [];

  constructor(private shouldLearnFn: (o: string, n: string) => boolean = shouldLearn) {}

  step(r: Reading | null, isReadable = true, final = false): Step {
    this.notes = [];
    this.reads++;
    if (!isReadable) {
      this.unreadable++;
      if (final) return { ...this.emit(), end: 'vorbei' };
      return { ask: [], grammarOnly: false };
    }
    if (!r) {
      this.gone++;
      // text gone (chat sent, box emptied, scrolled away): a change that already stood counts
      if (this.candidate.length && (this.stable >= 1 || final)) return { ...this.emit(), end: 'Text nicht mehr da' };
      const out: Step = { ask: [], grammarOnly: false };
      if (final) out.end = 'vorbei'; else if (this.gone >= 20) out.end = 'Text nicht mehr da';
      return out;
    }
    this.gone = 0;
    const now = r.pairs.map((p) => `${p.old}\u0001${p.new}`);
    if (now.length) this.everSaw = true;
    for (const c of now) {
      const [o, n] = c.split('\u0001') as [string, string];
      const v = (this.seen.get(o) ?? []).filter((x) => x !== n);
      v.unshift(n);
      this.seen.set(o, v);
    }
    const same = now.length === this.candidate.length && now.every((x, i) => x === this.candidate[i]);
    if (now.length && same) this.stable++;
    else {
      if (!same && now.length && !now.every((x) => this.learned.has(x))) this.notes.push(`Änderung gesehen (${now.length})`);
      this.candidate = now;
      this.stable = 0;
    }
    let out: Step = { ask: [], grammarOnly: false };
    if (this.candidate.length && (r.sent || final || this.stable >= 2)) out = this.emit();
    if (r.sent) out.end = 'abgeschickt'; else if (final) out.end = 'vorbei';
    return out;
  }

  private emit(): Step {
    const fresh = this.candidate.filter((c) => !this.learned.has(c));
    this.candidate = [];
    this.stable = 0;
    if (!fresh.length) return { ask: [], grammarOnly: false };
    fresh.forEach((c) => this.learned.add(c));
    const ask = fresh.map((c) => { const [o, n] = c.split('\u0001') as [string, string]; return { old: o, new: n }; })
      .filter((p) => this.shouldLearnFn(p.old, p.new));
    return { ask, grammarOnly: ask.length === 0 };
  }
}

// MARK: suggestions

/** Up to 3 suggestions: what was written last, then intermediate states (the Mac adds spelling guesses – Windows has
 *  no spell checker reachable from here, so only what the user actually typed is offered). */
export function options(old: string, nw: string, seen: readonly string[]): string[] {
  const out = [nw];
  const add = (o: string) => {
    const t = o.trim();
    if (!t || t.toLowerCase() === old.toLowerCase() || out.some((x) => x.toLowerCase() === t.toLowerCase()) || !/\p{L}/u.test(t)) return;
    out.push(t);
  };
  for (const v of seen) {
    if (v === nw) continue;
    // half-typed intermediate states („auch f“) are not offered
    const nl = nw.toLowerCase(), vl = v.toLowerCase();
    if (nl.startsWith(vl) && Array.from(v).length < Array.from(nw).length && !nl.startsWith(vl + ' ')) continue;
    add(v);
  }
  return out.slice(0, 3);
}

// MARK: grammar vs. mishearing

/** small words that are usually only swapped for grammar */
export const FUNCTION_WORDS = new Set([
  'der', 'die', 'das', 'dass', 'dem', 'den', 'des', 'ein', 'eine', 'einer', 'einem', 'einen', 'eines', 'kein', 'keine', 'keinen',
  'zu', 'zur', 'zum', 'im', 'in', 'ins', 'am', 'an', 'ans', 'auf', 'aus', 'bei', 'beim', 'mit', 'nach', 'von', 'vom', 'vor', 'für',
  'über', 'unter', 'um', 'ob', 'wenn', 'als', 'wie', 'so', 'und', 'oder', 'aber', 'doch', 'ja', 'nein', 'nicht', 'noch', 'schon',
  'auch', 'nur', 'mal', 'da', 'dann', 'denn', 'ich', 'du', 'er', 'sie', 'es', 'wir', 'ihr', 'mich', 'mir', 'dich', 'dir', 'sich',
  'uns', 'euch', 'ihn', 'ihm', 'ihnen', 'sein', 'seine', 'seinen', 'ihre', 'ihren', 'mein', 'meine', 'meinen', 'dein', 'deine',
  'ist', 'sind', 'war', 'bin', 'bist', 'hat', 'habe', 'hast', 'haben', 'wird', 'werden', 'kann', 'können', 'muss', 'müssen',
  'soll', 'will', 'wo', 'was', 'wer', 'hier', 'dort', 'the', 'a', 'an', 'to', 'of', 'on', 'at', 'for', 'is', 'are', 'was', 'it',
  'this', 'that', 'and', 'or', 'but', 'in', 'i', 'you', 'he', 'she', 'we', 'they', 'be', 'have', 'has', 'do', 'does']);

const ENDINGS = new Set(['', 'e', 'en', 'er', 'es', 'em', 'n', 's', 'st', 't', 'et', 'est', 'ern', 'ens', 'te', 'ten', 'd', 'ed', 'ing']);

/** same start (≥ 3 letters), the rest only a usual ending */
export function sameStem(a: string, b: string): boolean {
  const x = Array.from(a), y = Array.from(b);
  let p = 0;
  while (p < x.length && p < y.length && x[p] === y[p]) p++;
  if (p < 3) return false;
  return ENDINGS.has(x.slice(p).join('')) && ENDINGS.has(y.slice(p).join(''));
}

/**
 * „Is this a real word?“ The Mac asks NSSpellChecker; Windows has no spell checker reachable from Electron without
 * extra native code. The rules below only use the answer to SUPPRESS a question (both words real AND function words /
 * same stem), so a plain-letters check is enough: a token with digits, hyphens or apostrophes counts as not real
 * (→ always asked), function words and endings are caught by the explicit lists.
 */
export const plainWord = (w: string): boolean => /^\p{L}+$/u.test(w);

/** Grammar corrections („zur“ → „zu“, „ich“ → „Ich“, „gehe“ → „gehen“) are no mishearings → do not learn.
 *  A real word replaced by ANOTHER real word („sehen“ → „gehen“, „Zeilen“ → „Teilen“) is a mishearing → ask. */
export function shouldLearn(old: string, nw: string, isRealWord: (w: string) => boolean = plainWord): boolean {
  // case only: at the word start = grammar („ich“ → „Ich“), inside the word = spelling of a name („Github“ → „GitHub“)
  if (old.toLowerCase() === nw.toLowerCase()) return Array.from(old).slice(1).join('') !== Array.from(nw).slice(1).join('');
  const oneWord = !old.includes(' ') && !nw.includes(' ');
  if (!oneWord || !isRealWord(old) || !isRealWord(nw)) return true;
  const o = old.toLowerCase(), n = nw.toLowerCase();
  // articles, prepositions, pronouns … swapped among each other
  if (FUNCTION_WORDS.has(o) && FUNCTION_WORDS.has(n)) return false;
  // same stem, only the ending differs
  if (sameStem(o, n)) return false;
  return true;
}

/** word diff: which 1–3 words were replaced by which 1–3 words? */
export function replacements(a: string, b: string, shouldLearnFn: (o: string, n: string) => boolean = shouldLearn): Pair[] {
  const tok = (s: string) => s.split(/\s+/u).filter(Boolean).map(bare);
  const x = tok(a), y = tok(b);
  if (!x.length || !y.length) return [];
  const dp: number[][] = Array.from({ length: x.length + 1 }, () => new Array<number>(y.length + 1).fill(0));
  for (let i = x.length - 1; i >= 0; i--) {
    for (let j = y.length - 1; j >= 0; j--) dp[i]![j] = x[i] === y[j] ? dp[i + 1]![j + 1]! + 1 : Math.max(dp[i + 1]![j]!, dp[i]![j + 1]!);
  }
  let i = 0, j = 0;
  const out: Pair[] = [];
  let del: string[] = [], ins: string[] = [];
  let changed = 0;
  const flush = () => {
    if (del.length && ins.length && del.length <= 3 && ins.length <= 3) {
      // same number of words: only split when one part is mere grammar („zur Legal“ → „zu Lidl“),
      // otherwise learn as a whole („Whisper Floor“ → „Wispr Flow“ is a name)
      let pairs: Pair[] = [{ old: del.join(' '), new: ins.join(' ') }];
      if (del.length === ins.length && del.length > 1) {
        const split = del.map((o, k) => ({ old: o, new: ins[k]! }));
        if (split.some((p) => !shouldLearnFn(p.old, p.new) || p.old === p.new)) pairs = split;
      }
      for (const p of pairs) if (p.old !== p.new && /\p{L}/u.test(p.new) && p.old) out.push(p);
    }
    changed += Math.max(del.length, ins.length);
    del = []; ins = [];
  };
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] === y[j]) { flush(); i++; j++; }
    else if (j < y.length && (i >= x.length || dp[i]![j + 1]! >= dp[i + 1]![j]!)) { ins.push(y[j]!); j++; }
    else { del.push(x[i]!); i++; }
  }
  flush();
  // big rewrite instead of a correction → learn nothing
  if (changed > Math.max(3, x.length * 0.4)) return [];
  return out;
}

/** replacements that are worth asking about (what the pill shows) */
export const learnable = (a: string, b: string): Pair[] => replacements(a, b).filter((p) => shouldLearn(p.old, p.new));

// MARK: where did the text land?

/** Find the pasted text in what was read: the field, or the terminal rows (Claude Code box). */
export function locateInsert(inserted: string, r: ReadResult): { result: AnchorResult; screen: Screen } {
  const ins = norm(inserted);
  const s = screenFromRead(r, knownWords(ins));
  return { result: anchor(ins, s, r.kind === 'field'), screen: s };
}

// MARK: pill questions (App.swift askToLearn / answerLearn)

export interface Suggestion { old: string; options: string[] }

/** open questions, one card at a time; the same word again (typing intermediate states) merges its options */
export class LearnQueue {
  pending: Suggestion[] = [];
  readonly rejected = new Set<string>();

  /** returns true when the visible card (first item) changed or a first card must be shown */
  add(items: readonly Suggestion[]): boolean {
    const wasEmpty = this.pending.length === 0;
    let firstChanged = false;
    for (const it of items) {
      const open = it.options.filter((o) => !this.rejected.has(`${it.old}\u0001${o}`));
      if (!open.length) continue;
      const i = this.pending.findIndex((p) => p.old.toLowerCase() === it.old.toLowerCase());
      if (i >= 0) {
        const merged = [...open];
        for (const o of this.pending[i]!.options) if (!merged.includes(o)) merged.push(o);
        this.pending[i] = { old: this.pending[i]!.old, options: merged.slice(0, 3) };
        if (i === 0) firstChanged = true;
      } else {
        this.pending.push({ old: it.old, options: open.slice(0, 3) });
      }
    }
    return (wasEmpty && this.pending.length > 0) || firstChanged;
  }

  get current(): Suggestion | undefined { return this.pending[0]; }

  /** answer the visible card: save → the entry to remember; no → all its options are rejected for this session */
  answer(save: boolean, choice?: string): { heard: string; write: string } | null {
    const p = this.pending.shift();
    if (!p) return null;
    if (save) {
      const write = choice && p.options.includes(choice) ? choice : p.options[0]!;
      return { heard: p.old, write };
    }
    for (const o of p.options) this.rejected.add(`${p.old}\u0001${o}`);
    return null;
  }
}

/** put a learned pair into the dictionary (replacing an entry with the same heard word, case-insensitive).
 *  Unlike the Mac app no entry is stored as „hint only“ (vocabOnly): Windows' recognisers take no vocabulary hints,
 *  so a hint-only entry would do nothing – the user explicitly chose „Ins Wörterbuch“. */
export function rememberEntry<T extends { heard: string; write: string; vocabOnly?: boolean }>(dict: readonly T[], heard: string, write: string): { heard: string; write: string }[] {
  const rest = dict.filter((e) => e.heard.toLowerCase() !== heard.toLowerCase()).map((e) => (e.vocabOnly ? { heard: e.heard, write: e.write, vocabOnly: true } : { heard: e.heard, write: e.write }));
  return [{ heard, write }, ...rest];
}
