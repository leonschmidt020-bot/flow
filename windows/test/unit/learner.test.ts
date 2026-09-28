// Word learner – the Mac self-test (SelfTestCLI.swift › LearnerSelfTest) ported case by case, plus Windows specifics.
// Terminal fixtures are synthetic, built after the structure measured on the Mac (VS Code/xterm.js + Claude Code,
// 27.09.2026: one row per element, padded to full width) – no real terminal text, neutral names only.
import { describe, expect, it } from 'vitest';
import {
  anchor, knownWords, learnable, LearnQueue, locate, locateInsert, norm, options, PLACE_LABEL, readable, reading, regionBetween,
  rememberEntry, replacements, sameStem, screenFromRead, shouldLearn, Tracker, words, type AnchorResult, type Pair,
} from '../../src/core/learner';
import { isRule, join, parse, isPromptStart, dropPrompt, content } from '../../src/core/terminalPrompt';

const has = (p: Pair[], o: string, n: string) => p.some((x) => x.old === o && x.new === n);
const lower = (w: string[]) => w.map((x) => x.replace(/^\p{P}+|\p{P}+$/gu, '').toLowerCase());

function bounds(inserted: string, screen: string) {
  const w = words(screen), l = lower(w);
  const f = locate(words(inserted), w);
  if (!f) return null;
  return { pre: l.slice(Math.max(0, f.lo - 3), f.lo), post: l.slice(f.hi, f.hi + 3) };
}
/** a whole observation like CorrectionLearner.poll(): screen when pasting → after the correction */
function observe(inserted: string, before: string, after: string): Pair[] {
  const b = bounds(inserted, before);
  if (!b) return [];
  const insW = words(inserted), valW = words(after);
  const region = insW.length === 1 ? regionBetween(b.pre, b.post, valW) : locate(insW, valW, b.pre, b.post)?.words ?? null;
  return region ? learnable(inserted, region.join(' ')) : [];
}

const rule = '─'.repeat(60);
const pad = (r: string, w = 60) => (Array.from(r).length >= w ? r : r + ' '.repeat(w - Array.from(r).length));
/** Claude Code (new box): history, sent messages („❯ …“, indented continuation), rule, input („❯\u00a0…“), rule, status */
function claude(input: string[], sent: string[][] = [], above = ['⏺ Erledigt, die Tests laufen wieder.', '', '✻ Gearbeitet für 1m 12s'], spinner = '✻ Gearbeitet für 1m 12s'): string[] {
  const r = [...above, ''];
  for (const m of sent) {
    r.push('❯ ' + m[0]); r.push(...m.slice(1).map((x) => '  ' + x));
    r.push('', '⏺ Mache ich.', '', spinner, '');
  }
  r.push(rule, '❯\u00a0' + (input[0] ?? ''), ...input.slice(1).map((x) => '  ' + x), rule);
  r.push('  Modell: Opus 4.7 (1M context) · Kontext: 42%', '  ⏵⏵ accept edits on (shift+tab to cycle) · 3 files');
  return r.map((x) => pad(x));
}
function claudeOld(input: string[]): string[] {
  const w = 60;
  const r = ['⏺ Fertig.', '', '╭' + '─'.repeat(w - 2) + '╮'];
  input.forEach((l, i) => r.push('│ ' + pad((i === 0 ? '> ' : '  ') + l, w - 4) + ' │'));
  r.push('╰' + '─'.repeat(w - 2) + '╯', '  ? for shortcuts');
  return r;
}

/** whole flow like CorrectionLearner.poll(): state when pasting → readings ([] = nothing readable) */
function flow(ins: string, start: string[], polls: string[][], o: { field?: boolean; finalLast?: boolean } = {}) {
  const k = knownWords(ins);
  const scr = (rows: string[]) => (o.field ? { sent: [], all: norm(rows.join('\n')), collapsed: false } : parse(rows, k));
  const res = anchor(norm(ins), scr(start), !!o.field);
  const tr = new Tracker();
  const asks: Pair[] = [];
  if (res.t !== 'found') return { asks, end: undefined as string | undefined, res, tr };
  for (let i = 0; i < polls.length; i++) {
    const p = polls[i]!;
    const ok = p.length > 0;
    const st = tr.step(ok ? reading(res.anchor, scr(p)) : null, ok, !!o.finalLast && i === polls.length - 1);
    asks.push(...st.ask);
    if (st.end) return { asks, end: st.end as string | undefined, res, tr };
  }
  return { asks, end: undefined as string | undefined, res, tr };
}
const place = (r: AnchorResult) => (r.t === 'found' ? PLACE_LABEL[r.anchor.place] : r.t === 'sentAlready' ? 'schon abgeschickt' : `nicht gefunden (${r.score})`);

