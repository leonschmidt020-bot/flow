// Agent-Prompt – pure logic (no UI, no AI, no Electron). Port of APCore.swift (Flow for macOS 1.7.17).
//
//   match("Prompt: bau mir …")                → trigger recognised, rest = the dictation for the prompt (trigger removed)
//   detect({ text, duration, app, title })    → score + reasons: does this look like a long task for an agent?
//   structure(text, context)                  → fallback without Claude: sort the sentences into goal/context/task/…
//   gistOf(prompt)                            → short line for the card („Ziel … · 5 Anforderungen“)
//
// Windows: the Mac's bundle ids become process names ("Code.exe", "WindowsTerminal.exe"); see appCategory().
import * as QuickPolish from '../core/quickPolish';
import { tidy } from '../core/textCleaner';
import { language } from '../core/tagger';
import { all, ci, count, first, icu, replaceAll } from './regex';

// MARK: - text helpers

export const words = (s: string): number => s.split(/\s+/u).filter((w) => w.length > 0).length;

export function capFirst(s: string): string {
  const f = s.codePointAt(0);
  if (f === undefined) return s;
  const c = String.fromCodePoint(f);
  if (!/\p{Ll}/u.test(c)) return s;
  return c.toUpperCase() + s.slice(c.length);
}

/** Swift `trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))` */
const trimWsPunct = (s: string) => s.replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, '');
/** Swift `trimmingCharacters(in: CharacterSet(charactersIn: set))` */
function trimSet(s: string, set: string): string {
  const a = Array.from(s);
  let lo = 0, hi = a.length;
  while (lo < hi && set.includes(a[lo]!)) lo++;
  while (hi > lo && set.includes(a[hi - 1]!)) hi--;
  return a.slice(lo, hi).join('');
}

/** language of the dictation (DE/EN only) – for headings and the instruction to Claude */
export function isEnglish(s: string): boolean {
  const t = s.toLowerCase();
  const de = count(icu(String.raw`\b(und|der|die|das|ich|nicht|bitte|ist|mit|auf|für|dass|wir|soll|auch|mal|noch|den|dem|ein|eine|einen)\b`), t);
  const en = count(icu(String.raw`\b(and|the|is|i|not|please|with|for|that|we|should|also|this|to|of|a|an|it|you)\b`), t);
  if (de + en < 3) return language(s) === 'en';
  return en > de * 2;
}

// MARK: - target app (Windows process names)

export type AppCategory = 'personal' | 'work' | 'email' | 'ai' | 'other';

const exeBase = (exe: string) => (exe.toLowerCase().split(/[\\/]/u).pop() ?? '').replace(/\.exe$/u, '');

const CAT_PERSONAL = new Set(['whatsapp', 'whatsapp.root', 'telegram', 'discord', 'signal', 'messenger', 'instagram', 'threema', 'element']);
const CAT_WORK = new Set(['slack', 'teams', 'ms-teams', 'notion', 'linear', 'zoom', 'clickup', 'jira']);
const CAT_EMAIL = new Set(['outlook', 'olk', 'hxoutlook', 'thunderbird', 'mailspring', 'em client', 'mailbird']);
/** agent/terminal apps (Mac: Claude, ChatGPT, VS Code, Cursor, Antigravity, Windsurf, Terminal, iTerm2, Ghostty) */
const CAT_AI = new Set(['claude', 'chatgpt', 'code', 'code - insiders', 'cursor', 'antigravity', 'windsurf', 'windowsterminal', 'wt',
  'openconsole', 'cmd', 'powershell', 'pwsh', 'conhost', 'wezterm-gui', 'alacritty', 'mintty', 'ghostty', 'warp', 'tabby', 'hyper']);

/** AppCategory.of(bundleID:) for Windows process names */
export function appCategory(exe: string): AppCategory {
  const e = exeBase(exe);
  if (!e) return 'other';
  if (CAT_PERSONAL.has(e)) return 'personal';
  if (CAT_WORK.has(e)) return 'work';
  if (CAT_EMAIL.has(e)) return 'email';
  if (CAT_AI.has(e)) return 'ai';
  return 'other';
}

