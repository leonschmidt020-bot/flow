// Port of SmartLists.swift – smart lists, rule-based (< 5 ms, no AI):
//  • enumeration of ≥ 3 similar things after a trigger/head word → bullets
//  • order ("zuerst … dann … zum Schluss", "first … then … finally"), "Top 3" → numbered
//  • tasks ("ich muss noch X machen, Y anrufen und Z schreiben") → checklist
//  • several imperative sentences → bullets
// Every list must pass the word check (no word added except heading, none dropped except allowed) – otherwise text stays.
// Spoken hint at the end: "als Liste" / "nummeriert" / "als Checkliste" forces, "keine Liste" suppresses (removed).
import { capFirst, isAllDigits, isLetter, isNumber, isUpper, lastChar, trimChars, trimSpaces } from './chars';
import { language as detectLanguage, tagTokens, type Lang, type Tag } from './tagger';
import { formatLists, NUMBER_WORDS } from './quickPolish';

export type Kind = 'bullets' | 'numbered' | 'checklist';
export type Hint = { t: 'none' } | { t: 'force'; kind: Kind | null } | { t: 'suppress' };
export type Target = 'markdown' | 'plain' | 'mail' | 'chat' | 'terminal';
const NONE: Hint = { t: 'none' };
const SUPPRESS: Hint = { t: 'suppress' };
const force = (kind: Kind | null): Hint => ({ t: 'force', kind });

// MARK: target app

/** Mac bundle id → target (kept for parity tests with the Mac app) */
export function targetForBundle(bundleID: string): Target {
  const b = bundleID.toLowerCase();
  const md = ['md.obsidian', 'net.shinyfrog.bear', 'notion.id', 'com.ulyssesapp', 'abnerworks.typora', 'pro.writer.mac',
    'com.logseq', 'com.lukilabs.lukiapp', 'com.agiletortoise.drafts'];
  if (md.some((x) => b.startsWith(x))) return 'markdown';
  const rich = ['com.apple.iwork.pages', 'com.microsoft.word', 'com.apple.textedit', 'com.apple.iwork.keynote', 'com.microsoft.powerpoint'];
  if (rich.some((x) => b.startsWith(x))) return 'mail';
  if (['com.anthropic.claudefordesktop', 'com.openai.chat'].some((x) => b.startsWith(x))) return 'terminal';
  const has = (l: string[]) => l.some((x) => b.startsWith(x));
  if (has(['com.microsoft.vscode', 'com.todesktop.230313mzl4w4u92', 'com.exafunction.windsurf', 'com.google.antigravity',
    'com.apple.dt.xcode', 'com.jetbrains', 'com.sublimetext', 'dev.zed.zed', 'com.panic.nova'])) return 'markdown';
  if (has(['com.apple.terminal', 'com.googlecode.iterm2', 'com.mitchellh.ghostty', 'dev.warp.warp', 'net.kovidgoyal.kitty', 'io.alacritty'])) return 'terminal';
  if (has(['com.apple.mail', 'com.microsoft.outlook', 'com.readdle.smartemail', 'com.superhuman', 'it.bloop.airmail'])) return 'mail';
  if (has(['com.tinyspeck.slackmacgap', 'net.whatsapp', 'desktop.whatsapp', 'com.apple.mobilesms', 'ru.keepcoder.telegram',
    'org.telegram', 'com.hnc.discord', 'org.whispersystems.signal', 'com.microsoft.teams'])) return 'chat';
  return 'plain';
}

/** Windows process name (e.g. "WINWORD.EXE") → target */
export function targetForExe(exe: string): Target {
  const e = exe.toLowerCase().replace(/\.exe$/u, '').split(/[\\/]/).pop() ?? '';
  if (['obsidian', 'notion', 'typora', 'logseq', 'code', 'cursor', 'windsurf', 'zed', 'sublime_text', 'notepad++', 'idea64', 'pycharm64',
    'webstorm64', 'rider64', 'devenv', 'marktext', 'joplin'].includes(e)) return 'markdown';
  if (['winword', 'outlook', 'olk', 'hxoutlook', 'thunderbird', 'powerpnt', 'wordpad', 'soffice', 'swriter', 'mailspring'].includes(e)) return 'mail';
  if (['windowsterminal', 'wt', 'cmd', 'powershell', 'pwsh', 'conhost', 'wezterm-gui', 'alacritty', 'mintty', 'claude', 'chatgpt', 'openconsole'].includes(e)) return 'terminal';
  if (['whatsapp', 'whatsapp.root', 'slack', 'telegram', 'discord', 'signal', 'teams', 'ms-teams', 'element', 'threema'].includes(e)) return 'chat';
  return 'plain';
}

export function marker(kind: Kind, i: number, t: Target): string {
  const dot = t === 'mail' || t === 'chat';
  switch (kind) {
    case 'numbered': return `${i + 1}. `;
    case 'bullets': return dot ? '• ' : '- ';
    case 'checklist': return t === 'markdown' ? '- [ ] ' : dot ? '• ' : '- ';
  }
}

// MARK: hint at the end

export interface Prepared { text: string; hint: Hint; separated: boolean }

const HINT_PHRASES: [string, Hint][] = ([
  ['als checkliste', force('checklist')], ['als to-do-liste', force('checklist')], ['als todo-liste', force('checklist')],
  ['als todo liste', force('checklist')], ['als to-do liste', force('checklist')], ['als aufgabenliste', force('checklist')],
  ['als to-dos', force('checklist')], ['als todos', force('checklist')], ['as a checklist', force('checklist')],
  ['as checklist', force('checklist')], ['as a to-do list', force('checklist')], ['as a todo list', force('checklist')],
  ['als nummerierte liste', force('numbered')], ['als nummerierte aufzählung', force('numbered')], ['durchnummeriert', force('numbered')],
  ['nummeriert', force('numbered')], ['mit nummern', force('numbered')], ['as a numbered list', force('numbered')],
  ['numbered list', force('numbered')], ['numbered', force('numbered')],
  ['nicht als liste', SUPPRESS], ['keine liste', SUPPRESS], ['ohne liste', SUPPRESS], ['als fließtext', SUPPRESS],
  ['als ganzer satz', SUPPRESS], ['als satz', SUPPRESS], ['keine aufzählung', SUPPRESS], ['not as a list', SUPPRESS],
  ['no list', SUPPRESS], ['no bullets', SUPPRESS], ['as a sentence', SUPPRESS], ['as prose', SUPPRESS],
  ['als stichpunktliste', force(null)], ['als stichpunkte', force(null)], ['in stichpunkten', force(null)],
  ['als aufzählung', force(null)], ['als liste', force(null)], ['as a bulleted list', force(null)], ['as bullet points', force(null)],
  ['in bullet points', force(null)], ['as bullets', force(null)], ['as a list', force(null)], ['as list', force(null)],
] as [string, Hint][]).sort((a, b) => Array.from(b[0]).length - Array.from(a[0]).length);

/** case-insensitive suffix → start index, or -1 */
function suffixAt(s: string, w: string): number {
  if (s.length < w.length) return -1;
  const tail = s.slice(s.length - w.length);
  return tail.toLowerCase() === w.toLowerCase() ? s.length - w.length : -1;
}

