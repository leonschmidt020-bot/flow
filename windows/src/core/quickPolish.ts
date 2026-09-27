// Port of QuickPolish.swift (rule-based polish, no AI, < 5 ms): self-corrections, false starts,
// repeats, "erstens …" lists, final punctuation. Principle: better change nothing than change wrongly.
import { capFirst, isAllDigits, isLower, isUpper, lastChar, firstChar, levenshtein, trimChars, lowerFirst, isLetter, isNumber } from './chars';
import { tidy } from './textCleaner';
import { lexicalClasses, type Tag } from './tagger';
import * as SmartLists from './smartLists';

export interface Report {
  corrections: number; repeats: number; falseStarts: number; lists: number; punctuation: number; listHints: number;
}
const changed = (r: Report) => r.corrections + r.repeats + r.falseStarts + r.lists + r.punctuation + r.listHints > 0;

/** `target` = how the destination app shows lists */
export function apply(input: string, target: SmartLists.Target = 'plain'): { text: string; report: Report } {
  const r: Report = { corrections: 0, repeats: 0, falseStarts: 0, lists: 0, punctuation: 0, listHints: 0 };
  let s = input;
  let n: number;
  [s, n] = resolveCorrections(s); r.corrections = n;
  [s, n] = collapseRepeats(s); r.repeats = n;
  [s, n] = dropFalseStarts(s); r.falseStarts = n;
  const lp = SmartLists.pass(s, target);
  s = lp.text; r.lists = lp.lists; r.listHints = lp.hintUsed ? 1 : 0;
  [s, n] = finalPunctuation(s); r.punctuation = n;
  if (changed(r)) s = tidy(s);
  return { text: changed(r) ? s : input, report: r };
}

// MARK: words

export interface Tok { text: string }
const PUNCT_BARE = ',.;:!?…–—-"\'„“”»«()';
export const bare = (w: string) => trimChars(w, PUNCT_BARE);
const lowerOf = (t: Tok) => bare(t.text).toLowerCase();
const bareOf = (t: Tok) => bare(t.text);
export const tokens = (s: string): Tok[] => s.split(' ').filter((x) => x.length > 0).map((text) => ({ text }));
export const join = (t: readonly Tok[]) => t.map((x) => x.text).join(' ');
const endsClause = (t: Tok) => { const c = lastChar(t.text); return c !== undefined && ',;:.!?…–—'.includes(c); };
const endsSentence = (t: Tok) => { const c = lastChar(t.text); return c !== undefined && '.!?'.includes(c); };

// MARK: self-corrections

type MarkerKind = 'replace' | 'deletePrevious';
interface Marker { words: string[]; kind: MarkerKind; needsCommaBefore: boolean }
const m = (s: string, k: MarkerKind = 'replace', comma = false): Marker => ({ words: s.split(' '), kind: k, needsCommaBefore: comma });
const MARKERS: Marker[] = [
  m('nein warte'), m('nee warte'), m('nein moment'), m('moment nein'), m('warte nein'), m('äh nein'), m('ähm nein'),
  m('oder nein'), m('nein sorry'), m('nein ich meine'), m('nein ich meinte'), m('ich meinte'), m('korrektur'),
  m('oder besser gesagt'), m('besser gesagt'), m('oder besser', 'replace', true), m('ich meine', 'replace', true), m('sorry', 'replace', true),
  m('no wait'), m('wait no'), m('no sorry'), m('sorry i mean'), m('no i mean'), m('i meant'), m('actually make that'),
  m('actually no'), m('no actually'), m('or rather'), m('make that', 'replace', true), m('i mean', 'replace', true), m('correction', 'replace', true),
  m('streich das', 'deletePrevious'), m('vergiss das', 'deletePrevious'), m('lösch das', 'deletePrevious'),
  m('scratch that', 'deletePrevious'), m('forget that', 'deletePrevious'), m('delete that', 'deletePrevious'),
].sort((a, b) => b.words.length - a.words.length); // stable sort, like Swift's

const SPEECH_VERBS = new Set(['said', 'says', 'say', 'asked', 'told', 'sagte', 'sagt', 'meinte', 'fragte', 'schrieb', 'rief']);
const PARTICLES = new Set(['da', 'mit', 'an', 'auf', 'ab', 'zu', 'vor', 'hin', 'her', 'los', 'weg', 'zurück', 'vorbei', 'ein', 'aus']);
const SOFT_LEAD = new Set(['lieber', 'doch', 'eher', 'besser', 'also', 'eigentlich', 'rather', 'actually', 'better', 'instead', 'maybe', 'vielleicht']);