describe('1) replacements / mishearing vs. grammar', () => {
  it('one word becomes two', () => expect(has(learnable('ich will das heute noch auffixen', 'ich will das heute noch auch fixen'), 'auffixen', 'auch fixen')).toBe(true));
  it('„zur Legal“ → „zu Lidl“: only Legal→Lidl, zur→zu is grammar', () => {
    const p = learnable('wir gehen zur Legal einkaufen', 'wir gehen zu Lidl einkaufen');
    expect(has(p, 'Legal', 'Lidl')).toBe(true);
    expect(p.some((x) => x.old === 'zur')).toBe(false);
  });
  it('case only at the word start is not learned', () => expect(learnable('ich gehe morgen', 'Ich gehe morgen')).toEqual([]));
  it('function words and endings are grammar, real word swaps are mishearings', () => {
    expect(shouldLearn('zur', 'zu')).toBe(false);
    expect(shouldLearn('das', 'dass')).toBe(false);
    expect(shouldLearn('den', 'dem')).toBe(false);
    expect(shouldLearn('gehe', 'gehen')).toBe(false);
    expect(shouldLearn('ID', 'Lidl')).toBe(true);
    expect(shouldLearn('Zeilen', 'Teilen')).toBe(true);
    expect(shouldLearn('fixen', 'mixen')).toBe(true);
    expect(shouldLearn('sehen', 'gehen')).toBe(true);
    expect(shouldLearn('Github', 'GitHub')).toBe(true);
  });
  it('two-word name is learned as a whole', () => expect(has(learnable('Whisper Floor ist schnell', 'Wispr Flow ist schnell'), 'Whisper Floor', 'Wispr Flow')).toBe(true));
  it('big rewrite instead of a correction → nothing', () => expect(learnable('das ist ein ganz anderer Satz mit vielen Wörtern', 'heute regnet es und wir bleiben lieber zu Hause')).toEqual([]));
  it('sameStem', () => {
    expect(sameStem('gehe', 'gehen')).toBe(true);
    expect(sameStem('haus', 'hause')).toBe(true);
    expect(sameStem('lidel', 'lidl')).toBe(false);
    expect(sameStem('okonkwu', 'okonkwo')).toBe(false);
  });
  it('raw replacements keep punctuation out', () => expect(replacements('Hallo, Nico!', 'Hallo, Niko!')).toEqual([{ old: 'Nico', new: 'Niko' }]));
});

describe('2) locate: a deleted word is never paired with the status line', () => {
  it('„West“ deleted → no pair with „Modell“', () => {
    const ins = 'West wurde gelöscht und neu angelegt';
    const p = observe(ins, 'Opus 4 Modell ❯ West wurde gelöscht und neu angelegt', 'Opus 4 Modell ❯ wurde gelöscht und neu angelegt');
    expect(p.some((x) => x.new.toLowerCase().includes('modell') || x.old === 'West')).toBe(false);
    // counter-check: without borders the old bug is reproducible
    expect(locate(words(ins), words('Opus 4 Modell ❯ wurde gelöscht und neu angelegt'))?.words[0]).toBe('Modell');
  });
  it('word in the middle replaced → exactly ID→Lidl', () => {
    const p = observe('wir treffen uns bei ID um acht', 'Status: bereit ❯ wir treffen uns bei ID um acht', 'Status: bereit ❯ wir treffen uns bei Lidl um acht');
    expect(p).toEqual([{ old: 'ID', new: 'Lidl' }]);
  });
  it('locate takes a changed last word along', () => {
    const loc = locate(words('ganz am Ende steht Okonkwo'), words('xx yy ganz am Ende steht Okonkwu zz'));
    expect(loc?.words.at(-1)).toBe('Okonkwu');
    expect(loc?.score).toBe(4);
  });
});