export function stripHint(input: string): Prepared {
  let s = input.trim();
  while (s.length > 0 && '.!?'.includes(s[s.length - 1]!)) s = s.slice(0, -1);
  const dropWord = (w: string): boolean => {
    const at = suffixAt(s, w);
    if (at <= 0) return false;
    const before = s[at - 1]!;
    if (!(/\s/u.test(before) || ',.'.includes(before))) return false;
    s = trimSpaces(s.slice(0, at));
    return true;
  };
  void (dropWord('bitte') || dropWord('please'));
  s = trimChars(s, ' ,');
  for (const [p, h] of HINT_PHRASES) {
    const at = suffixAt(s, p);
    if (at < 0) continue;
    let rest = s.slice(0, at);
    const lc = lastChar(rest);
    if (lc !== undefined && (isLetter(lc) || isNumber(lc))) continue;
    rest = trimSpaces(rest);
    for (const w of ['bitte', 'please', 'und', 'and']) {
      const lr = rest.toLowerCase();
      if (lr.endsWith(' ' + w) || lr.endsWith(',' + w) || lr === w) rest = trimSpaces(rest.slice(0, rest.length - w.length));
    }
    const l2 = lastChar(rest);
    const sep = l2 !== undefined && ',.;:!?–—-'.includes(l2);
    rest = trimChars(rest, ' ,;–—-');
    if (rest.split(' ').filter(Boolean).length < 2) return { text: input, hint: NONE, separated: false };
    return { text: rest, hint: h, separated: sep };
  }
  return { text: input, hint: NONE, separated: false };
}

// MARK: entry (from QuickPolish.apply)

export interface PassResult { text: string; lists: number; hintUsed: boolean }

export function pass(s: string, target: Target, auto = true): PassResult {
  const prep = stripHint(s);
  if (prep.hint.t !== 'none') {
    if (prep.hint.t === 'suppress') {
      const wouldList = stage(prep.text, NONE, 'markdown')[1] > 0;
      const commas = Array.from(prep.text).filter((c) => c === ',').length;
      if (wouldList || (prep.separated && commas >= 1)) return { text: prep.text, lists: 0, hintUsed: true };
    } else {
      const [t, n] = stage(prep.text, prep.hint, target);
      if (n > 0) return { text: t, lists: n, hintUsed: true };
    }
  }
  if (!auto) return { text: s, lists: 0, hintUsed: false };
  const [t, n] = stage(s, NONE, target);
  return { text: t, lists: n, hintUsed: false };
}

function stage(s: string, hint: Hint, target: Target): [string, number] {
  if (hint.t === 'suppress') return [s, 0];
  const [t, n] = formatLists(s);
  if (n > 0) return [t, n];
  return format(s, hint, target);
}

/** only the automatic detection (without "erstens …") */
export function format(input: string, hint: Hint = NONE, target: Target = 'plain'): [string, number] {
  let isForced = false;
  let forcedKind: Kind | null = null;
  if (hint.t === 'force') { isForced = true; forcedKind = hint.kind; }
  if (hint.t === 'suppress') return [input, 0];
  const s = input.trim();
  if (!s || s.includes('\n') || looksLikeCode(s)) return [input, 0];
  const lower = s.toLowerCase();
  const sentences = Array.from(s).filter((c) => '.!?'.includes(c)).length;
  const commas = Array.from(s).filter((c) => c === ',').length;
  const seq = SEQ_HINTS.some((h) => lower.includes(h));
  if (!isForced && commas < 1 && !seq && sentences < 3 && !lower.includes(':')) return [input, 0];
  const lang = language(s);
  const t = tag(s, lang);
  if (t.length < 3) return [input, 0];
  const minItems = isForced ? 2 : target === 'chat' ? 4 : 3;
  const ctx = makeCtx(t, lang, minItems, isForced);
  let block = sequence(ctx) ?? imperativeRun(ctx);
  if (!block) {
    for (const [a, b] of ctx.sentences) { const bl = enumeration(ctx, a, b); if (bl) { block = bl; break; } }
  }
  if (!block && isForced) block = generic(ctx);
  if (!block) return [input, 0];
  const bl = block;
  if (forcedKind) bl.kind = forcedKind;
  const out = render(bl, ctx, target);
  if (!safe(s, out, bl.drops, bl.adds)) return [input, 0];
  if (!isForced && bl.end < t.length) {
    const restIn = joinT(t, bl.end, t.length);
    const [rest, n] = format(restIn, NONE, target);
    if (n > 0 && out.endsWith(restIn)) return [out.slice(0, out.length - restIn.length) + rest, 1 + n];
  }
  return [out, 1];
}

// MARK: words

export interface T { text: string; bare: string; lower: string; tag: Tag | null; lemma: string }
const comma = (w: T) => w.text.endsWith(',') || w.text.endsWith(';');
const colon = (w: T) => w.text.endsWith(':');
const capitalized = (w: T) => isUpper(w.bare[0]);
const ABBREVIATIONS = new Set(['z', 'b', 'bzw', 'usw', 'etc', 'ca', 'dr', 'nr', 'st', 'mr', 'mrs', 'ms', 'vs', 'inkl', 'evtl', 'ggf', 'bspw', 'prof']);
function endsSentence(w: T): boolean {
  const c = lastChar(w.text);
  if (c === undefined || !'.!?'.includes(c)) return false;
  if (c === '.') {
    const bl = Array.from(w.bare);
    if (ABBREVIATIONS.has(w.lower) || (bl.length === 1 && isLetter(bl[0]))) return false;
    if (bl.length > 0 && bl.length <= 2 && isAllDigits(w.bare)) return false;
  }
  return true;
}

interface Ctx { t: T[]; lang: Lang; minItems: number; forced: boolean; sentences: [number, number][]; de: boolean }
function makeCtx(t: T[], lang: Lang, minItems: number, forced: boolean): Ctx {
  const out: [number, number][] = [];
  let a = 0;
  t.forEach((w, i) => { if (endsSentence(w) || i === t.length - 1) { out.push([a, i + 1]); a = i + 1; } });
  return { t, lang, minItems, forced, sentences: out, de: lang === 'de' };
}
const sentenceOf = (c: Ctx, i: number): [number, number] => c.sentences.find(([a, b]) => a <= i && i < b) ?? [0, c.t.length];

interface Block { start: number; end: number; heading: string | null; items: string[]; kind: Kind; drops: Set<string>; adds: Set<string> }

const BARE_SET = ',.;:!?…–—"\'„“”»«()';
export const bare = (w: string) => trimChars(w, BARE_SET);

export function language(s: string): Lang { return detectLanguage(s); }

export function tag(s: string, lang: Lang): T[] {
  const raw = s.split(' ').filter(Boolean);
  const tagged = tagTokens(raw, lang);
  return raw.map((text, i) => {
    const b = bare(text);
    const lower = b.toLowerCase();
    return { text, bare: b, lower, tag: tagged[i]!.tag, lemma: tagged[i]!.tag ? tagged[i]!.lemma : lower };
  });
}

const looksLikeCode = (s: string) => s.includes('`') || s.includes('{') || s.includes('()') || s.includes('=>') || s.includes('==');
const joinT = (t: readonly T[], lo: number, hi: number) => t.slice(lo, hi).map((x) => x.text).join(' ');

// MARK: word lists

const S = (a: string[]) => new Set(a);
export const SEQ_HINTS = ['zuerst', 'als erstes', 'erstmal', 'erst mal', 'zunächst', 'first', 'to start', 'to begin'];
const SEQ_START = [['zuerst'], ['als', 'erstes'], ['erstmal'], ['erst', 'mal'], ['zunächst'], ['zu', 'beginn'],
  ['am', 'anfang'], ['first'], ['first', 'of', 'all'], ['firstly'], ['to', 'start'], ['to', 'begin'], ['start', 'by']];
const SEQ_MID = [['dann'], ['danach'], ['anschließend'], ['als', 'nächstes'], ['daraufhin'], ['im', 'anschluss'],
  ['then'], ['after', 'that'], ['next'], ['afterwards'], ['after', 'this']];