export function findMarker(t: readonly Tok[], from = 1): { lo: number; hi: number; kind: MarkerKind } | null {
  if (t.length < 3) return null;
  let i = Math.max(1, from);
  while (i < t.length) {
    for (const mk of MARKERS) {
      if (i + mk.words.length > t.length) continue;
      let ok = true;
      for (let k = 0; k < mk.words.length; k++) if (lowerOf(t[i + k]!) !== mk.words[k]) { ok = false; break; }
      if (!ok) continue;
      let inner = false;
      for (let k = 0; k < mk.words.length - 1; k++) if (endsSentence(t[i + k]!)) inner = true;
      if (inner) continue;
      const before = mk.needsCommaBefore ? t[i - 1]!.text.endsWith(',') : endsClause(t[i - 1]!);
      const after = endsClause(t[i + mk.words.length - 1]!) || i + mk.words.length === t.length;
      if (mk.needsCommaBefore ? !before : !(before || after)) continue;
      if (mk.kind === 'deletePrevious' && !after) continue;
      if (mk.needsCommaBefore && SPEECH_VERBS.has(lowerOf(t[i - 1]!))) continue;
      return { lo: i, hi: i + mk.words.length, kind: mk.kind };
    }
    i += 1;
  }
  return null;
}

function lastIndexWhere<T>(a: readonly T[], f: (x: T) => boolean): number {
  for (let i = a.length - 1; i >= 0; i--) if (f(a[i]!)) return i;
  return -1;
}

export function resolveCorrections(input: string): [string, number] {
  let t = tokens(input);
  let done = 0;
  let from = 1;
  for (let round = 0; round < 4; round++) {
    const mk = findMarker(t, from);
    if (!mk) break;
    const a = t.slice(0, mk.lo).map((x) => ({ ...x }));
    const b = t.slice(mk.hi);
    const afterSentence = a.length > 0 ? endsSentence(a[a.length - 1]!) : false;
    if (afterSentence) {
      const l = a[a.length - 1]!;
      a[a.length - 1] = { text: Array.from(l.text).slice(0, -1).join('') };
    }
    const ls = lastIndexWhere(a, endsSentence);
    const sentStart = ls >= 0 ? ls + 1 : 0;
    if (mk.kind === 'deletePrevious') {
      const kept = a.slice(0, sentStart);
      if (b.length === 0 && kept.length > 0 && !endsSentence(kept[kept.length - 1]!)) {
        kept[kept.length - 1] = { text: kept[kept.length - 1]!.text + '.' };
      }
      t = [...kept, ...b];
      done += 1; from = Math.max(1, kept.length); continue;
    }
    if (b.length === 0 || !(sentStart < a.length)) { from = mk.hi; continue; }
    let cut = replaceStart(a, sentStart, b, !(afterSentence && b.length >= 3));
    if (cut === null && afterSentence && b.length >= 3) cut = sentStart;
    if (cut === null) { from = mk.hi; continue; }
    const head = a.slice(0, cut);
    if (head.length > 0 && !endsSentence(head[head.length - 1]!)) {
      head[head.length - 1] = { text: trimChars(head[head.length - 1]!.text, ',;:–—') };
    }
    const tail = b.map((x) => ({ ...x }));
    const lastA = a[a.length - 1];
    if (cut > sentStart && cut < a.length - 1 && lastA && PARTICLES.has(lowerOf(lastA)) && !b.some((x) => lowerOf(x) === lowerOf(lastA)) && tail.length > 0) {
      const end = tail[tail.length - 1]!;
      const chars = Array.from(end.text);
      let p = 0;
      while (p < chars.length && '.!?,;'.includes(chars[chars.length - 1 - p]!)) p++;
      const punct = chars.slice(chars.length - p).join('');
      tail[tail.length - 1] = { text: chars.slice(0, chars.length - p).join('') };
      tail.push({ text: bareOf(lastA) + punct });
    }
    if (tail.length > 0) {
      const first = tail[0]!;
      const c = firstChar(first.text);
      if (c !== undefined) {
        if (cut === sentStart) {
          tail[0] = { text: capFirst(first.text) };
        } else if (isUpper(c) && !properLike(bareOf(first)) && isLower(firstChar(bareOf(a[cut]!)))) {
          tail[0] = { text: lowerFirst(first.text) };
        }
      }
    }
    t = [...head, ...tail];
    done += 1;
    from = Math.max(1, head.length);
  }
  return done > 0 ? [join(t), done] : [input, 0];
}

