// Port of TerminalPrompt.swift – terminal text for the word learner (pure logic, unit-tested).
//
// Windows Terminal / conhost expose their visible rows through UI Automation (TextPattern, visible ranges);
// VS Code, Cursor & Co. draw their terminal with xterm.js, whose hidden input field („xterm-helper-textarea“) is
// always empty – the text only lives in the rows xterm.js offers screen readers („xterm-accessibility-tree“, one
// element per visible row). Measured on the Mac (27.09.2026): 61–75 rows, only the visible part, rows padded with
// spaces to the full width. Windows Terminal may or may not pad – `content()` works either way.
//
// Claude Code draws its input box like this (09/2026):
//
//     ────────────────────────────  (rule)
//     ❯ first part of the text …
//       continuation, indented by 2 spaces
//     ────────────────────────────  (rule)
//       status lines …
//
// Older versions: `╭──╮ / │ > text │ / ╰──╯`. Sent messages then stand in the history as `❯ text` (continuation
// indented again). `parse` splits the rows into: input, sent messages, whole text.

export interface Screen {
  /** text in the Claude Code input box (without frame/prompt). undefined = no box (plain shell etc.) */
  input?: string;
  /** sent messages in the visible history (top → bottom) */
  sent: string[];
  /** all rows joined (line breaks → spaces, wrapped words glued back together) */
  all: string;
  /** Claude Code collapsed the pasted text („[Pasted text #1 +12 lines]“) */
  collapsed: boolean;
}

export const screenOf = (all: string): Screen => ({ sent: [], all, collapsed: false });
export const hasBox = (s: Screen): boolean => s.input !== undefined;

const RULE = new Set(['─', '━', '═', '╌', '┄', '┈', '-', '╭', '╮', '╰', '╯', '┌', '┐', '└', '┘']);
const FRAME = new Set(['│', '┃', '║']);
const PROMPT = new Set(['❯', '>', '›']);
/** characters Claude Code starts its output with – a sent message ends there */
const MARKERS = new Set(['⎿', '⏺', '●', '✻', '✽', '✶', '✳', '✢', '·', '※', '◯', '⏵', '⧉', '▐', '▛', '▜', '▝', '▘']);

const isWs = (c: string | undefined) => c !== undefined && /^\s$/u.test(c);
const isAlnum = (c: string | undefined) => c !== undefined && /^[\p{L}\p{N}]$/u.test(c);
const chars = (s: string) => Array.from(s);
const trimWs = (s: string) => s.replace(/^\s+|\s+$/gu, '');

/** collapse whitespace (terminals wrap lines) – same as CorrectionLearner.norm */
export function norm(s: string): string {
  return s.replace(/[\s\u00a0]+/gu, ' ').trim();
}

/** separator line (─────) or top/bottom edge of a box */
export function isRule(row: string): boolean {
  const t = chars(trimWs(row));
  return t.length >= 8 && t.every((c) => RULE.has(c));
}

/** strip the frame „│ … │“ and trailing spaces. Returns content + whether the row reaches the right edge. */
export function content(row: string, width: number): { text: string; full: boolean } {
  const c = chars(row);
  let lo = 0, hi = c.length;
  let right = width;
  let last = -1;
  for (let i = c.length - 1; i >= 0; i--) if (!isWs(c[i])) { last = i; break; }
  if (last >= 0 && FRAME.has(c[last]!)) { hi = last; right = last; }
  let first = -1;
  for (let i = 0; i < c.length; i++) if (!isWs(c[i])) { first = i; break; }
  if (first >= 0 && first < hi && FRAME.has(c[first]!)) lo = first + 1;
  let end = hi;
  while (end > lo && isWs(c[end - 1])) end--;
  // "full" = the last character stands at (almost) the right edge – a word may be wrapped mid-word there
  return { text: c.slice(lo, end).join(''), full: end > lo && end >= right - 1 };
}

/** does the row (after the frame, at most 2 spaces) start with a prompt „❯ “ / „> “? */
export function isPromptStart(text: string): boolean {
  const c = chars(text);
  let lead = 0;
  while (c[lead] === ' ') lead++;
  if (lead > 2) return false;
  const f = c[lead];
  if (f === undefined || !PROMPT.has(f)) return false;
  const next = c[lead + 1];
  return next === undefined || next === ' ';
}