const SEQ_END = [['zum', 'schluss'], ['zuletzt'], ['schließlich'], ['am', 'ende'], ['abschließend'], ['am', 'schluss'],
  ['zu', 'guter', 'letzt'], ['finally'], ['lastly'], ['at', 'the', 'end'], ['last'], ['in', 'the', 'end']];

const CONJ = S(['und', 'and', 'sowie', 'plus', '&']);
const OR_CONJ = S(['oder', 'or']);
const COPULA = S(['sind', 'ist', 'lauten', 'umfassen', 'wären', 'are', 'is', 'include', 'includes', 'were']);
const SUBJECT_PRONOUNS = S(['ich', 'du', 'er', 'wir', 'ihr', 'man', 'i', 'we', 'he', 'she', 'they']);
const INV_PRONOUNS = S(['du', 'wir', 'ihr', 'ich', 'man', 'er', 'sie', 'es']);
const POSSESSIVES = S(['mein', 'meine', 'meinen', 'meinem', 'meiner', 'dein', 'deine', 'deinen', 'sein', 'seine', 'seinen',
  'unser', 'unsere', 'unseren', 'euer', 'eure', 'ihre', 'ihren', 'my', 'your', 'our', 'his', 'her', 'their']);
const STRIP_ARTICLES = S(['ein', 'eine', 'einen', 'einem', 'einer', 'der', 'die', 'das', 'den', 'dem', 'a', 'an', 'the', 'some']);
const MEASURE = S(['paar', 'bisschen', 'packung', 'flasche', 'flaschen', 'tüte', 'dose', 'dosen', 'glas', 'kiste', 'kasten', 'liter',
  'kilo', 'gramm', 'stück', 'pack', 'beutel', 'becher', 'bund', 'netz', 'pair', 'bottle', 'bottles', 'bag', 'box', 'can', 'jar', 'bunch',
  'couple', 'loaf', 'dozen', 'litre', 'pound', 'pounds', 'kg', 'g']);
const NEGATIONS = S(['kein', 'keine', 'keinen', 'keinem', 'nicht', 'no', 'not', 'never', 'nie']);
const ABSTRACT = S(['zeit', 'ruhe', 'geduld', 'liebe', 'kraft', 'hoffnung', 'mut', 'glück', 'hilfe', 'unterstützung', 'frieden',
  'freude', 'energie', 'schlaf', 'pause', 'laune', 'humor', 'spaß', 'motivation', 'vertrauen', 'glauben', 'glaube', 'gnade', 'segen', 'weisheit',
  'verständnis', 'respekt', 'stille', 'ehrlichkeit', 'fun', 'faith', 'trust', 'grace', 'wisdom', 'joy', 'hope', 'strength', 'attitude', 'mood', 'humour',
  'honesty', 'kindness', 'focus', 'fokus', 'zuversicht', 'demut', 'dankbarkeit', 'gratitude', 'break', 'nap', 'urlaub', 'time', 'patience', 'love', 'help',
  'support', 'peace', 'rest', 'energy', 'courage', 'sleep', 'luck', 'space']);
const PEOPLE = S(['freunde', 'freundin', 'freund', 'familie', 'nachbarn', 'kinder', 'eltern', 'kollegen', 'leute', 'mama', 'papa',
  'oma', 'opa', 'geschwister', 'friends', 'friend', 'family', 'neighbors', 'neighbours', 'kids', 'children', 'parents', 'colleagues', 'people', 'mom', 'dad']);
export function isAbstract(w: string): boolean {
  const n = Array.from(w).length;
  return ABSTRACT.has(w) || (n > 6 && (w.endsWith('heit') || w.endsWith('keit') || w.endsWith('schaft') || w.endsWith('ness')));
}
const TIME_WORDS = S(['heute', 'morgen', 'übermorgen', 'nachher', 'später', 'today', 'tomorrow', 'tonight', 'later']);
const PARTICLES = S(['ab', 'an', 'auf', 'zu', 'mit', 'ein', 'aus', 'los', 'weg', 'zurück', 'vorbei', 'raus', 'rein', 'hin', 'her']);
const SUBORDINATORS = S(['weil', 'damit', 'dass', 'wenn', 'falls', 'obwohl', 'because', 'since', 'although', 'unless', 'if', 'so']);
const LIGHT = S(['ich', 'wir', 'du', 'man', 'muss', 'müssen', 'musst', 'will', 'wollen', 'willst', 'möchte', 'möchten', 'sollte',
  'sollten', 'soll', 'sollen', 'gehe', 'geh', 'gehen', 'geht', 'noch', 'auch', 'mal', 'und', 'dann', 'jetzt', 'gleich', 'schnell', 'bitte', 'kurz',
  'zum', 'gerne', 'gern', 'unbedingt', 'bin', 'fahre', 'fahren', 'i', 'we', 'you', 'need', 'to', 'have', 'got', 'gotta', 'must', 'should', 'want',
  "i'll", "we'll", "i'm", 'going', 'go', 'still', 'also', 'just', 'quickly', 'please', 'and', 'then', 'some', 'for', 'the', 'am', 'are',
  "'m", 'gonna', 'run', 'head', 'out', 'off', 'a', 'few', 'things']);
const SHOP_WORDS = S(['einkaufen', 'kaufen', 'kaufe', 'kauf', 'kauft', 'kaufst', 'besorgen', 'besorge', 'besorg', 'holen',
  'hole', 'hol', 'einkauf', 'supermarkt', 'einkaufsliste', 'einkaufszettel', 'buy', 'shopping', 'groceries', 'grocery', 'pick', 'up', 'grab', 'get']);
const STORES = S(['rewe', 'aldi', 'lidl', 'edeka', 'netto', 'penny', 'kaufland', 'dm', 'rossmann', 'bäcker', 'markt', 'laden', 'supermarket', 'store']);
const PACK_WORDS = S(['einpacken', 'packen', 'pack', 'packe', 'koffer', 'packliste', 'rucksack', 'packing', 'suitcase', 'backpack']);
const TRIGGERS_BEFORE = S(['kaufen', 'kaufe', 'kauf', 'einkaufen', 'besorgen', 'besorge', 'besorg', 'holen', 'hole', 'hol',
  'mitnehmen', 'mitbringen', 'einpacken', 'packen', 'pack', 'packe', 'bestellen', 'bestelle', 'bestell', 'brauche', 'brauchen', 'brauchst',
  'braucht', 'benötige', 'benötigen', 'buy', 'grab', 'bring', 'order', 'need', 'needs', 'get']);