/** looks like a proper name / identifier (uppercase letter inside) */
export const properLike = (w: string) => Array.from(w).slice(1).some((c) => isUpper(c));

export function replaceStart(a: readonly Tok[], sentStart: number, b: readonly Tok[], byClass = true): number | null {
  if (!(sentStart < a.length)) return null;
  // 1) anchor: B starts with a word from A
  const bp = b.slice(0, 2);
  for (let k = 0; k < bp.length; k++) {
    const bw = bp[k]!;
    if (k === 1 && !SOFT_LEAD.has(lowerOf(b[0]!))) break;
    for (let i = a.length - 1; i >= sentStart; i--) {
      if (lowerOf(a[i]!) === lowerOf(bw) && lowerOf(bw) !== '') return i;
    }
  }
  // 1b) right-aligned: B ends like A
  const bHead: Tok[] = [];
  for (const x of b) { bHead.push(x); if (endsSentence(x)) break; }
  if (bHead.length >= 2 && bHead.length <= 4) {
    const lastB = lowerOf(bHead[bHead.length - 1]!);
    let j = -1;
    for (let i = a.length - 1; i >= sentStart; i--) if (lowerOf(a[i]!) === lastB) { j = i; break; }
    if (j >= 0 && j >= a.length - 2) {
      const c = j - (bHead.length - 1);
      if (c >= sentStart) return c;
    }
  }
  // 2) same word class at the end of A
  if (!byClass) return null;
  const whole = join(a) + ' ' + join(b);
  const classes = lexicalClasses(whole, TIME_WORDS, NUMBER_WORDS);
  const bClass = classes.length > a.length ? classes[a.length]! : null;
  const bc = bClass ? group(bClass) : null;
  if (!bc) return null;
  const lo = Math.max(sentStart, a.length - 4);
  for (let i = a.length - 1; i >= lo; i--) {
    if (i < classes.length && group(classes[i]!) === bc) return i;
  }
  return null;
}

function group(c: Tag): string | null {
  switch (c) {
    case 'noun': case 'personalName': case 'placeName': case 'organizationName': return 'nomen';
    case 'number': return 'zahl';
    case 'verb': return 'verb';
    case 'adjective': return 'adj';
    case 'adverb': return 'adv';
    case 'preposition': return 'präp';
    case 'determiner': return 'art';
    case 'pronoun': return 'pron';
    default: return null;
  }
}

export const TIME_WORDS = new Set(['heute', 'morgen', 'übermorgen', 'gestern', 'vorgestern', 'jetzt', 'später', 'gleich', 'bald', 'nachher',
  'today', 'tomorrow', 'yesterday', 'tonight', 'later', 'now', 'soon']);