const APP_NAMES: Record<string, string> = {
  code: 'Visual Studio Code', 'code - insiders': 'Visual Studio Code Insiders', cursor: 'Cursor', windsurf: 'Windsurf', antigravity: 'Antigravity',
  windowsterminal: 'Terminal', wt: 'Terminal', openconsole: 'Terminal', cmd: 'Eingabeaufforderung', powershell: 'PowerShell', pwsh: 'PowerShell',
  claude: 'Claude', chatgpt: 'ChatGPT', chrome: 'Google Chrome', msedge: 'Microsoft Edge', firefox: 'Firefox', brave: 'Brave', arc: 'Arc',
  slack: 'Slack', 'ms-teams': 'Microsoft Teams', teams: 'Microsoft Teams', outlook: 'Outlook', olk: 'Outlook', winword: 'Word',
  notepad: 'Editor', 'notepad++': 'Notepad++', obsidian: 'Obsidian', notion: 'Notion', whatsapp: 'WhatsApp', 'wezterm-gui': 'WezTerm',
  alacritty: 'Alacritty', idea64: 'IntelliJ IDEA', pycharm64: 'PyCharm', webstorm64: 'WebStorm', devenv: 'Visual Studio', zed: 'Zed',
};
/** friendly app name for a process ("Code.exe" → "Visual Studio Code") */
export function appName(exe: string): string {
  const e = exeBase(exe);
  if (!e) return '';
  return APP_NAMES[e] ?? (exe.split(/[\\/]/u).pop() ?? exe).replace(/\.exe$/iu, '');
}

// MARK: - triggers („Prompt: …“, „Ich mache jetzt einen Prompt …“, „… mach daraus einen Prompt“)

export interface TriggerMatch {
  /** dictation without the trigger (first letter upper case) */
  body: string;
  /** what was recognised as the trigger (log/tests) */
  phrase: string;
  atEnd: boolean;
}

/** „Prompt“ incl. typical ASR mishearings („Promt“, „Brompt“, „Prompf“ …) */
const P = String.raw`(?:prompts?|promts?|prompd|prompt[ea]|brompts?|bromts?|prompf|promp|pomt|prompt's)`;
/** „Agent“ incl. mishearings („Agenten“, „Eigent“, „Agend“, „Ägent“) */
const AGENT = String.raw`(?:agent(?:en|s)?|agend|eigent|ägent|aged)`;
/** who the prompt addresses */
const WHO = String.raw`(?:(?:den|die|das|meinen|meine|unseren|my|the)\s+)?(?:${AGENT}|claude(?:\s+code)?|cloud(?:\s+code)?|codex|ki|chat\s*gpt|cursor)`;
/** filler words before the trigger */
const LEAD = String.raw`^(?:(?:okay|ok|also|so|gut|ja|äh|ähm|hm|und|well|alright|right|hey|jetzt|genau|nun)[\s,.:!…-]+){0,3}`;
const SEP = String.raw`(?:\s*[:,.;!?…–—-]+\s*|\s+|$)`;

/** strong triggers at the start (always trigger) */
const STRONG_START: string[] = [
  // Ich mache jetzt (mal) einen (neuen) (Agent-)Prompt / ich diktier dir einen Prompt
  String.raw`ich\s+(?:mach(?:e)?|schreib(?:e)?|bau(?:e)?|diktier(?:e)?|sprech(?:e)?)\s+(?:dir\s+|euch\s+)?(?:jetzt\s+)?(?:mal\s+)?(?:schnell\s+)?(?:einen|ein|nen|'nen|n)\s+(?:neuen\s+|kurzen\s+|langen\s+)?(?:${AGENT}[\s-]*)?${P}(?:\s+(?:für|an)\s+${WHO})?`,
  // Jetzt kommt ein Prompt
  String.raw`(?:jetzt\s+)?(?:kommt|folgt)\s+(?:jetzt\s+)?(?:ein(?:en)?|der|mein)\s+(?:neuer\s+)?(?:${AGENT}[\s-]*)?${P}(?:\s+(?:für|an)\s+${WHO})?`,
  // Agent-Prompt / Agenten Prompt (für Claude)
  String.raw`${AGENT}[\s-]*${P}(?:\s+(?:für|an|for)\s+${WHO})?`,
  // Prompt für den Agenten / Prompt an Claude Code
  String.raw`${P}\s+(?:für|an|for|to)\s+${WHO}`,
  // Mach (mir) daraus einen Prompt / Mach mir einen Prompt
  String.raw`(?:mach|mache|bau|baue|schreib|schreibe)\s+(?:mir\s+|uns\s+)?(?:bitte\s+)?(?:daraus\s+|draus\s+|hieraus\s+|davon\s+)?(?:bitte\s+)?(?:einen|ein|nen)\s+(?:guten\s+|starken\s+)?(?:${AGENT}[\s-]*)?${P}(?:\s+(?:daraus|draus))?`,
  // Neuer Prompt / Prompt-Modus
  String.raw`(?:neuer|neuen|new)\s+(?:${AGENT}[\s-]*)?${P}`,
  String.raw`${P}[\s-]*(?:modus|mode)`,
  // I'm (going to) make a prompt / let me write a prompt / here's a prompt
  String.raw`(?:i'?m|i\s+am)\s+(?:going\s+to\s+|gonna\s+|about\s+to\s+)?(?:make|making|write|writing|do|doing|dictate|dictating|build|building)\s+(?:a|an|the)\s+(?:new\s+|quick\s+)?(?:agent\s+)?${P}(?:\s+(?:for|to)\s+${WHO})?`,
  String.raw`(?:let\s+me|let's|lets)\s+(?:make|write|do|dictate|build)\s+(?:a|an)\s+(?:new\s+|quick\s+)?(?:agent\s+)?${P}(?:\s+(?:for|to)\s+${WHO})?`,
  String.raw`(?:make|turn)\s+(?:this|that|it)\s+(?:into\s+)?(?:a|an)\s+(?:agent\s+)?${P}`,
  String.raw`here'?s\s+(?:a|an|the)\s+(?:new\s+)?(?:agent\s+)?${P}`,
];