describe('3) single-word dictation (regionBetween)', () => {
  it('word in the middle', () => expect(has(observe('Lidel', 'Wir gehen morgen zu Lidel und dann heim', 'Wir gehen morgen zu Lidl und dann heim'), 'Lidel', 'Lidl')).toBe(true));
  it('word at the end (at most 2 words)', () => expect(has(observe('auffixen', 'Kannst du das bitte auffixen', 'Kannst du das bitte auch fixen'), 'auffixen', 'auch fixen')).toBe(true));
  it('borders', () => {
    expect(regionBetween(['gehen', 'zu'], [], words('wir gehen zu Lidl und dann nach Hause'))).toEqual(['Lidl', 'und']);
    expect(regionBetween(['gehen', 'zu'], ['heute'], words('ganz anderer Text'))).toBeNull();
    expect(regionBetween([], [], ['Lidl'])).toEqual(['Lidl']);
    expect(regionBetween(['a'], ['b'], words('a eins zwei drei vier b'))).toBeNull();
  });
});

describe('4) options', () => {
  const o = options('auffixen', 'auch fixen', ['auch fixen', 'auch f', 'auch', 'auch fi']);
  it('first = what was written last, no half-typed states, max 3, never the original', () => {
    expect(o[0]).toBe('auch fixen');
    expect(o).not.toContain('auch f');
    expect(o).not.toContain('auch fi');
    expect(o).toContain('auch');
    expect(o.length).toBeLessThanOrEqual(3);
    expect(o.some((x) => x.toLowerCase() === 'auffixen')).toBe(false);
  });
});

describe('7) Claude Code box (synthetic terminal rows)', () => {
  const insK = 'frag mal Klot ob das mit dem neuen Build und den Terminal-Zeilen jetzt wirklich zuverlässig funktioniert';
  it('wrapped input over 2 rows without prompt/rules/indent; status lines excluded', () => {
    const sc = parse(claude(['frag mal Klot ob das mit dem neuen Build und den', 'Terminal-Zeilen jetzt wirklich zuverlässig funktioniert']), knownWords(insK));
    expect(sc.input).toBe(insK);
    expect(sc.sent).toEqual([]);
    expect(sc.input).not.toContain('Modell');
    expect(sc.input).not.toContain('Gearbeitet');
  });
  it('older box „│ > … │“', () => expect(parse(claudeOld(['bitte prüf das mit', 'dem Wortlerner nochmal'])).input).toBe('bitte prüf das mit dem Wortlerner nochmal'));
  it('sent: box empty, message as „❯ …“ in the history', () => {
    const hist = parse(claude([''], [['frag mal Claude ob das mit dem neuen Build und den', 'Terminal-Zeilen jetzt wirklich zuverlässig funktioniert']]), knownWords(insK));
    expect(hist.input).toBe('');
    expect(hist.sent.at(-1)).toBe(insK.replace('Klot', 'Claude'));
  });
  it('join: mid-word wrap glued, two known words stay apart', () => {
    expect(join([{ text: 'bitte den Wortler', full: true }, { text: 'ner prüfen', full: false }], knownWords('bitte den Wortlerner prüfen'))).toBe('bitte den Wortlerner prüfen');
    expect(join([{ text: 'frag mal', full: true }, { text: 'Klot ob', full: false }], knownWords('frag mal Klot ob'))).toBe('frag mal Klot ob');
  });
  it('collapsed paste and plain shell prompt', () => {
    expect(parse(claude(['[Pasted text #1 +12 lines]'])).collapsed).toBe(true);
    expect(parse(['~/code main', '❯ git commit -m "Wortlerner geht wieder"', ''].map((x) => pad(x))).input).toBeUndefined();
  });
  it('helpers', () => {
    expect(isRule(rule)).toBe(true);
    expect(isRule('  ---  ')).toBe(false);
    expect(isPromptStart('❯ hallo')).toBe(true);
    expect(isPromptStart('   ❯ hallo')).toBe(false);
    expect(isPromptStart('>x')).toBe(false);
    expect(dropPrompt('❯ ❯ Text')).toBe('Text');
    expect(content('│ hallo   │', 11)).toEqual({ text: ' hallo', full: false });
  });
  it('Windows Terminal rows without padding and with \\r are fine', () => {
    const rows = claude(['frag mal Klot ob das geht']).map((r) => r.trimEnd() + '\r');
    expect(parse(rows).input).toBe('frag mal Klot ob das geht');
  });
});