export const NUMBER_WORDS = new Set(['null', 'eins', 'ein', 'zwei', 'drei', 'vier', 'fünf', 'sechs', 'sieben', 'acht', 'neun', 'zehn',
  'elf', 'zwölf', 'zwanzig', 'dreißig', 'vierzig', 'fünfzig', 'hundert', 'tausend', 'zero', 'one', 'two', 'three', 'four', 'five', 'six',
  'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'twenty', 'thirty', 'forty', 'fifty', 'hundred', 'thousand']);

// MARK: repeats & false starts

export function collapseRepeats(input: string): [string, number] {
  let t = tokens(input);
  let n = 0;
  let again = true;
  while (again) {
    again = false;
    outer: for (let len = 4; len >= 2; len--) {
      if (t.length < 2 * len) continue;
      for (let i = 0; i <= t.length - 2 * len; i++) {
        const a = t.slice(i, i + len).map(lowerOf);
        const b = t.slice(i + len, i + 2 * len).map(lowerOf);
        if (a.join('\u0000') !== b.join('\u0000') || !a.some((x) => Array.from(x).length >= 2)) continue;
        if (endsSentence(t[i + len - 1]!)) continue;
        const keep = t.slice(i + len).map((x) => ({ ...x }));
        if ((i === 0 || endsSentence(t[i - 1]!)) && keep.length > 0 && isUpper(firstChar(t[i]!.text))) {
          keep[0] = { text: capFirst(keep[0]!.text) };
        }
        t = [...t.slice(0, i), ...keep];
        n += 1; again = true;
        break outer;
      }
    }
  }
  return n > 0 ? [join(t), n] : [input, 0];
}

export function dropFalseStarts(input: string): [string, number] {
  let t = tokens(input);
  let n = 0;
  let i = 0;
  while (i < t.length) {
    const atStart = i === 0 || endsSentence(t[i - 1]!);
    if (!atStart) { i += 1; continue; }
    let removed = false;
    for (let len = 1; len <= 4; len++) {
      if (!(i + len < t.length)) continue;
      const frag = t.slice(i, i + len);
      const last = frag[frag.length - 1]!;
      if (!(endsClause(last) && !endsSentence(last))) continue;
      if (frag.slice(0, -1).some(endsClause)) break;
      const rest = t.slice(i + len);
      if (!(rest.length > len && lowerOf(rest[0]!) === lowerOf(frag[0]!))) continue;
      let sim = true;
      for (let k = 1; k < len; k++) if (!similarWord(lowerOf(frag[k]!), lowerOf(rest[k]!))) { sim = false; break; }
      if (!sim) continue;
      const keep = rest.map((x) => ({ ...x }));
      if (keep.length > 0 && isUpper(firstChar(frag[0]!.text))) keep[0] = { text: capFirst(keep[0]!.text) };
      t = [...t.slice(0, i), ...keep];
      n += 1; removed = true;
      break;
    }
    if (!removed) i += 1;
  }
  return n > 0 ? [join(t), n] : [input, 0];
}

function similarWord(a: string, b: string): boolean {
  if (a === b) return true;
  const la = Array.from(a).length, lb = Array.from(b).length;
  if (la >= 2 && b.startsWith(a)) return true;
  if (lb >= 2 && a.startsWith(b)) return true;
  return la >= 3 && lb >= 3 && levenshtein(Array.from(a), Array.from(b)) <= 1;
}

// MARK: "erstens …" lists

interface ListFamily { id: string; words: string[][]; firstAnywhere: boolean }
const FAMILIES: ListFamily[] = [
  { id: 'ens', words: [['erstens'], ['zweitens'], ['drittens'], ['viertens'], ['fünftens'], ['sechstens'], ['siebtens']], firstAnywhere: true },
  { id: 'punkt', words: [['punkt eins', 'punkt 1'], ['punkt zwei', 'punkt 2'], ['punkt drei', 'punkt 3'], ['punkt vier', 'punkt 4'], ['punkt fünf', 'punkt 5'], ['punkt sechs', 'punkt 6']], firstAnywhere: true },
  { id: 'nummer', words: [['nummer eins', 'nummer 1'], ['nummer zwei', 'nummer 2'], ['nummer drei', 'nummer 3'], ['nummer vier', 'nummer 4'], ['nummer fünf', 'nummer 5']], firstAnywhere: true },
  { id: 'als', words: [['als erstes'], ['als zweites'], ['als drittes'], ['als viertes'], ['als fünftes']], firstAnywhere: false },
  { id: 'platz', words: [['auf platz eins', 'auf platz 1', 'platz eins', 'platz 1'], ['auf platz zwei', 'auf platz 2', 'platz zwei', 'platz 2'], ['auf platz drei', 'auf platz 3', 'platz drei', 'platz 3'], ['auf platz vier', 'auf platz 4', 'platz vier', 'platz 4'], ['auf platz fünf', 'auf platz 5', 'platz fünf', 'platz 5']], firstAnywhere: true },
  { id: 'lly', words: [['firstly'], ['secondly'], ['thirdly'], ['fourthly'], ['fifthly']], firstAnywhere: true },
  { id: 'ly', words: [['first'], ['second'], ['third'], ['fourth'], ['fifth'], ['sixth']], firstAnywhere: false },
  { id: 'number', words: [['number one', 'number 1'], ['number two', 'number 2'], ['number three', 'number 3'], ['number four', 'number 4'], ['number five', 'number 5']], firstAnywhere: true },
  { id: 'point', words: [['point one', 'point 1'], ['point two', 'point 2'], ['point three', 'point 3'], ['point four', 'point 4']], firstAnywhere: true },
];

const reCache = new Map<string, RegExp>();
function cachedRegex(p: string): RegExp {
  let r = reCache.get(p);
  if (!r) { r = new RegExp(p, 'iud'); reCache.set(p, r); }
  return r;
}
const escICU = (s: string) => s.replace(/[\\^$.*+?()[\]{}|/-]/g, (c) => (c === '-' ? '\\x2D' : '\\' + c));

export interface Range { location: number; length: number }

/** marker ranges in order 1, 2, 3 … – only at sentence/clause boundaries */
export function listMarkers(s: string): Range[] {
  let best: Range[] = [];
  const boundary = '(?:^|(?<=[,.;:!?])\\s*|\\s(?:und|and|dann|then|sowie)\\s+)';
  for (const fam of FAMILIES) {
    const found: Range[] = [];
    let from = 0;
    for (const alts of fam.words) {
      const alt = alts.map((x) => escICU(x).replace(/ /g, '\\s+')).join('|');
      const lead = found.length === 0 && fam.firstAnywhere ? '(?:^|(?<=[\\s,.;:!?]))' : boundary;
      const pat = `${lead}(${alt})(?![\\p{L}\\p{N}])[,:.]?`;
      const re = cachedRegex(pat);
      // NSRegularExpression default: anchoring + non-transparent bounds → search the substring
      const sub = s.slice(from);
      const mm = re.exec(sub);
      if (!mm) break;
      const [gs, ge] = mm.indices![1]!;
      found.push({ location: from + gs, length: ge - gs });
      from = from + mm.index + mm[0].length;
    }
    if (found.length >= 2 && found.length > best.length) best = found;
  }
  return best.length >= 2 ? best : [];
}

export function formatLists(input: string): [string, number] {
  const ms = listMarkers(input);
  if (ms.length < 2) return [input, 0];
  const L = input.length;
  const markerEnd = (r: Range) => {
    let e = r.location + r.length;
    while (e < L && ',:.'.includes(input[e]!)) e++;
    return e;
  };
  const items: string[] = [];
  ms.forEach((r, k) => {
    const start = markerEnd(r);
    const end = k + 1 < ms.length ? ms[k + 1]!.location : L;
    items.push(input.substring(start, Math.max(start, end)));
  });
  let tail = '';
  if (items.length > 0) {
    let last = items[items.length - 1]!;
    const mt = /[.!?](\s+)(?=\p{Lu})/u.exec(last);
    if (mt) {
      tail = last.substring(mt.index + 1).replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, '');
      last = last.substring(0, mt.index + 1);
    }
    items[items.length - 1] = last;
  }
  const clean = (s: string) => {
    let x = s.trim();
    x = x.replace(/[,;]?\s+(und|and|dann|then|sowie)[,.;]?$/iu, '');
    x = trimChars(x, ' ,;:.\n');
    x = x.replace(/^(ist|is|sind|are)\s+/iu, '');
    return capFirst(x);
  };
  const cleaned = items.map(clean);
  if (!cleaned.every((x) => x.length > 0 && x.split(' ').filter(Boolean).length <= 30)) return [input, 0];
  let intro = input.substring(0, ms[0]!.location).trim();
  intro = intro.replace(/[,;]?\s*(und|and)$/iu, '');
  intro = trimChars(intro, ' ,;');
  const l = lastChar(intro);
  if (intro.length > 0 && l !== undefined && !':?!'.includes(l)) intro = trimChars(intro, '.') + ':';
  let out = (intro.length === 0 ? '' : intro + '\n') + cleaned.map((x, i) => `${i + 1}. ${x}`).join('\n');
  if (tail.length > 0) out += '\n\n' + tail;
  return [out, 1];
}

// MARK: punctuation

const QUESTION_STARTS = new Set(['wer', 'was', 'wann', 'wo', 'wie', 'warum', 'wieso', 'weshalb', 'welche', 'welcher',
  'welches', 'kannst', 'könntest', 'hast', 'bist', 'willst', 'möchtest', 'sollen', 'sollten', 'soll', 'können', 'kann', 'hat', 'ist',
  'gibt', 'habt', 'seid', 'what', 'when', 'where', 'who', 'why', 'how', 'which', 'can', 'could', 'would', 'should', 'do', 'does',
  'did', 'is', 'are', 'was', 'were', 'have', 'has', 'will', 'shall']);

export function finalPunctuation(s: string): [string, number] {
  const lines = s.split('\n');
  const lastLine = lines[lines.length - 1] ?? s;
  const last = lastChar(lastLine);
  if (last === undefined || !(isLetter(last) || isNumber(last))) return [s, 0];
  if (/^(\d+\.|[-•]|- \[ \])\s/u.test(lastLine)) return [s, 0];
  if (lastLine.split(' ').filter(Boolean).length < 3) return [s, 0];
  if (s.includes('`') || s.includes('{') || s.includes('()')) return [s, 0];
  const parts = lastLine.split(/[.!?]/);
  const sentence = parts[parts.length - 1] ?? lastLine;
  const fw = sentence.split(' ').filter(Boolean)[0];
  const first = fw !== undefined ? bare(fw).toLowerCase() : '';
  return [s + (QUESTION_STARTS.has(first) ? '?' : '.'), 1];
}

export { isAllDigits };
