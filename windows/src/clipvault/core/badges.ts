// Badges (link / email / phone / color / code) – ported from the Mac util.swift heuristics.

export type Badge = 'link' | 'email' | 'phone' | 'color' | 'code';

const URL_RX = /\bhttps?:\/\/[^\s<>"'`]+/i;
const SOLE_URL_RX = /^https?:\/\/[^\s<>"'`]+$/i;
const EMAIL_RX = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
const HEX_COLOR_RX = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const FN_COLOR_RX = /^(?:rgb|rgba|hsl|hsla)\(\s*[-\d.%\s,/]+\)$/i;

/** The text is exactly one web link (after trimming). */
export function soleURL(text: string | null | undefined): string | null {
  if (!text) return null;
  const t = text.trim();
  if (t.length > 4096 || !SOLE_URL_RX.test(t)) return null;
  try {
    const u = new URL(t);
    return u.protocol === 'http:' || u.protocol === 'https:' ? t : null;
  } catch {
    return null;
  }
}

export function parseColor(text: string | null | undefined): string | null {
  if (!text) return null;
  const t = text.trim();
  if (t.length > 40) return null;
  if (HEX_COLOR_RX.test(t) || FN_COLOR_RX.test(t)) return t;
  return null;
}

export function looksLikeCode(t: string): boolean {
  const lines = t.split('\n').filter((l) => l.trim().length > 0);
  let score = 0;
  if (lines.length >= 2) {
    const enders = lines.filter((l) => /[;{}]$|\);$|\):$/.test(l.trim())).length;
    if (enders / lines.length >= 0.3) score += 2;
    const indented = lines.filter((l) => /^(\t| {2,})/.test(l)).length;
    if (indented / lines.length >= 0.3) score += 1;
  }
  if (/\b(function|const|let|var|return|import|export|class|def|public|private|func|struct|SELECT|FROM|WHERE)\b/.test(t)) score += 1;
  if (/=>|===|!==|&&|\|\||::|->/.test(t)) score += 1;
  if (/^\s*[{[][\s\S]*[}\]]\s*$/.test(t) && /"\s*:/.test(t)) score += 2; // JSON
  return score >= 3;
}

export function detectBadges(raw: string | null | undefined): Badge[] {
  const t = (raw ?? '').trim();
  if (!t) return [];
  const sample = t.length > 20000 ? t.slice(0, 20000) : t;
  const out: Badge[] = [];
  if (parseColor(t)) out.push('color');
  if (EMAIL_RX.test(sample) && !SOLE_URL_RX.test(sample)) out.push('email');
  if (t.length <= 40) {
    const digits = (sample.match(/\d/g) ?? []).length;
    const isDate = /^\d{4}-\d{1,2}-\d{1,2}$|^\d{1,2}\.\d{1,2}\.\d{2,4}$|^\d{1,2}\/\d{1,2}\/\d{2,4}$/.test(sample);
    const isNumber = /^-?\d+([.,]\d+)?$/.test(sample) && !sample.startsWith('0');
    if (!isDate && !isNumber && digits >= 6 && /^[+()\d\s./-]+$/.test(sample) && digits / sample.length >= 0.6) out.push('phone');
  }
  if (URL_RX.test(sample)) out.push('link');
  if (looksLikeCode(sample)) out.push('code');
  return out;
}