const WEAK_TRIGGERS = S(['brauche', 'brauchen', 'brauchst', 'braucht', 'benötige', 'benötigen', 'need', 'needs', 'get', 'bring', 'order']);
const TRIGGERS_AFTER = S(['kaufen', 'einkaufen', 'besorgen', 'holen', 'mitnehmen', 'mitbringen', 'einpacken', 'packen', 'bestellen']);
const PARTICLE_VERBS: Record<string, Set<string>> = {
  mit: S(['bringe', 'bring', 'bringst', 'bringen', 'bringt', 'nimm', 'nehme', 'nehmen', 'nimmst', 'nehmt']),
  ein: S(['pack', 'packe', 'packen', 'packst', 'kauf', 'kaufe', 'kaufen', 'packt']),
};
const HEAD_NOUNS: Record<string, Kind> = {
  agenda: 'bullets', tagesordnung: 'bullets', themen: 'bullets', punkte: 'bullets', einkaufsliste: 'bullets', einkaufszettel: 'bullets',
  packliste: 'bullets', zutaten: 'bullets', liste: 'bullets', programm: 'bullets', ablauf: 'numbered', optionen: 'bullets',
  ideen: 'bullets', fragen: 'bullets', ziele: 'bullets', 'prioritäten': 'numbered', schritte: 'numbered', reihenfolge: 'numbered',
  aufgaben: 'checklist', 'to-dos': 'checklist', todos: 'checklist', 'to-do-liste': 'checklist', 'todo-liste': 'checklist', 'to-do': 'checklist',
  topics: 'bullets', points: 'bullets', items: 'bullets', list: 'bullets', ingredients: 'bullets', options: 'bullets', ideas: 'bullets',
  questions: 'bullets', goals: 'bullets', priorities: 'numbered', steps: 'numbered', tasks: 'checklist', "to-do's": 'checklist',
  folgendes: 'bullets', following: 'bullets', setlist: 'bullets', setliste: 'bullets',
};
const headNoun = (w: string): Kind | undefined => (Object.prototype.hasOwnProperty.call(HEAD_NOUNS, w) ? HEAD_NOUNS[w] : undefined);
const ANY_HEADS = S(['setlist', 'setliste', 'lieder', 'songs', 'fragen', 'questions', 'agenda', 'tagesordnung', 'themen', 'topics', 'punkte', 'points', 'einladen', 'gäste', 'teilnehmer', 'guests', 'invite', 'attendees']);
const OR_HEADS = S(['optionen', 'options', 'ideen', 'ideas', 'alternativen', 'alternatives']);
const IMPERATIVE_DE = S(['kauf', 'kaufe', 'hol', 'hole', 'ruf', 'rufe', 'schick', 'schicke', 'schreib', 'schreibe', 'bring',
  'bringe', 'mach', 'mache', 'pack', 'packe', 'nimm', 'geh', 'sag', 'frag', 'check', 'prüf', 'prüfe', 'bestell', 'bestelle', 'buch', 'buche', 'lies',
  'schau', 'denk', 'vergiss', 'such', 'suche', 'besorg', 'besorge', 'antworte', 'erinner', 'erinnere', 'räum', 'räume', 'putz', 'bezahl', 'überweis',
  'meld', 'melde', 'plan', 'plane', 'trag', 'leg', 'stell', 'setz', 'lösch', 'speicher', 'sende', 'send', 'öffne', 'starte', 'start', 'teste', 'test',
  'installier', 'lad', 'lade', 'druck', 'drucke', 'unterschreib', 'gib', 'zahl', 'koch', 'koche', 'wasch', 'füll', 'sortier', 'markier', 'kopier',
  'informier', 'kontaktier', 'organisier', 'reservier', 'kündig', 'verschieb', 'beantworte', 'erledige', 'erledig', 'notier', 'lern', 'übe', 'gieß',
  'füttere', 'fütter', 'bereite', 'bereit', 'aktualisier', 'update', 'pushe', 'push', 'committe', 'bau', 'baue', 'fix', 'fixe', 'trink', 'iss',
  'wirf', 'bestätige', 'bestätig', 'schließ', 'schließe', 'dreh', 'spül', 'lüfte', 'sperr', 'schalt', 'schalte', 'kläre', 'klär', 'besuch',
  'hilf', 'zeig', 'zeige', 'stopp', 'guck', 'miete', 'miet', 'wechsel', 'wechsle', 'tausch', 'tausche', 'entsorge', 'entsorg', 'abonnier', 'erstelle', 'erstell', 'leite', 'leit', 'zieh', 'gieße', 'hör', 'hoer']);
const VERBS_EN = S(['book', 'call', 'email', 'text', 'check', 'fix', 'send', 'update', 'finish', 'water', 'feed', 'lock',
  'answer', 'prepare', 'clean', 'buy', 'pay', 'order', 'schedule', 'review', 'write', 'read', 'plan', 'pick', 'drop', 'get', 'take', 'make', 'do',
  'wash', 'cancel', 'renew', 'submit', 'file', 'print', 'sign', 'return', 'reply', 'test', 'deploy', 'push', 'merge', 'ship', 'set', 'start', 'stop',
  'open', 'close', 'restart', 'install', 'remove', 'delete', 'add', 'invite', 'ask', 'tell', 'remind', 'visit', 'walk', 'clear', 'empty', 'fill',
  'charge', 'back', 'upload', 'save', 'find', 'change', 'run', 'create', 'move', 'copy', 'paste', 'try', 'use', 'turn', 'click', 'notify', 'download', 'post', 'share', 'record', 'edit', 'finalize', 'draft', 'confirm', 'follow', 'meet', 'go', 'bring', 'grab']);
const AUX_EN = S(['is', 'are', 'am', 'was', 'were', 'be', 'do', 'does', 'did', 'can', 'could', 'will', 'would', 'shall',
  'should', 'may', 'might', 'must', 'have', 'has', 'had', "let's", 'lets', 'thank', 'thanks', 'sorry', 'hope', 'love', 'like', 'see']);
const AUX_DE = S(['ist', 'sind', 'war', 'waren', 'hat', 'haben', 'hatte', 'kann', 'können', 'muss', 'müssen', 'soll', 'sollen',
  'wird', 'werden', 'wurde', 'gibt', 'bin', 'bist', 'darf', 'möchte', 'will']);
const PAST_DE = S(['war', 'waren', 'warst', 'hatte', 'hatten', 'hattest', 'wurde', 'wurden', 'ging', 'gingen', 'kam', 'kamen',
  'gab', 'sah', 'sahen', 'machte', 'machten', 'sagte', 'fuhr', 'fuhren', 'aß', 'aßen', 'dachte', 'dachten', 'wollte', 'wollten', 'musste',
  'mussten', 'konnte', 'konnten', 'fand', 'stand', 'lief', 'liefen', 'saß', 'las', 'schrieb', 'rief', 'haben', 'hat', 'habe', 'hast', 'habt']);
const PAST_EN = S(['was', 'were', 'had', 'did', 'went', 'came', 'got', 'took', 'made', 'saw', 'ate', 'said', 'drove', 'left',
  'thought', 'found', 'bought', 'brought', 'felt', 'met', 'ran', 'sat', 'told', 'began']);

// MARK: word classes

const NOUN_TAGS: ReadonlySet<Tag> = new Set<Tag>(['noun', 'personalName', 'placeName', 'organizationName']);
function isNounish(w: T, c: Ctx, sentenceStart: boolean): boolean {
  if (w.tag && NOUN_TAGS.has(w.tag)) return true;
  if (c.de && capitalized(w) && !sentenceStart && !SUBJECT_PRONOUNS.has(w.lower) && w.lower !== 'sie') return true;
  if (!c.de && capitalized(w) && !sentenceStart && w.lower !== 'i') return true;
  return false;
}
function isVerb(w: T, c: Ctx, sentenceStart: boolean): boolean {
  if (w.tag !== 'verb') return false;
  if (c.de && capitalized(w) && !sentenceStart) return false;
  return true;
}
const infSuffix = (w: string) => w.endsWith('en') || w.endsWith('ern') || w.endsWith('eln');
function isInfinitive(w: T, c: Ctx): boolean {
  if (!(w.tag === 'verb' || (c.de && !capitalized(w) && infSuffix(w.lower)))) return false;
  if (c.de) return !capitalized(w) && (w.lower === w.lemma || infSuffix(w.lower));
  return true;
}

// ranges are [lo, hi)
type R = [number, number];
const rlen = (r: R) => r[1] - r[0];
const idx = (r: R) => { const a: number[] = []; for (let k = r[0]; k < r[1]; k++) a.push(k); return a; };