/** triggers at the end („…, mach daraus einen Prompt.“) */
const STRONG_END: string[] = [
  String.raw`(?:und\s+)?(?:bitte\s+)?(?:mach|mache|bau|baue)\s+(?:mir\s+|uns\s+)?(?:bitte\s+)?(?:daraus|draus|davon|hieraus)\s+(?:bitte\s+)?(?:einen|ein|nen)\s+(?:guten\s+|starken\s+|sauberen\s+)?(?:${AGENT}[\s-]*)?${P}(?:\s+(?:für|an)\s+${WHO})?(?:\s+bitte)?`,
  String.raw`(?:and\s+)?(?:please\s+)?(?:make|turn)\s+(?:this|that|it)\s+into\s+(?:a|an)\s+(?:good\s+|strong\s+|clean\s+)?(?:agent\s+)?${P}(?:\s+(?:for|to)\s+${WHO})?(?:\s+please)?`,
  String.raw`(?:das\s+)?(?:bitte\s+)?als\s+(?:${AGENT}[\s-]*)?${P}(?:\s+(?:für|an)\s+${WHO})?(?:\s+bitte)?`,
];

/** after a bare „Prompt“ at the start these words mean „talking about prompts“, not „prompt mode“ */
const BARE_BLOCK = new Set(['ist', 'war', 'hat', 'wird', 'wurde', 'sind', 'waren', 'engineering', 'injection', 'injections',
  'design', 'library', 'bibliothek', 'vorlage', 'vorlagen', 'template', 'templates', 'is', 'was',
  'has', 'will', 'are', 'were', 'der', 'die', 'das', 'des', 'caching', 'cache', 'länge', 'fenster',
  'window', 'tuning', 'optimierung', 'technik', 'techniken', 'beispiele', 'examples', 'ly']);

const LEAD_RE = icu(LEAD, 'i');
const START_RES = STRONG_START.map((p) => icu('^(?:' + p + ')' + SEP, 'i'));
const END_RES = STRONG_END.map((p) => icu(String.raw`(?:^|[\s,.;:!?–—-]+)(?:` + p + String.raw`)\s*[.!…]*\s*$`, 'i'));
const BARE_RE = icu('^(' + P + String.raw`)\b\s*([:,.;!–—-]*)\s*`, 'i');

export function match(text: string): TriggerMatch | null {
  const t = text.trim();
  if (!t) return null;
  const leadLen = first(LEAD_RE, t)?.[0].length ?? 0;
  const rest = t.slice(leadLen);

  // 1) strong triggers at the start
  for (const re of START_RES) {
    const m = first(re, rest);
    if (m && m.index === 0) {
      const r = finish(rest.slice(m[0].length), trimWsPunct(m[0]), false);
      if (r) return r;
    }
  }
  // 2) strong triggers at the end
  for (const re of END_RES) {
    const m = first(re, t);
    if (m) {
      const r = finish(t.slice(0, m.index), trimWsPunct(m[0]), true);
      if (r) return r;
    }
  }
  // 3) bare „Prompt“ at the start: only with punctuation after it („Prompt: …“, „Promt, …“) or a real task behind it
  const m = first(BARE_RE, rest);
  if (m) {
    const punct = m[2] ?? '';
    const body = rest.slice(m[0].length);
    const next = (body.split(/[\s,.;:!?]+/u).find((x) => x.length > 0) ?? '').toLowerCase();
    const phrase = m[1] ?? '';
    if (punct && !Array.from(punct).every((c) => c === '-')) {
      const r = finish(body, phrase, false, 3);
      if (r) return r;
    } else if (!BARE_BLOCK.has(next) && words(body) >= 6) {
      const r = finish(body, phrase, false, 6);
      if (r) return r;
    }
  }
  return null;
}

function finish(body: string, phrase: string, atEnd: boolean, minWords = 3): TriggerMatch | null {
  let b = body.trim();
  b = b.replace(/^[\s,.;:!?…–—-]+/u, '');
  b = b.replace(/[\s,;:–—-]+$/u, '');
  if (words(b) < minWords) return null;
  const last = Array.from(b).pop();
  if (atEnd && last && !'.!?'.includes(last)) b += '.';
  return { body: capFirst(b), phrase, atEnd };
}

