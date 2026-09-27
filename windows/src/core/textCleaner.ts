// Port of the Mac app's TextCleaner (Sources/Murmur/TextCleaner.swift):
// filler words, dictionary replacements, voice commands ("neue Zeile"), tidy().
import { escapeRe, isLetter, isSpace } from './chars';

export interface DictEntry {
  /** what the recogniser hears, e.g. "clip vault" */
  heard: string;
  /** what should be written, e.g. "ClipVault" */
  write: string;
  /** only a vocabulary hint (no replacement) */
  vocabOnly?: boolean;
}

export interface CleanOptions {
  removeFillers: boolean;
  voiceCommands: boolean;
  dictionary: readonly DictEntry[];
}

/** pure fillers. "um" is missing on purpose (German preposition: "um zehn Uhr"). */
export const FILLERS = ['ähm', 'äh', 'ähh', 'öhm', 'öh', 'ehm', 'hm', 'hmm', 'uh', 'uhm', 'uhh', 'erm', 'mhm'];

const FILLER_RE = new RegExp(`(^|[\\s,])(${FILLERS.map(escapeRe).join('|')})[,.…]*(?=\\s|$)`, 'giu');
// Swift/ICU \b and \w are Unicode-aware; emulate with explicit classes.
const W = '[\\p{L}\\p{M}\\p{Nd}\\p{Pc}]';
const REPEAT_RE = new RegExp(`(?<!${W})(${W}{1,12})(?:\\s+\\1(?!${W}))+`, 'giu');
const PARA_RE = /[,.]?\s*\b(neuer absatz|new paragraph)\b[,.]?\s*/giu;
const LINE_RE = /[,.]?\s*\b(neue zeile|new line)\b[,.]?\s*/giu;

const dictCache = new Map<string, RegExp>();
/** whole word, case-insensitive (no partial matches) */
export function dictRegex(heard: string): RegExp | null {
  const key = heard.trim();
  if (!key) return null;
  let r = dictCache.get(key);
  if (!r) {
    r = new RegExp(`(?<![\\p{L}\\d])${escapeRe(key)}(?![\\p{L}\\d])`, 'giu');
    dictCache.set(key, r);
  }
  r.lastIndex = 0;
  return r;
}

export function applyDictionary(s: string, dictionary: readonly DictEntry[]): string {
  for (const e of dictionary) {
    if (!e.heard.trim() || e.vocabOnly === true) continue;
    const re = dictRegex(e.heard);
    if (!re) continue;
    s = s.replace(re, () => e.write);
  }
  return s;
}

export function applyVoiceCommands(s: string): string {
  s = s.replace(PARA_RE, '\n\n');
  s = s.replace(LINE_RE, '\n');
  return s;
}

export function removeFillers(s: string): string {
  s = s.replace(FILLER_RE, '$1');
  s = s.replace(REPEAT_RE, '$1');
  return s;
}

/** TextCleaner.applyRules */
export function applyRules(input: string, o: CleanOptions): string {
  let s = input;
  if (o.removeFillers) s = removeFillers(s);
  s = applyDictionary(s, o.dictionary);
  if (o.voiceCommands) s = applyVoiceCommands(s);
  return tidy(s);
}

/** spaces/punctuation clean-up, capitalise sentence starts */
export function tidy(input: string): string {
  let s = input;
  s = s.replace(/[ \t]{2,}/g, ' ');
  // "ungefähr3000" → "ungefähr 3000" (but "M4", "MP3" stay)
  s = s.replace(/(\p{Ll}{2,})(\d)/gu, '$1 $2');
  s = s.replace(/ +([,.!?;:])/g, '$1');
  // "Hallo.Wie" → "Hallo. Wie" (not 9.40, v2.0, claude.ai)
  s = s.replace(/(\p{L})([.!?;:])(?=\d|\p{Lu})/gu, '$1$2 ');
  s = s.replace(/^[\s,.;:]+/u, '');
  s = s.replace(/,\s*([.!?])/gu, '$1');
  s = s.replace(/\n[ \t]+/g, '\n');
  let out = '';
  let capNext = true;
  const chars = Array.from(s);
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i]!;
    if (capNext && isLetter(ch)) {
      out += ch.toUpperCase();
      capNext = false;
      continue;
    }
    out += ch;
    const endsSentence = '.!?'.includes(ch) && (i + 1 === chars.length || isSpace(chars[i + 1]));
    if (endsSentence || ch === '\n') capNext = true;
    else if (!isSpace(ch)) capNext = false;
  }
  return out.trim();
}

const CORRECTION_MARKERS = [
  'nein warte', 'nein, warte', 'nee warte', 'nee, warte', 'moment, nein', 'moment nein', 'ich meine',
  'ich mein ', 'ich meinte', 'korrektur', 'streich das', 'vergiss das', 'no wait', 'no, wait', 'i mean',
  'scratch that', 'actually no', 'actually, no', 'sorry, ich',
];
export function hasSelfCorrection(s: string): boolean {
  const l = s.toLowerCase();
  return CORRECTION_MARKERS.some((m) => l.includes(m));
}