function chunks(c: Ctx, lo: number, hi: number, allowOr: boolean): { parts: R[]; conj: number } | null {
  if (!(lo < hi)) return null;
  const t = c.t;
  let parts: R[] = [];
  let s = lo;
  for (let k = lo; k < hi; k++) if (comma(t[k]!) && k < hi - 1) { parts.push([s, k + 1]); s = k + 1; }
  parts.push([s, hi]);
  const joiners = allowOr ? new Set([...CONJ, ...OR_CONJ]) : CONJ;
  let removed = 0;
  parts = parts.map((r) => {
    if (rlen(r) > 1 && joiners.has(t[r[0]]!.lower)) { removed++; return [r[0] + 1, r[1]] as R; }
    return r;
  });
  if (parts.length === 1) {
    const r = parts[0]!;
    const out: R[] = [];
    let a = r[0];
    for (let k = r[0]; k < r[1]; k++) if (joiners.has(t[k]!.lower) && k > a && k < r[1] - 1) { out.push([a, k]); a = k + 1; removed++; }
    out.push([a, r[1]]);
    parts = out;
  } else {
    const last = parts[parts.length - 1]!;
    let k = -1;
    for (let j = last[1] - 1; j >= last[0]; j--) if (joiners.has(t[j]!.lower)) { k = j; break; }
    if (k >= 0 && k > last[0] && k < last[1] - 1) {
      parts[parts.length - 1] = [last[0], k];
      parts.push([k + 1, last[1]]);
      removed++;
    }
  }
  if (!allowOr && parts.some((r) => idx(r).some((k) => OR_CONJ.has(t[k]!.lower)))) return null;
  if (!parts.every((r) => rlen(r) > 0)) return null;
  return { parts, conj: removed };
}

function isNounPhrase(c: Ctx, r: R, maxWords = 6): boolean {
  if (!(rlen(r) >= 1 && rlen(r) <= maxWords)) return false;
  const t = c.t;
  if (NEGATIONS.has(t[r[0]]!.lower)) return false;
  if (SUBORDINATORS.has(t[r[0]]!.lower)) return false;
  if (t[r[0]]!.tag === 'preposition') return false;
  let noun = false;
  const p = idx(r).find((k) => t[k]!.tag === 'preposition' && k > r[0]);
  if (p !== undefined && r[1] - p - 1 >= 3) return false;
  if (PARTICLES.has(t[r[1] - 1]!.lower)) return false;
  if (idx(r).some((k) => { const x = t[k]!; return !capitalized(x) && (TRIGGERS_BEFORE.has(x.lower) || TRIGGERS_AFTER.has(x.lower)); })) return false;
  if (idx(r).slice(1).some((k) => (t[k]!.tag === 'determiner' || STRIP_ARTICLES.has(t[k]!.lower)) && isNounish(t[k - 1]!, c, false))) return false;
  for (const k of idx(r)) {
    const w = t[k]!;
    if (isVerb(w, c, false)) {
      const objectFollows = k + 1 < r[1] && (t[k + 1]!.tag === 'determiner' || t[k + 1]!.tag === 'pronoun' || POSSESSIVES.has(t[k + 1]!.lower));
      if (c.de || AUX_EN.has(w.lower) || objectFollows) return false;
      const nounFollows = k + 1 < r[1] && isNounish(t[k + 1]!, c, false);
      if (w.lower.endsWith('ed') && !nounFollows) return false;
      if (w.lemma !== w.lower && !w.lower.endsWith('ing') && !w.lower.endsWith('ed')) return false;
      if (rlen(r) === 1 || w.lower.endsWith('ing')) noun = true;
      continue;
    }
    if (w.tag === 'pronoun' && !POSSESSIVES.has(w.lower) && !STRIP_ARTICLES.has(w.lower) && !(c.de && capitalized(w))) return false;
    if (isNounish(w, c, false) || (w.bare.length > 0 && isAllDigits(w.bare) && rlen(r) === 1)) noun = true;
  }
  return noun;
}

function isVerbPhrase(c: Ctx, r: R): boolean {
  if (!(rlen(r) >= 1 && rlen(r) <= 10)) return false;
  const t = c.t;
  if (NEGATIONS.has(t[r[0]]!.lower) || SUBORDINATORS.has(t[r[0]]!.lower)) return false;
  if (idx(r).some((k) => SUBJECT_PRONOUNS.has(t[k]!.lower))) return false;
  if (c.de) {
    if (!isInfinitive(t[r[1] - 1]!, c)) return false;
    return !idx(r).slice(0, -1).some((k) => isVerb(t[k]!, c, false) && t[k]!.lower !== t[k]!.lemma && !t[k]!.lower.endsWith('en'));
  }
  let first = r[0];
  if (t[first]!.lower === 'to' && rlen(r) > 1) first++;
  const w = t[first]!;
  if (w.lower === 'do' && first + 1 < r[1] && (t[first + 1]!.tag === 'determiner' || POSSESSIVES.has(t[first + 1]!.lower))) return true;
  if (AUX_EN.has(w.lower)) return false;
  if (VERBS_EN.has(w.lower) && (rlen(r) >= 2 || w.tag === 'verb')) return true;
  return w.tag === 'verb' && (w.lemma === w.lower || w.lower === 'do');
}

function heading(c: Ctx, r: R, extra: string[], checklist: boolean, verbatim: boolean, drops: Set<string>, adds: Set<string>):
  { h: string | null; shop: boolean; pack: boolean } {
  const t = c.t;
  const words = [...idx(r).map((k) => t[k]!.lower), ...extra.map((x) => x.toLowerCase())];
  const shop = words.some((w) => SHOP_WORDS.has(w) || STORES.has(w)) && !(words.includes('get') && !words.includes('groceries') && !words.includes('shopping') && !words.includes('store'));
  const pack = !shop && words.some((w) => PACK_WORDS.has(w));
  const isLight = words.every((w) => LIGHT.has(w) || SHOP_WORDS.has(w) || PACK_WORDS.has(w) || TIME_WORDS.has(w)
    || TRIGGERS_BEFORE.has(w) || TRIGGERS_AFTER.has(w) || w === 'mit' || w === 'ein' || w === 'zu');
  const times = idx(r).map((k) => t[k]!).filter((x) => TIME_WORDS.has(x.lower)).map((x) => x.lower);
  const label = (l: string) => {
    for (const k of idx(r)) drops.add(t[k]!.lower);
    for (const w of extra) drops.add(w.toLowerCase());
    for (const w of l.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean)) adds.add(w);
    return times.length === 0 ? l + ':' : l + ' (' + times.join(' ') + '):';
  };
  if (isLight && !verbatim) {
    if (checklist) return { h: label('To-dos'), shop, pack };
    if (shop) return { h: label(c.de ? 'Einkaufen' : 'Shopping'), shop, pack };
    if (pack) return { h: label(c.de ? 'Packliste' : 'Packing list'), shop, pack };
  }
  if (rlen(r) === 0 && extra.length === 0) return { h: null, shop, pack };
  let h = [...idx(r).map((k) => t[k]!.text), ...extra].join(' ');
  h = trimChars(h, ' ,;:.–—-');
  h = capFirst(h);
  return { h: h.length === 0 ? null : h + ':', shop, pack };
}