describe('8) terminal flow: edit the box, send, new dictation', () => {
  const insC = 'frag mal Klot ob das mit dem neuen Build geht';
  const boxStart = claude([insC]);
  const edited = claude(['frag mal Claude ob das mit dem neuen Build geht'], [], undefined, '✻ Gearbeitet für 1m 13s');
  const sentEdited = claude([''], [['frag mal Claude ob das mit dem neuen Build geht']]);
  it('anchored in the Claude Code input; 3 equal readings → asked', () => {
    const f = flow(insC, boxStart, [edited, edited, edited]);
    expect(place(f.res)).toBe('Claude-Code-Eingabe');
    expect(f.asks).toEqual([{ old: 'Klot', new: 'Claude' }]);
  });
  it('corrected + Enter right away → the sent version counts at once', () => {
    const f = flow(insC, boxStart, [edited, sentEdited]);
    expect(has(f.asks, 'Klot', 'Claude')).toBe(true);
    expect(f.end).toBe('abgeschickt');
  });
  it('correction only seen in the history', () => expect(has(flow(insC, boxStart, [sentEdited]).asks, 'Klot', 'Claude')).toBe(true));
  it('sent unchanged → nothing asked, observation ends', () => {
    const f = flow(insC, boxStart, [boxStart, claude([''], [[insC]])]);
    expect(f.asks).toEqual([]);
    expect(f.end).toBe('abgeschickt');
  });
  it('corrected, then a new dictation (finish) → still asked', () => {
    const f = flow(insC, boxStart, [edited], { finalLast: true });
    expect(has(f.asks, 'Klot', 'Claude')).toBe(true);
    expect(f.end).toBe('vorbei');
  });
  it('change stood 2 readings, then scrolled away → asked', () => {
    expect(has(flow(insC, boxStart, [edited, edited, claude([''], [], ['⏺ viel Ausgabe', '  noch mehr Ausgabe'])]).asks, 'Klot', 'Claude')).toBe(true);
  });
  it('a sentence appended / a word deleted → no correction', () => {
    const longer = claude(['frag mal Klot ob das mit dem neuen Build geht. Und schau dir danach', 'bitte auch die Logs an']);
    const f = flow(insC, boxStart, [longer, longer, longer, longer]);
    expect(f.asks).toEqual([]);
    expect(f.tr.everSaw).toBe(false);
    const deleted = claude(['frag mal Klot ob das mit dem Build geht']);
    expect(flow(insC, boxStart, [deleted, deleted, deleted]).asks).toEqual([]);
  });
  it('two words written together, case inside a word, real word swap', () => {
    expect(has(flow('teste bitte den Wort Lerner im Terminal', claude(['teste bitte den Wort Lerner im Terminal']), [claude(['teste bitte den Wortlerner im Terminal'])], { finalLast: true }).asks, 'Wort Lerner', 'Wortlerner')).toBe(true);
    const insG = 'der Code liegt auf Github im privaten Repo';
    expect(has(flow(insG, claude([insG]), [claude(['der Code liegt auf GitHub im privaten Repo'])], { finalLast: true }).asks, 'Github', 'GitHub')).toBe(true);
    expect(has(flow('wir sehen uns morgen früh', claude(['wir sehen uns morgen früh']), [claude(['wir gehen uns morgen früh'])], { finalLast: true }).asks, 'sehen', 'gehen')).toBe(true);
  });
  it('typed slowly: „Lidl“ asked once, intermediate states not offered', () => {
    const typing = ['L', 'Li', 'Lid', 'Lidl', 'Lidl', 'Lidl'].map((x) => claude([`wir treffen uns bei ${x} um acht`]));
    const f = flow('wir treffen uns bei ID um acht', claude(['wir treffen uns bei ID um acht']), typing);
    expect(f.asks).toEqual([{ old: 'ID', new: 'Lidl' }]);
    expect(options('ID', 'Lidl', f.tr.seen.get('ID') ?? [])).not.toContain('Lid');
  });
  it('same text already in the history earlier → the NEW message counts', () => {
    const f = flow(insC, claude([insC], [[insC]]), [claude([''], [[insC], ['frag mal Claude ob das mit dem neuen Build geht']])]);
    expect(has(f.asks, 'Klot', 'Claude')).toBe(true);
  });
  it('text only in the history (sent automatically) → nothing to watch', () => {
    expect(place(flow(insC, sentEdited.map((r) => r.replace('Claude', 'Klot')), []).res)).toBe('schon abgeschickt');
  });
  it('unreadable in between does not count as „text gone“', () => {
    const f = flow(insC, boxStart, [[], [], edited, edited, edited]);
    expect(has(f.asks, 'Klot', 'Claude')).toBe(true);
    expect(f.tr.unreadable).toBe(2);
  });
  it('plain shell: whole terminal rows', () => {
    const shell = ['~/code main', '❯ git commit -m "Wortlerner geht wieder"'].map((x) => pad(x));
    expect(place(flow('git commit -m Wortlerner geht wieder', shell, []).res)).toBe('Terminal-Zeilen');
  });
});