// MARK: - automatic detection: a long task for an agent?

export interface Detection {
  score: number;
  offer: boolean;
  reasons: string[];
  words: number;
  imperative: string[];
  technical: string[];
  agentApp: boolean;
  chatty: string[];
}

/** from this score on the card is offered (plus the hard conditions below) */
export const THRESHOLD = 6;

export const IMPERATIVE_RE = icu(String.raw`\b(bau|baue|bauen|baust|fix|fixe|fixen|fixt|implementier(?:e|en|st)?|prüf(?:e|en|st)?|pruef(?:e|en)?|check(?:e|en|st)?|teste|testen|recherchier(?:e|en)?|erstell(?:e|en)?|ergänz(?:e|en)?|änder(?:e|n)|entfern(?:e|en)?|lösch(?:e|en)?|refactor(?:e|n)?|refaktorier(?:e|en)?|analysier(?:e|en)?|debug(?:ge|gen)?|untersuch(?:e|en)?|migrier(?:e|en)?|installier(?:e|en)?|deploy(?:e|en)?|richte|stell\s+sicher|sorg(?:e)?\s+dafür|achte\s+darauf|schau\s+(?:dir\s+)?(?:mal\s+)?|guck\s+(?:dir\s+)?|lies|räum|ersetz(?:e|en)?|verschieb(?:e|en)?|benenn(?:e)?|füg(?:e)?|pass\s+(?:\w+\s+){0,3}an|build|implement|add|remove|delete|refactor|verify|investigate|research|rename|migrate|ensure|make\s+sure|look\s+into|figure\s+out|update|create|write|fix|summari[sz]e|propose|compare|evaluate|look\s+at|fass\s+(?:\w+\s+){0,4}zusammen|vergleich(?:e|en)?|schlag\s+(?:\w+\s+){0,3}vor|bewerte|dokumentier(?:e|en)?)\b`, 'i');
export const MODAL_RE = icu(String.raw`\b(bitte|soll(?:st|en|te)?|musst|müssen|muss|brauche|brauchen|ich\s+will|ich\s+möchte|wir\s+wollen|please|should|must|need\s+to|needs\s+to|i\s+want|i\s+need\s+you\s+to|kannst\s+du)\b`, 'i');
const TECH_RE = icu(String.raw`\b(agent(?:en)?|claude(?:\s+code)?|codex|datei(?:en)?|funktion(?:en)?|repo(?:sitory)?|tests?|commit(?:s)?|branch(?:es)?|pull\s+request|api|endpoint|bug(?:s)?|fehlermeldung|build|deploy(?:ment)?|komponente(?:n)?|component(?:s)?|server|datenbank|database|code|swift|swiftui|typescript|javascript|python|react|next\.?js|npm|pnpm|git|github|skript|script|logs?|cli|terminal|backend|frontend|modul|module|klasse|class|methode|method|variable|parameter|json|sql|schema|migration|release|diff|pipeline|worker|config|konfiguration|feature|endpoint|query|queries|cache|hook|useeffect|state|refactoring|stack\s*trace|exception|crash|dependenc(?:y|ies)|library|package|framework|xcode|vs\s*code|cursor|linter|compiler|typ(?:en)?fehler|pr|ios|ipados|macos|core\s+data|design\s*doc|crdts?|open\s+source|offline\s+sync|ui\s*tests?|unit\s*tests?)\b`, 'i');
const EXT_A = 'swift|ts|tsx|js|jsx|py|md|json|sh|yml|yaml|css|html|go|rs|kt|java|rb|sql|toml|plist';
const EXT_B = 'swift|ts|tsx|js|py|json|md|sh|yaml|css|html';
/** files, paths, spoken extensions, camelCase/snake_case, --flags (camelCase deliberately case-SENSITIVE – otherwise every word matches) */
const FILE_RE = icu(String.raw`(\b[\w-]+\.(?:${ci(EXT_A)})\b|\b(?:${ci('punkt|dot')})\s+(?:${ci(EXT_B)})\b|(?:^|\s)/[\w.-]+/[\w./-]+|\b${ci('slash')}\s+\w+|\b[a-z]+[A-Z][A-Za-z]+\b|\b[A-Za-z]+_[A-Za-z_]+\b|(?:^|\s)--[a-z][\w-]+)`);
const CHATTY_RE = icu(String.raw`(^\s*(hallo|hi|hey|servus|moin|hallöchen|guten\s+morgen|guten\s+abend|liebe[rs]?|dear|hello|yo)\b|\b(liebe\s+grüße|viele\s+grüße|lg|bis\s+später|bis\s+dann|bis\s+morgen|hab\s+dich\s+lieb|kuss|küsschen|cheers|best\s+regards|kind\s+regards|love\s+you|miss\s+you|danke\s+dir|dankeschön|haha|hahaha|lol|mama|papa|schatz|omi|opa|geburtstag|urlaub|wochenende|abendessen)\b)`, 'i');
const NARRATIVE_RE = icu(String.raw`\b(ich\s+war|wir\s+waren|gestern|heute\s+morgen|letzte\s+woche|ich\s+hab\s+gestern|i\s+was|we\s+were|yesterday|last\s+week)\b`, 'i');