function itemText(c: Ctx, r0: R, stripArticle: boolean, drops: Set<string>, keepIndefinite = false): string {
  let r = r0;
  const t = c.t;
  const indefinite = S(['ein', 'eine', 'einen', 'einem', 'einer', 'a', 'an']);
  if (stripArticle && rlen(r) === 2 && STRIP_ARTICLES.has(t[r[0]]!.lower) && !(keepIndefinite && indefinite.has(t[r[0]]!.lower))
    && !MEASURE.has(t[r[0] + 1]!.lower) && isNounish(t[r[0] + 1]!, c, false)) {
    drops.add(t[r[0]]!.lower);
    r = [r[0] + 1, r[1]];
  }
  let s = trimChars(joinT(t, r[0], r[1]), ' ,;:.!?');
  const fw = s.split(' ').filter(Boolean)[0];
  const innerUpper = fw !== undefined && Array.from(fw).slice(1).some((ch) => isUpper(ch));
  if (s.length > 0 && !innerUpper) s = capFirst(s);
  return s;
}

function firstItemStart(c: Ctx, r: R): number | null {
  const t = c.t;
  let s = r[1] - 1;
  let nouns = 0;
  while (s >= r[0]) {
    const x = t[s]!;
    if (isNounish(x, c, s === sentenceOf(c, s)[0]) && !(c.de && s === r[0] && x.tag === 'verb')) {
      if (nouns >= 1 && !MEASURE.has(x.lower)) break;
      nouns++; s--; continue;
    }
    if (x.tag === 'determiner' || x.tag === 'adjective' || x.tag === 'number' || POSSESSIVES.has(x.lower) || MEASURE.has(x.lower)
      || NUMBER_WORDS.has(x.lower) || (x.bare.length > 0 && isAllDigits(x.bare))) {
      if (STRIP_ARTICLES.has(x.lower) || x.tag === 'determiner') { s--; break; }
      s--; continue;
    }
    break;
  }
  if (nouns < 1) return null;
  return s + 1;
}

type ItemType = 'noun' | 'verbPhrase' | 'any' | null;

function enumeration(c: Ctx, a: number, b: number): Block | null {
  const t = c.t;
  if (b - a < 3) return null;
  if (t[b - 1]!.text.endsWith('?') && !c.forced) return null;
  const drops = new Set<string>([...CONJ, ...OR_CONJ]);
  const adds = new Set<string>();

  const build = (hr0: R, lo: number, hi: number, kind: Kind, type: ItemType,
    o: { extra?: string[]; allowOr?: boolean; weak?: boolean; trigger?: boolean; splitFirst?: boolean; verbatim?: boolean } = {}): Block | null => {
    const extra = o.extra ?? [];
    const ch = chunks(c, lo, hi, o.allowOr ?? false);
    if (!ch || ch.parts.length < c.minItems) return null;
    const parts = ch.parts.map((p) => [p[0], p[1]] as R);
    let hr: R = [hr0[0], hr0[1]];
    if (o.splitFirst && !isNounPhrase(c, parts[0]!)) {
      const s = firstItemStart(c, parts[0]!);
      if (s !== null && s > parts[0]![0] && !idx([hr[0], s]).some((k) => colon(t[k]!))) {
        hr = [hr[0], s];
        parts[0] = [s, parts[0]![1]];
      }
    }
    const isNP = parts.every((p) => isNounPhrase(c, p));
    const isVP = parts.every((p) => isVerbPhrase(c, p)) && parts.some((p) => rlen(p) >= 2);
    let k = kind;
    switch (type) {
      case 'noun': if (!isNP) return null; break;
      case 'verbPhrase': if (!isVP) return null; break;
      case 'any': if (!parts.every((p) => rlen(p) <= 8)) return null; break;
      case null:
        if (!(isNP || isVP)) return null;
        if (isVP && !isNP && kind === 'bullets') k = 'checklist';
    }
    if (o.weak || o.trigger) {
      const heads = parts.map((p) => t[p[1] - 1]!.lower);
      if (heads.filter((h) => isAbstract(h)).length >= 2) return null;
      const lastLemmas = parts.filter((p) => rlen(p) >= 2).map((p) => t[p[1] - 1]!.lemma);
      if (lastLemmas.length >= 2 && new Set(lastLemmas).size < lastLemmas.length) return null;
      const indefinite = S(['a', 'an', 'ein', 'eine', 'einen']);
      if (o.weak && parts.length < 4 && idx(hr0).every((q) => LIGHT.has(t[q]!.lower) || TRIGGERS_BEFORE.has(t[q]!.lower))
        && parts.filter((p) => indefinite.has(t[p[0]]!.lower)).length >= 2) return null;
    }
    if (o.trigger && parts.filter((p) => idx(p).some((q) => t[q]!.tag === 'personalName' || PEOPLE.has(t[q]!.lower))).length >= 2) return null;
    const d = new Set(drops), ad = new Set(adds);
    const hd = heading(c, hr, extra, k === 'checklist' && isVP, o.verbatim ?? false, d, ad);
    const quantities = parts.some((p) => { const x = t[p[0]]!; return (NUMBER_WORDS.has(x.lower) && !STRIP_ARTICLES.has(x.lower)) || isNumber(x.bare[0]); });
    const items = parts.map((p) => itemText(c, p, hd.shop || hd.pack, d, quantities));
    return { start: a, end: b, heading: hd.h, items, kind: k, drops: d, adds: ad };
  };

  // 1) colon / head noun
  let colonAt: number | null = null;
  for (let q = a; q < b - 1; q++) if (colon(t[q]!)) { colonAt = q; break; }
  for (let i = a; i < b - 1; i++) {
    const w = t[i]!;
    const head = headNoun(w.lower) ?? headNoun(w.lemma);
    const top = w.lower === 'top' && i + 1 < b && (/^-?\d+$/u.test(t[i + 1]!.bare) || NUMBER_WORDS.has(t[i + 1]!.lower));
    const ranking = top || t.slice(a, i).some((x) => ['rangliste', 'ranking', 'reihenfolge', 'order'].includes(x.lower));
    if (colon(w)) {
      const hr: R = [a, i + 1];
      const heads = idx(hr).map((q) => headNoun(t[q]!.lower) ?? headNoun(t[q]!.lemma)).filter((x): x is Kind => !!x);
      const hk: Kind = ranking ? 'numbered' : (heads[0] ?? 'bullets');
      const allowOr = idx(hr).some((q) => OR_HEADS.has(t[q]!.lower));
      const fixedHead = heads.length > 0 || idx(hr).some((q) => ANY_HEADS.has(t[q]!.lower));
      const bl = build(hr, i + 1, b, hk, null, { allowOr, verbatim: true });
      if (bl) return bl;
      if (fixedHead) { const bl2 = build(hr, i + 1, b, hk, 'any', { allowOr, verbatim: true }); if (bl2) return bl2; }
      break;
    }
    if ((head !== undefined || top) && (colonAt === null || colonAt < i)) {
      for (let j = i + 1; j < Math.min(i + 6, b - 1); j++) {
        if (!COPULA.has(t[j]!.lower)) continue;
        drops.add(t[j]!.lower);
        const k: Kind = ranking ? 'numbered' : (head ?? 'bullets');
        const allowOr = OR_HEADS.has(w.lower);
        const bl = build([a, j], j + 1, b, k, k === 'checklist' || k === 'numbered' ? null : 'noun', { allowOr, verbatim: true });
        if (bl) return bl;
        if (ANY_HEADS.has(w.lower)) { const bl2 = build([a, j], j + 1, b, k, 'any', { allowOr, verbatim: true }); if (bl2) return bl2; }
        drops.delete(t[j]!.lower);
        break;
      }
    }
  }

  // 2) tasks
  const modalsDE = S(['muss', 'müssen', 'musst', 'sollte', 'sollten', 'sollst']);
  for (let i = a; i < b - 2; i++) {
    const w = t[i]!;
    let lo: number | null = null;
    if (c.de && modalsDE.has(w.lower)) {
      let j = i + 1;
      if (j < b && SUBJECT_PRONOUNS.has(t[j]!.lower)) j++;
      while (j < b && ['noch', 'heute', 'morgen', 'unbedingt', 'mal', 'auch', 'dringend', 'diese', 'woche', 'bis', 'freitag', 'gleich'].includes(t[j]!.lower)) j++;
      lo = j;
    } else if (!c.de && ['need', 'have', 'gotta', 'must', 'should'].includes(w.lower)) {
      let j = i + 1;
      if (w.lower !== 'gotta' && w.lower !== 'must' && w.lower !== 'should') { if (!(j < b && t[j]!.lower === 'to')) continue; j++; }
      lo = j;
    }
    if (lo === null || !(lo < b)) continue;
    const subj = (i > a && SUBJECT_PRONOUNS.has(t[i - 1]!.lower)) || (i + 1 < b && SUBJECT_PRONOUNS.has(t[i + 1]!.lower))
      || (i > a + 1 && SUBJECT_PRONOUNS.has(t[i - 2]!.lower) && ['still', 'really', 'also', 'just', 'noch', 'auch'].includes(t[i - 1]!.lower));
    if (!subj) continue;
    const bl = build([a, lo], lo, b, 'checklist', 'verbPhrase');
    if (bl) return bl;
  }

  // 2b) "Don't forget to …", "Vergiss nicht, …"
  for (let i = a; i < b - 2; i++) {
    let lo: number | null = null;
    if (!c.de && ["don't", 'dont'].includes(t[i]!.lower) && t[i + 1]!.lower === 'forget' && i + 2 < b && t[i + 2]!.lower === 'to') lo = i + 3;
    if (c.de && ['vergiss', 'vergesst'].includes(t[i]!.lower) && t[i + 1]!.lower === 'nicht') lo = i + 2;
    if (lo !== null && lo < b) { const bl = build([a, lo], lo, b, 'checklist', 'verbPhrase'); if (bl) return bl; }
  }

  // 3) trigger before
  const fillers = S(['noch', 'auch', 'mal', 'unbedingt', 'bitte', 'folgendes', 'folgende', 'so', 'also', 'some', 'still', 'heute', 'morgen', 'today', 'tomorrow']);
  for (let i = a; i < b - 2; i++) {
    const w = t[i]!;
    let isTrig = TRIGGERS_BEFORE.has(w.lower);
    let endTrig = i;
    if (!c.de && w.lower === 'pick' && i + 1 < b && t[i + 1]!.lower === 'up') { isTrig = true; endTrig = i + 1; }
    if (!isTrig || comma(w)) continue;
    if (!c.de) {
      if ((w.lower === 'need' || w.lower === 'needs') && i + 1 < b && t[i + 1]!.lower === 'to') continue;
      if (w.lower === 'get' && !(i === a || ['to', 'gotta', 'please', 'and'].includes(t[i - 1]!.lower))) continue;
    }
    const pastAux = c.de ? ['habe', 'hab', 'hatte', 'hatten', 'haben', 'hast'] : ['had', 'have', 'has'];
    if (t.slice(a, i).some((x) => pastAux.includes(x.lower))) continue;
    let lo = endTrig + 1;
    while (lo < b && fillers.has(t[lo]!.lower) && !colon(t[lo - 1]!)) lo++;
    const weak = WEAK_TRIGGERS.has(w.lower);
    const bl = build([a, lo], lo, b, 'bullets', 'noun', { weak, trigger: true, splitFirst: true });
    if (bl) return bl;
  }

  // 4) trigger at the end
  const last = t[b - 1]!;
  let trigEnd: number[] = [];
  if (c.de && TRIGGERS_AFTER.has(last.lower)) { trigEnd = [b - 1]; if (b - 2 > a && t[b - 2]!.lower === 'zu') trigEnd = [b - 2, b - 1]; }
  const pv = PARTICLE_VERBS[last.lower];
  if (c.de && pv && t.slice(a, b - 1).some((x) => pv.has(x.lower))) trigEnd = [b - 1];
  const first = trigEnd[0];
  if (first !== undefined && first - a >= 3) {
    let cm = -1;
    for (let q = a; q < first; q++) if (comma(t[q]!)) { cm = q; break; }
    if (cm < 0) return null;
    const itemStart = firstItemStart(c, [a, cm + 1]);
    if (itemStart === null) return null;
    const extra = trigEnd.map((q) => t[q]!.bare);
    const bl = build([a, itemStart], itemStart, first, 'bullets', 'noun', { extra, trigger: true });
    if (bl) return bl;
  }
  return null;
}