describe('9) text field (Notepad/Word/browser) and grammar rules', () => {
  const note = ['Liebe Grüße an alle,', 'wir treffen uns morgen bei ID um acht', 'am Eingang'];
  const fixed = ['Liebe Grüße an alle,', 'wir treffen uns morgen bei Lidl um acht', 'am Eingang'];
  it('field: word replaced → asked', () => {
    const f = flow('wir treffen uns morgen bei ID um acht', note, [fixed, fixed, fixed], { field: true });
    expect(place(f.res)).toBe('Textfeld');
    expect(has(f.asks, 'ID', 'Lidl')).toBe(true);
  });
  it('chat: corrected, stood one reading, then Enter (field empty) → asked', () => {
    const f = flow('sag Lena bitte dass wir bei ID sind', ['sag Lena bitte dass wir bei ID sind'],
      [['sag Lena bitte dass wir bei Lidl sind'], ['sag Lena bitte dass wir bei Lidl sind'], ['']], { field: true });
    expect(has(f.asks, 'ID', 'Lidl')).toBe(true);
  });
});

describe('Windows: read results from the UI Automation helper', () => {
  it('field / terminal / xterm read results become screens', () => {
    expect(screenFromRead({ kind: 'field', text: 'Hallo\n Nico' }, new Set()).all).toBe('Hallo Nico');
    expect(screenFromRead({ kind: 'terminal', rows: claude(['hallo Nico']) }, new Set()).input).toBe('hallo Nico');
    expect(screenFromRead({ kind: 'xterm', text: claude(['hallo Nico']).join('\n') }, new Set()).input).toBe('hallo Nico');
  });
  it('readable', () => {
    expect(readable(null)).toBe(false);
    expect(readable({ kind: 'field', text: '' })).toBe(true);
    expect(readable({ kind: 'field', pwd: true })).toBe(false);
    expect(readable({ kind: 'xterm', rows: ['   ', ''] })).toBe(false);
    expect(readable({ kind: 'none' })).toBe(false);
  });
  it('locateInsert finds the text in a field and in the Claude Code box', () => {
    expect(locateInsert('bei ID um acht', { kind: 'field', text: 'Wir sind bei ID um acht da.' }).result.t).toBe('found');
    const r = locateInsert('frag mal Klot', { kind: 'xterm', rows: claude(['frag mal Klot']) });
    expect(r.result.t === 'found' && r.result.anchor.place).toBe('input');
  });
});

describe('pill questions (LearnQueue) and dictionary', () => {
  it('first card shown, same word merges options, answer saves the chosen option', () => {
    const q = new LearnQueue();
    expect(q.add([{ old: 'Klot', options: ['Claude'] }])).toBe(true);
    expect(q.add([{ old: 'klot', options: ['Claud'] }])).toBe(true); // visible card updated
    expect(q.current).toEqual({ old: 'Klot', options: ['Claud', 'Claude'] });
    expect(q.add([{ old: 'Niko', options: ['Nico'] }])).toBe(false);
    expect(q.answer(true, 'Claude')).toEqual({ heard: 'Klot', write: 'Claude' });
    expect(q.current?.old).toBe('Niko');
  });
  it('„Nein“ rejects all options for the session', () => {
    const q = new LearnQueue();
    q.add([{ old: 'Legal', options: ['Lidl', 'Lidel'] }]);
    expect(q.answer(false)).toBeNull();
    expect(q.add([{ old: 'Legal', options: ['Lidl'] }])).toBe(false);
    expect(q.current).toBeUndefined();
  });
  it('rememberEntry replaces the same heard word (case-insensitive) and keeps the rest', () => {
    const d = rememberEntry([{ heard: 'klot', write: 'x' }, { heard: 'para keet', write: 'Parakeet' }, { heard: 'a', write: 'b', vocabOnly: true }], 'Klot', 'Claude');
    expect(d).toEqual([{ heard: 'Klot', write: 'Claude' }, { heard: 'para keet', write: 'Parakeet' }, { heard: 'a', write: 'b', vocabOnly: true }]);
  });
});