/** drop prompt characters at the start („❯ ❯ Text“ → „Text“) */
export function dropPrompt(text: string): string {
  const c = chars(text);
  let i = 0;
  while (c[i] === ' ') i++;
  while (c[i] !== undefined && PROMPT.has(c[i]!)) { i++; while (c[i] === ' ') i++; }
  return c.slice(i).join('');
}

export const lowerBare = (w: string): string => w.replace(/^\p{P}+|\p{P}+$/gu, '').toLowerCase();

/**
 * Join rows into one text. If a row reaches the edge and the next continues with a letter, a word may be wrapped
 * mid-word (shells, long words): glue it when the glued word is known (from the dictation) – or neither half is.
 */
export function join(parts: { text: string; full: boolean }[], known: ReadonlySet<string>): string {
  let out = '';
  let prevFull = false;
  for (const p of parts) {
    const t = trimWs(p.text);
    if (!t) { prevFull = false; if (out && !out.endsWith(' ')) out += ' '; continue; }
    if (!out) { out = t; prevFull = p.full; continue; }
    let glue = ' ';
    const lc = chars(out).pop();
    const fc = chars(t)[0];
    if (prevFull && isAlnum(lc) && isAlnum(fc)) {
      const a = out.split(' ').filter(Boolean).pop() ?? '';
      const b = t.split(' ').filter(Boolean)[0] ?? '';
      const whole = lowerBare(a + b);
      if (known.has(whole) || (!known.has(lowerBare(a)) && !known.has(lowerBare(b)))) glue = '';
    }
    if (out.endsWith(' ')) glue = '';
    out += glue + t;
    prevFull = p.full;
  }
  return norm(out);
}

/** terminal rows → input box, sent messages, whole text. `known` = dictated words (lower case, bare) for wrapped words. */
export function parse(raw: readonly string[], known: ReadonlySet<string> = new Set()): Screen {
  // measured 27.09.: the input row has „❯“ + no-break space (U+00A0), the history „❯ “
  const rows = raw.map((r) => r.replace(/\u00a0/gu, ' ').replace(/\r/gu, ''));
  const width = rows.reduce((m, r) => Math.max(m, chars(r).length), 0);
  const parts = rows.map((r) => content(r, width));
  const screen: Screen = { sent: [], all: join(parts, known), collapsed: false };

  // input box from the bottom: rule – 1…40 rows – rule, first row with a prompt
  let box: [number, number] | null = null;
  for (let i = rows.length - 1; i > 0 && !box; i--) {
    if (!isRule(rows[i]!)) continue;
    let j = i - 1;
    while (j >= 0 && !isRule(rows[j]!) && i - j <= 41) j--;
    if (j >= 0 && isRule(rows[j]!) && j + 1 < i && isPromptStart(parts[j + 1]!.text)) box = [j + 1, i];
  }
  if (!box) return screen;

  const boxParts = parts.slice(box[0], box[1]).map((p) => ({ ...p }));
  boxParts[0]!.text = dropPrompt(boxParts[0]!.text);
  const input = join(boxParts, known);
  screen.input = input;
  screen.collapsed = input.includes('[Pasted text');

  // history above the box: „❯ text“ + indented continuation rows up to a blank row or an output marker
  let r = 0;
  const end = box[0] - 1;
  while (r < end) {
    if (!isPromptStart(parts[r]!.text) || isRule(rows[r]!)) { r++; continue; }
    const block = [{ ...parts[r]!, text: dropPrompt(parts[r]!.text) }];
    let k = r + 1;
    while (k < end) {
      const rawText = parts[k]!.text;
      const trimmed = trimWs(rawText);
      if (!trimmed || isRule(rows[k]!) || isPromptStart(rawText)) break;
      if (MARKERS.has(chars(trimmed)[0]!)) break;
      if (!rawText.startsWith('  ')) break; // continuation is indented
      block.push(parts[k]!);
      k++;
    }
    const text = join(block, known);
    if (text) screen.sent.push(text);
    r = k;
  }
  return screen;
}