/** browser windows with Claude/ChatGPT in the title count like an agent app */
export function isAgentTarget(exe: string, title: string): boolean {
  if (appCategory(exe) === 'ai') return true;
  const t = title.toLowerCase();
  return ['claude', 'chatgpt', 'codex', 'cursor', 'gemini', 'copilot'].some((x) => t.includes(x));
}

function uniq(xs: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const x of xs) {
    const k = x.toLowerCase().trim();
    if (!seen.has(k)) { seen.add(k); out.push(k); }
  }
  return out;
}

export interface DetectInput { text: string; duration: number; exe: string; title?: string }

export function detect({ text, duration, exe, title = '' }: DetectInput): Detection {
  const n = words(text);
  const lower = text.toLowerCase();
  const impList = uniq(all(IMPERATIVE_RE, text));
  const modList = uniq(all(MODAL_RE, text));
  const imp = [...impList, ...modList.map((m) => `(${m})`)];
  const impHits = impList.length;
  const modalHits = Math.min(2, modList.length);
  const tech = uniq([...all(TECH_RE, text), ...all(FILE_RE, text).map((x) => x.trim())]);
  const chatty = uniq(all(CHATTY_RE, lower));
  const narrative = Math.min(2, count(NARRATIVE_RE, lower));
  const agentApp = isAgentTarget(exe, title);
  const category = appCategory(exe);
  const personalApp = category === 'personal' || category === 'email';

  let lenPts = n >= 120 ? 3 : n >= 60 ? 2 : n >= 40 ? 1 : 0;
  if (n >= 25) lenPts += duration >= 45 ? 2 : duration >= 25 ? 1 : 0;
  lenPts = Math.min(4, lenPts);
  let score = lenPts + Math.min(4, impHits) + modalHits + Math.min(4, tech.length) + (agentApp ? 3 : 0);
  score -= 2 * Math.min(2, chatty.length) + narrative + (personalApp ? 3 : 0);

  const long = n >= 60 || (duration >= 25 && n >= 35);
  const signals = impHits + modalHits + tech.length;
  let offer = long && score >= THRESHOLD;
  if (offer && !agentApp) {
    // without an agent app: a real task is needed (verb + tech or many verbs)
    offer = (impHits >= 1 && tech.length >= 2) || (impHits >= 2 && tech.length >= 1) || (impHits + modalHits >= 3 && tech.length >= 1);
  } else if (offer && agentApp) {
    offer = signals >= 1;
  }
  if (chatty.length >= 2 || (personalApp && chatty.length > 0)) offer = false;

  const reasons: string[] = [`${n} Wörter`];
  if (duration >= 1) reasons.push(`${Math.round(duration)} s`);
  if (imp.length) reasons.push('Auftrag: ' + imp.slice(0, 4).join(', '));
  if (tech.length) reasons.push('Technik: ' + tech.slice(0, 4).join(', '));
  if (agentApp) reasons.push('Ziel-App: Agent/Terminal');
  if (personalApp) reasons.push('Ziel-App: Nachricht/E-Mail');
  if (chatty.length) reasons.push('Plaudern: ' + chatty.slice(0, 3).join(', '));
  if (narrative > 0) reasons.push('Erzählung');
  if (!long) reasons.push('zu kurz');
  return { score, offer, reasons, words: n, imperative: imp, technical: tech, agentApp, chatty };
}

// MARK: - short line + structure of a finished prompt

export interface Gist { goal: string; tasks: number; criteria: number; rules: number; open: number }

const GOAL_LINE_RE = icu(String.raw`^\*{0,2}(?:Ziel|Goal)\s*:\s*\*{0,2}\s*(.+)$`);
const ITEM_RE = /^(\d+[.)]|[-*•])\s+/u;

