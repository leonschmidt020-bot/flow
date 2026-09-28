// ICU (NSRegularExpression) → JavaScript regex helpers for the Agent-Prompt port.
//
// The Mac patterns rely on ICU semantics: `\b` and `\w` know every Unicode letter („prüfe“, „ändere“, „für“). In JavaScript
// both are ASCII-only – even with the `u` flag – so `\bänder` would never match. `icu()` rewrites them to Unicode-aware
// equivalents and always adds the `u` flag. Inline `(?i)` is not used: pass the `i` flag instead; case-insensitive parts of
// otherwise case-sensitive patterns are spelled out with `ci()`.

const W = String.raw`\p{L}\p{M}\p{N}_`;
const B = String.raw`(?:(?<=[${W}])(?![${W}])|(?<![${W}])(?=[${W}]))`;

const cache = new Map<string, RegExp>();

/** compile an ICU-style pattern: `\b`/`\w` become Unicode-aware, flag `u` is always set */
export function icu(pattern: string, flags = ''): RegExp {
  const f = flags.includes('u') ? flags : flags + 'u';
  const key = f + '\u0000' + pattern;
  const hit = cache.get(key);
  if (hit) { hit.lastIndex = 0; return hit; }
  let out = '';
  let inClass = false;
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i]!;
    if (c === '\\') {
      const n = pattern[i + 1] ?? '';
      if (n === 'b' && !inClass) { out += B; i++; continue; }
      if (n === 'w') { out += inClass ? W : `[${W}]`; i++; continue; }
      out += c + n; i++; continue;
    }
    if (c === '[' && !inClass) inClass = true;
    else if (c === ']' && inClass) inClass = false;
    out += c;
  }
  const re = new RegExp(out, f);
  cache.set(key, re);
  return re;
}

/** letters → [xX] classes (for case-insensitive words inside a case-sensitive pattern, like ICU's `(?i:…)`) */
export function ci(words: string): string {
  let out = '';
  for (const ch of words) {
    const lo = ch.toLowerCase(), up = ch.toUpperCase();
    out += lo !== up ? `[${lo}${up}]` : ch;
  }
  return out;
}

/** first match (like NSRegularExpression.firstMatch) */
export function first(re: RegExp, s: string): RegExpExecArray | null {
  if (!re.global && !re.sticky) return re.exec(s);
  return new RegExp(re.source, re.flags.replace('g', '').replace('y', '')).exec(s);
}

/** all matched strings (non-overlapping, left to right) */
export function all(re: RegExp, s: string): string[] {
  const r = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
  const out: string[] = [];
  for (const m of s.matchAll(r)) out.push(m[0]);
  return out;
}

export const count = (re: RegExp, s: string): number => all(re, s).length;

/** replace every match (NSRegularExpression.stringByReplacingMatches) */
export function replaceAll(re: RegExp, s: string, template: string): string {
  const r = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
  return s.replace(r, template);
}