// MARK: order

function matchMarker(c: Ctx, i: number, list: string[][]): number | null {
  let best: number | null = null;
  for (const m of list) {
    if (i + m.length > c.t.length) continue;
    if (m.every((w, k) => c.t[i + k]!.lower === w)) {
      let bad = false;
      for (let k = 0; k < m.length - 1; k++) { const ch = lastChar(c.t[i + k]!.text); if (ch !== undefined && ',.;:!?'.includes(ch)) bad = true; }
      if (bad) continue;
      if (best === null || m.length > best) best = m.length;
    }
  }
  return best;
}

function clauseStart(c: Ctx, i: number): { ok: boolean; conj: boolean } {
  if (i === 0) return { ok: true, conj: false };
  const p = c.t[i - 1]!;
  const ch = lastChar(p.text);
  if (ch !== undefined && ',.;:!?'.includes(ch)) return { ok: true, conj: false };
  if (CONJ.has(p.lower)) return { ok: true, conj: true };
  return { ok: false, conj: false };
}

function sequence(c: Ctx): Block | null {
  const t = c.t;
  let start: { i: number; len: number } | null = null;
  for (let i = 0; i < t.length; i++) {
    const n = matchMarker(c, i, SEQ_START);
    if (n !== null && clauseStart(c, i).ok) {
      const [sa] = sentenceOf(c, i);
      if (i === sa || colon(t[i - 1]!)) { start = { i, len: n }; break; }
    }
  }
  if (!start) return null;
  const st = start;
  const marks: { i: number; len: number; conj: boolean }[] = [{ i: st.i, len: st.len, conj: false }];
  let hasEnd = false;
  let k = st.i + st.len;
  while (k < t.length) {
    const cs = clauseStart(c, k);
    if (cs.ok) { const n = matchMarker(c, k, SEQ_END); if (n !== null) { marks.push({ i: k, len: n, conj: cs.conj }); hasEnd = true; break; } }
    if (cs.ok) { const n = matchMarker(c, k, SEQ_MID); if (n !== null) { marks.push({ i: k, len: n, conj: cs.conj }); k += n; continue; } }
    k++;
  }
  if (marks.length < Math.max(3, c.minItems)) return null;
  if (!(hasEnd || marks.length >= 4 || c.forced)) return null;
  const lastSentenceEnd = sentenceOf(c, marks[marks.length - 1]!.i)[1];
  const steps: R[] = [];
  for (let n = 0; n < marks.length; n++) {
    const m = marks[n]!;
    const from = m.i + m.len;
    let to = n + 1 < marks.length ? marks[n + 1]!.i - (marks[n + 1]!.conj ? 1 : 0) : lastSentenceEnd;
    while (to > from && CONJ.has(t[to - 1]!.lower)) to--;
    if (!(to > from && to - from <= 25)) return null;
    steps.push([from, to]);
  }
  const all = t.slice(st.i, lastSentenceEnd);
  const past = c.de ? all.some((x) => PAST_DE.has(x.lower))
    : all.some((x) => PAST_EN.has(x.lower) || (x.tag === 'verb' && x.lower.endsWith('ed') && x.lemma !== x.lower));
  if (past) return null;
  const keep = c.de && steps.some((r) => rlen(r) >= 2 && t[r[0]]!.tag === 'verb' && INV_PRONOUNS.has(t[r[0] + 1]!.lower));
  const drops = new Set<string>(CONJ);
  const items: string[] = [];
  steps.forEach((r, n) => {
    const m = marks[n]!;
    if (keep) {
      const words = [...t.slice(m.i, m.i + m.len).map((x) => trimChars(x.text, ',')), ...t.slice(r[0], r[1]).map((x) => x.text)];
      if (words.length > 0) words[0] = capFirst(words[0]!);
      items.push(trimChars(words.join(' '), ' ,;:.!?'));
    } else {
      for (const x of t.slice(m.i, m.i + m.len)) drops.add(x.lower);
      items.push(itemText(c, r, false, drops));
    }
  });
  const [sa] = sentenceOf(c, st.i);
  let startTok = st.i;
  let head: string | null = null;
  if (st.i > sa && colon(t[st.i - 1]!)) {
    startTok = sa;
    head = trimChars(joinT(t, sa, st.i), ' :') + ':';
  } else if (st.i > 0 && colon(t[st.i - 1]!)) {
    const [pa] = sentenceOf(c, st.i - 1);
    startTok = pa;
    head = trimChars(joinT(t, pa, st.i), ' :') + ':';
  } else if (st.i === sa && sa > 0) {
    const [pa, pb] = sentenceOf(c, sa - 1);
    if (pa === 0 && pb - pa <= 7 && t[pb - 1]!.text.endsWith('.')) {
      startTok = 0;
      head = trimChars(joinT(t, pa, pb), ' .') + ':';
    }
  }
  return { start: startTok, end: lastSentenceEnd, heading: head, items, kind: 'numbered', drops, adds: new Set() };
}