export function gistOf(prompt: string): Gist {
  const g: Gist = { goal: '', tasks: 0, criteria: 0, rules: 0, open: 0 };
  let section = '';
  for (const raw of prompt.split('\n')) {
    const l = raw.trim();
    if (!g.goal) {
      const m = first(GOAL_LINE_RE, l);
      if (m) { g.goal = (m[1] ?? '').split('**').join('').split('`').join('').trim(); continue; }
    }
    if (l.startsWith('#')) {
      const h = trimSet(l, '# ').toLowerCase();
      const has = (...xs: string[]) => xs.some((x) => h.startsWith(x));
      if (has('aufgabe', 'anforderung', 'task', 'requirement', 'schritte', 'steps')) section = 'task';
      else if (has('akzeptanz', 'acceptance', 'wie prüf', 'how to verify')) section = 'crit';
      else if (has('regel', 'rules', 'nicht tun', 'constraints')) section = 'rules';
      else if (has('offen', 'open')) section = 'open';
      else section = '';
      continue;
    }
    if (!ITEM_RE.test(l)) continue;
    if (section === 'task') g.tasks++;
    else if (section === 'crit') g.criteria++;
    else if (section === 'rules') g.rules++;
    else if (section === 'open') g.open++;
  }
  if (!g.goal) {
    // no „Ziel:“ – first line with content
    g.goal = prompt.split('\n').map((x) => trimSet(x, '#*- ')).find((x) => x.length > 0) ?? '';
  }
  const chars = Array.from(g.goal);
  if (chars.length > 110) g.goal = chars.slice(0, 108).join('').trim() + '…';
  return g;
}

// MARK: - concrete details (numbers, files) – for the „nothing lost“ check

const NUMBER_RE = icu(String.raw`\b\d+(?:[.,]\d+)*\b`);
const DETAIL_FILE_RE = icu(String.raw`\b[\w-]+\.(?:swift|ts|tsx|js|jsx|py|md|json|sh|yml|yaml|css|html|go|rs|kt|java|rb|sql|toml|plist)\b`);

/** numbers and file names that stand in `s` */
export function hardDetails(s: string): string[] {
  const out = [...all(NUMBER_RE, s), ...all(DETAIL_FILE_RE, s)].filter((x) => x.length > 0);
  return [...new Set(out)].sort();
}

/** details of `source` missing in `result` */
export function missingDetails(source: string, result: string): string[] {
  const r = result.toLowerCase();
  return hardDetails(source).filter((d) => !r.includes(d.toLowerCase()));
}

// MARK: - fallback without Claude: rule structurer

export interface APContext {
  appName: string;
  /** process name, e.g. "Code.exe" */
  exe: string;
  windowTitle: string;
  /** selected text (Windows: not read – the clipboard is never used for it) */
  selection: string;
}

export const emptyContext = (): APContext => ({ appName: '', exe: '', windowTitle: '', selection: '' });

/** the window title only goes along for developer/agent apps and browsers with an agent in the title (privacy: no mail subjects) */
export const includesTitle = (c: APContext): boolean => !!c.windowTitle && isAgentTarget(c.exe, c.windowTitle);
export const contextIsEmpty = (c: APContext): boolean => !c.appName && !includesTitle(c) && !c.selection;

/** block for Claude (<kontext>) */
export function contextBlock(c: APContext): string {
  const lines: string[] = [];
  if (c.appName) lines.push(`App: ${c.appName}`);
  if (includesTitle(c)) lines.push(`Fenstertitel: ${c.windowTitle}`);
  if (c.selection) {
    lines.push('Markierter Text (nur verwenden, wenn er zum Auftrag gehört):');
    lines.push(Array.from(c.selection).slice(0, 4000).join(''));
  }
  return lines.join('\n');
}

/** sentence starts without content („Okay also“, „Ach ja und“) */
const DISCOURSE = icu(String.raw`^(?:(?:okay|ok|also|ja|und|so|genau|naja|ach\s+ja|äh|ähm|hm|well|so\s+yeah|alright|right|und\s+dann|dann|außerdem|übrigens|also\s+quasi|quasi|sozusagen|irgendwie|halt|eben)[\s,.:!…-]+)+`, 'i');
/** preamble without a task („ich mache jetzt mal“, „pass auf“, „hör zu“) */
const PREAMBLE = icu(String.raw`^(?:ich\s+mach(?:e)?\s+(?:jetzt\s+)?mal|pass\s+auf|hör\s+zu|also\s+pass\s+auf|so\s+pass\s+auf|okay\s+listen|listen|here\s+we\s+go|los\s+geht'?s)\b[\s,.:!…-]*`, 'i');
const FILLER_WORDS = icu(String.raw`\s*\b(?:quasi|sozusagen|irgendwie|halt|eigentlich\s+so|so\s+ein\s+bisschen|like|you\s+know|kind\s+of|sort\s+of)\b(?=[\s,.])`, 'i');

