// Word error rate (Levenshtein over normalised words).
import { levenshtein } from './chars';

const NUM: Record<string, string> = {
  null: '0', zero: '0', eins: '1', ein: '1', one: '1', zwei: '2', two: '2', drei: '3', three: '3', vier: '4', four: '4',
  fünf: '5', five: '5', sechs: '6', six: '6', sieben: '7', seven: '7', acht: '8', eight: '8', neun: '9', nine: '9',
  zehn: '10', ten: '10', elf: '11', eleven: '11', zwölf: '12', twelve: '12', zwanzig: '20', twenty: '20',
};

export function normWords(s: string): string[] {
  return s
    .toLowerCase()
    .replace(/[-–—/]/g, ' ')
    .replace(/[^\p{L}\p{N}\s']/gu, ' ')
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => (w === 'ein' ? w : NUM[w] ?? w));
}

export function wer(reference: string, hypothesis: string): number {
  const r = normWords(reference);
  const h = normWords(hypothesis);
  if (r.length === 0) return h.length === 0 ? 0 : 1;
  return levenshtein(r, h) / r.length;
}
