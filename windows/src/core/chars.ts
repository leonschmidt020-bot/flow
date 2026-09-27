// Small Unicode helpers mirroring Swift's Character properties.

export const isLetter = (c: string | undefined): boolean => !!c && /^\p{L}/u.test(c);
export const isNumber = (c: string | undefined): boolean => !!c && /^\p{N}/u.test(c);
export const isUpper = (c: string | undefined): boolean => !!c && /^\p{Lu}/u.test(c);
export const isLower = (c: string | undefined): boolean => !!c && /^\p{Ll}/u.test(c);
export const isSpace = (c: string | undefined): boolean => !!c && /^\s/u.test(c);

/** last user-perceived character (code point granularity is enough for our punctuation checks) */
export function lastChar(s: string): string | undefined {
  if (!s) return undefined;
  const cp = s.codePointAt(s.length - 1);
  // low surrogate → take the pair
  if (cp !== undefined && cp >= 0xdc00 && cp <= 0xdfff && s.length >= 2) return s.slice(-2);
  return s[s.length - 1];
}
export function firstChar(s: string): string | undefined {
  if (!s) return undefined;
  const cp = s.codePointAt(0)!;
  return String.fromCodePoint(cp);
}

/** Swift `String(c).uppercased() + s.dropFirst()` */
export function capFirst(s: string): string {
  const f = firstChar(s);
  if (f === undefined) return s;
  return f.toUpperCase() + s.slice(f.length);
}
export function lowerFirst(s: string): string {
  const f = firstChar(s);
  if (f === undefined) return s;
  return f.toLowerCase() + s.slice(f.length);
}

/** trimmingCharacters(in: CharacterSet(charactersIn: set)) */
export function trimChars(s: string, set: string): string {
  const arr = Array.from(s);
  let a = 0;
  let b = arr.length;
  while (a < b && set.includes(arr[a]!)) a++;
  while (b > a && set.includes(arr[b - 1]!)) b--;
  return arr.slice(a, b).join('');
}

/** trimmingCharacters(in: .whitespaces) – spaces/tabs only, not newlines */
export const trimSpaces = (s: string): string => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, '');

/** escape for a JS RegExp in `u` mode (only syntax characters may be escaped) */
export const escapeRe = (s: string): string => s.replace(/[\\^$.*+?()[\]{}|/]/g, '\\$&');

export const isAllDigits = (s: string): boolean => s.length > 0 && /^\p{N}+$/u.test(s);

export function levenshtein<T>(a: readonly T[], b: readonly T[]): number {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  let cur = new Array<number>(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j]! + 1, cur[j - 1]! + 1, prev[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    [prev, cur] = [cur, prev];
  }
  return prev[b.length]!;
}