// MARK: imperatives in a row

function isImperative(c: Ctx, a: number, b: number): boolean {
  const t = c.t;
  if (!(b - a >= 2 && b - a <= 15)) return false;
  if (t[b - 1]!.text.endsWith('?')) return false;
  let i = a;
  if (['bitte', 'please', 'und', 'and', 'dann', 'then'].includes(t[i]!.lower)) i++;
  if (!(i < b - 1)) return false;
  const w = t[i]!;
  if (b - i === 2 && !isNounish(t[i + 1]!, c, false)) return false;
  if (c.de) {
    if (AUX_DE.has(w.lower)) return false;
    if (INV_PRONOUNS.has(t[i + 1]!.lower) || t[i + 1]!.lower === 'sie') return false;
    if (IMPERATIVE_DE.has(w.lower)) return true;
    const lem = w.lemma;
    if (lem.endsWith('en') && Array.from(lem).length > 4 && (w.lower === lem.slice(0, -2) || w.lower === lem.slice(0, -1))) return true;
    return w.tag === 'verb' && w.lemma !== w.lower && !w.lower.endsWith('st') && !w.lower.endsWith('t');
  }
  if (AUX_EN.has(w.lower) || ['i', 'we', 'you', 'he', 'she', 'they', 'it'].includes(t[i + 1]!.lower)) return false;
  return (w.tag === 'verb' && w.lemma === w.lower) || VERBS_EN.has(w.lower);
}

function imperativeRun(c: Ctx): Block | null {
  const ss = c.sentences;
  if (ss.length < c.minItems) return null;
  let runStart = -1;
  let best: [number, number] | null = null;
  ss.forEach((s, n) => {
    if (isImperative(c, s[0], s[1])) {
      if (runStart < 0) runStart = n;
      if (n - runStart + 1 >= c.minItems && (best === null || n - runStart > best[1] - best[0])) best = [runStart, n];
    } else runStart = -1;
  });
  if (!best) return null;
  const [lo, hi] = best as [number, number];
  const t = c.t;
  const drops = new Set<string>();
  const items = ss.slice(lo, hi + 1).map((s) => itemText(c, [s[0], s[1]], false, drops));
  let start = ss[lo]![0];
  let head: string | null = null;
  if (lo > 0 && colon(t[ss[lo - 1]![1] - 1]!)) {
    start = ss[lo - 1]![0];
    head = joinT(t, ss[lo - 1]![0], ss[lo - 1]![1]);
  }
  return { start, end: ss[hi]![1], heading: head, items, kind: 'bullets', drops, adds: new Set() };
}

// MARK: forced ("als Liste") without a pattern

function generic(c: Ctx): Block | null {
  const t = c.t;
  let best: [number, number, R[]] | null = null;
  for (const [a, b] of c.sentences) {
    let lo = a;
    for (let q = a; q < b; q++) if (colon(t[q]!)) { lo = q + 1; break; }
    const ch = chunks(c, lo, b, true);
    if (!ch || ch.parts.length < 2) continue;
    if (best === null || ch.parts.length > best[2].length) best = [a, b, ch.parts];
  }
  const drops = new Set<string>([...CONJ, ...OR_CONJ]);
  if (best) {
    const [a, b] = best;
    const parts = best[2].map((p) => [p[0], p[1]] as R);
    let hr: R = [a, parts[0]![0]];
    if (rlen(hr) === 0 && rlen(parts[0]!) > 3) {
      const r = parts[0]!;
      let kk = -1;
      for (let q = r[1] - 1; q >= r[0]; q--) if (isNounish(t[q]!, c, q === a)) { kk = q; break; }
      if (kk > r[0]) {
        let s = kk;
        while (s > r[0] && (t[s - 1]!.tag === 'determiner' || t[s - 1]!.tag === 'adjective' || t[s - 1]!.tag === 'number')) s--;
        if (s > r[0]) { hr = [r[0], s]; parts[0] = [s, r[1]]; }
      }
    }
    const adds = new Set<string>();
    const hd = heading(c, hr, [], false, false, drops, adds);
    const items = parts.map((p) => itemText(c, p, false, drops));
    return { start: a, end: b, heading: hd.h, items, kind: 'bullets', drops, adds };
  }
  const ss = c.sentences;
  if (ss.length < 2) return null;
  const items = ss.map((s) => itemText(c, [s[0], s[1]], false, drops));
  return { start: 0, end: t.length, heading: null, items, kind: 'bullets', drops, adds: new Set() };
}

// MARK: output + word check

function render(b: Block, c: Ctx, target: Target): string {
  const parts: string[] = [];
  if (b.start > 0) parts.push(joinT(c.t, 0, b.start));
  let list = b.items.map((x, i) => marker(b.kind, i, target) + x).join('\n');
  if (b.heading !== null) list = b.heading + '\n' + list;
  parts.push(list);
  if (b.end < c.t.length) parts.push(joinT(c.t, b.end, c.t.length));
  return parts.join('\n\n');
}

export const words = (s: string) => s.toLowerCase().split(/[^\p{L}\p{M}\p{Nd}]+/u).filter(Boolean);

export function safe(input: string, output: string, drops: Set<string>, adds: Set<string>): boolean {
  const have = new Map<string, number>();
  for (const w of words(input)) have.set(w, (have.get(w) ?? 0) + 1);
  const got = new Map<string, number>();
  for (const w of words(output)) got.set(w, (got.get(w) ?? 0) + 1);
  for (const [w, n] of got) {
    if (n > (have.get(w) ?? 0)) {
      if (adds.has(w) || (/^\p{N}+$/u.test(w) && Number.parseInt(w, 10) <= 30)) continue;
      return false;
    }
  }
  const dropParts = new Set([...drops].flatMap((d) => words(d)));
  for (const [w, n] of have) {
    if (n > (got.get(w) ?? 0)) {
      if (dropParts.has(w)) continue;
      return false;
    }
  }
  return true;
}