const OPEN_RE = icu(String.raw`(\?\s*$|\bich\s+weiß\s+(?:noch\s+)?nicht\s*(?:genau|so\s+recht)?[\s,]+(?:ob|wie|wann|welche|was|wo)\b|\bweiß\s+nicht\s*(?:genau)?[\s,]+ob\b|\bbin\s+mir\s+(?:noch\s+)?nicht\s+sicher\b|\bkeine\s+ahnung\b|\bunklar\b|\bnot\s+sure\b|\bi\s+don'?t\s+know\s+(?:if|whether|how|which)\b|\bunsure\b|\bmaybe\s+we\b|\bvielleicht\s+sollten\b|\bmüssen\s+wir\s+noch\s+(?:klären|entscheiden)\b)`, 'i');
const RULE_RE = icu(String.raw`\b(nicht|kein|keine|keinen|keinesfalls|nie|niemals|ohne|auf\s+keinen\s+fall|don'?t|do\s+not|never|without|avoid|vermeide|nichts)\b`, 'i');
const ACCEPT_RE = icu(String.raw`((?:tests?|build|linter|ci)\b.{0,60}\b(grün|green|laufen|durchlaufen|bestehen|pass(?:en|t)?|fehlerfrei)|\b(?:am\s+ende|danach|zum\s+schluss)\b.{0,40}\b(soll|muss|müssen|sollen)\b|\bfertig\s+ist\s+es,?\s+wenn\b|\bakzeptanz|\bdone\s+when\b|\bmust\s+pass\b|\bshould\s+pass\b|\bis\s+done\s+if\b)`, 'i');
const CONTEXT_RE = icu(String.raw`^(es\s+geht\s+um|das\s+ist|das\s+sind|gerade|aktuell|momentan|im\s+moment|ich\s+glaube|ich\s+denke|das\s+liegt|das\s+problem|der\s+fehler|wir\s+haben|es\s+gibt|die\s+[\wäöüß-]+\s+(?:ist|sind|hat|haben)|der\s+[\wäöüß-]+\s+(?:ist|hat)|das\s+[\wäöüß-]+\s+(?:ist|hat)|it'?s|this\s+is|currently|right\s+now|the\s+problem|there\s+is|there\s+are|we\s+have|i\s+think)\b`, 'i');
const NEG_START = icu(String.raw`^(nicht|kein|keine|keinen|nie|niemals|bitte\s+nicht|bitte\s+kein\w*|don'?t|do\s+not|never|avoid|vermeide)\b`, 'i');
const NEW_THOUGHT = icu(String.raw`,?\s+(ach\s+ja|außerdem|übrigens|und\s+noch\s+was|by\s+the\s+way|oh\s+and|also,)\s+`, 'gi');

export interface Sections { goal: string; context: string[]; tasks: string[]; criteria: string[]; rules: string[]; open: string[] }

/** tidy a dictation (self-corrections, repeats, false starts, fillers) – without losing content */
export function clean(s: string): string {
  let t = resolveCorrections(s);
  t = QuickPolish.collapseRepeats(t)[0];
  t = QuickPolish.dropFalseStarts(t)[0];
  t = replaceAll(FILLER_WORDS, t, '');
  return tidy(t);
}

/** words that may disappear when a self-correction is resolved (the correction marker itself) */
const MARKER_WORDS = new Set(['nein', 'warte', 'sorry', 'doch', 'lieber', 'ich', 'meine', 'meinte', 'eher', 'besser', 'also',
  'streich', 'das', 'no', 'wait', 'mean', 'meant', 'actually', 'rather', 'scratch', 'that', 'oder']);

/** Resolve a self-correction with QuickPolish – but only when at most one content word (the corrected value) disappears.
 *  Otherwise everything stays and the correction is appended visibly („– korrigiert: …“) so no detail is lost. */
export function resolveCorrections(s: string): string {
  const [r, n] = QuickPolish.resolveCorrections(s);
  if (n <= 0) return s;
  const bag = (x: string) => {
    const d = new Map<string, number>();
    for (const w of x.split(/\s+/u).filter(Boolean)) {
      const b = QuickPolish.bare(w).toLowerCase();
      if (!b || MARKER_WORDS.has(b) || !(Array.from(b).length >= 3 || /\p{N}/u.test(b))) continue;
      d.set(b, (d.get(b) ?? 0) + 1);
    }
    return d;
  };
  const before = bag(s), after = bag(r);
  let lost = 0;
  for (const [k, v] of before) lost += Math.max(0, v - (after.get(k) ?? 0));
  if (lost <= 1) return r;
  const t = QuickPolish.tokens(s);
  const mk = QuickPolish.findMarker(t);
  if (!mk) return s;
  const a = trimSet(QuickPolish.join(t.slice(0, mk.lo)), ',;:–— ');
  let b = QuickPolish.join(t.slice(mk.hi)).trim();
  b = b.replace(/^(lieber|doch|eher|besser|rather|actually|instead)\s+/iu, '');
  return a + (isEnglish(s) ? ' – correction: ' : ' – korrigiert: ') + b;
}

export function sentences(s: string): string[] {
  // sentence ends + „Ach ja“/„Und bitte“/„Außerdem“ as new thoughts
  let t = s.replace(/\s*\n+\s*/gu, '. ');
  t = t.replace(NEW_THOUGHT, '. $1 ');
  const out: string[] = [];
  let cur = '';
  const chars = Array.from(t);
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i]!;
    cur += ch;
    if ('.!?'.includes(ch)) {
      const next = chars[i + 1] ?? ' ';
      // no split inside 1.7.16, 3.5, z.B., index.ts
      if (ch === '.' && !/\s/u.test(next)) continue;
      out.push(cur); cur = '';
    }
  }
  if (cur.trim()) out.push(cur);
  return out.map((x0) => {
    let x = x0.trim();
    for (let k = 0; k < 2; k++) {
      x = x.replace(DISCOURSE, '');
      x = x.replace(PREAMBLE, '');
    }
    return capFirst(x.trim());
  }).filter((x) => words(x) >= 2 || /\p{Nd}/u.test(x));
}

export function classify(xs: string[]): Sections {
  const s: Sections = { goal: '', context: [], tasks: [], criteria: [], rules: [], open: [] };
  for (const x of xs) {
    const isOpen = !!first(OPEN_RE, x);
    const imperative = !!first(IMPERATIVE_RE, x) || !!first(MODAL_RE, x);
    if (isOpen) { s.open.push(x.endsWith('?') ? x : x.replace(/[.!]+$/u, '') + '?'); continue; }
    if (first(ACCEPT_RE, x)) { s.criteria.push(x); continue; }
    const negStart = !!first(NEG_START, x);
    if (first(RULE_RE, x) && (imperative || negStart || x.toLowerCase().includes('fass'))) { s.rules.push(x); continue; }
    if (!imperative && (!!first(CONTEXT_RE, x) || (s.tasks.length === 0 && s.context.length < 3 && !x.endsWith('!')))) {
      s.context.push(x); continue;
    }
    s.tasks.push(x);
  }
  // everything was „context“? Then the sentences are the task
  if (s.tasks.length === 0 && s.context.length > 0) { s.tasks = s.context; s.context = []; }
  s.goal = goal(s.tasks[0] ?? s.criteria[0] ?? s.open[0] ?? '');
  return s;
}

/** goal sentence: the first task, shortened to one line (at the first comma after 6 words) */
export function goal(s: string): string {
  let g = s.replace(/^(bitte|please)\s+/iu, '');
  const w = g.split(' ').filter((x) => x.length > 0);
  if (w.length > 16) {
    const acc: string[] = [];
    for (const x of w) { acc.push(x); if (acc.length >= 6 && (x.endsWith(',') || acc.length >= 16)) break; }
    g = trimSet(acc.join(' '), ', ') + ' …';
  }
  return capFirst(g);
}

export function structure(transcript: string, context?: APContext | null): string {
  const en = isEnglish(transcript);
  const sec = classify(sentences(clean(transcript)));
  const H = en
    ? { goal: 'Goal', ctx: 'Context', task: 'Task', crit: 'Acceptance criteria', rules: 'Rules', open: 'Open questions' }
    : { goal: 'Ziel', ctx: 'Kontext', task: 'Aufgabe', crit: 'Akzeptanzkriterien', rules: 'Regeln', open: 'Offene Punkte' };
  let out = `**${H.goal}:** ${sec.goal || (en ? 'See task' : 'Siehe Aufgabe')}\n`;
  const ctx = sec.context.map((x) => `- ${x}`);
  if (context) {
    if (includesTitle(context)) ctx.push(en ? `- Window: ${context.windowTitle} (${context.appName})` : `- Fenster: ${context.windowTitle} (${context.appName})`);
    if (context.selection && Array.from(context.selection).length <= 600) ctx.push((en ? '- Selected text: ' : '- Markierter Text: ') + `„${context.selection.split('\n').join(' ')}“`);
  }
  if (ctx.length) out += `\n## ${H.ctx}\n` + ctx.join('\n') + '\n';
  const tasks = sec.tasks.length ? sec.tasks : [transcript.trim()];
  out += `\n## ${H.task}\n` + tasks.map((x, i) => `${i + 1}. ${x}`).join('\n') + '\n';
  const crit = sec.criteria.length ? sec.criteria : [en ? `All items under “${H.task}” are done.` : `Alle Punkte unter „${H.task}“ sind umgesetzt.`];
  out += `\n## ${H.crit}\n` + crit.map((x) => `- ${x}`).join('\n') + '\n';
  if (sec.rules.length) out += `\n## ${H.rules}\n` + sec.rules.map((x) => `- ${x}`).join('\n') + '\n';
  if (sec.open.length) out += `\n## ${H.open}\n` + sec.open.map((x) => `- ${x}`).join('\n') + '\n';
  return out.trim();
}
