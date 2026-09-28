// Agent-Prompt strings (German first, English second) – separate from shared/i18n.ts so the modules merge cleanly.
// The German card texts are the Mac's (APCard.swift / APViews.swift).
export type APLoc = 'de' | 'en';

const de = {
  // card
  chipOffer: 'Vorschlag',
  chipPrompt: 'Agent-Prompt',
  chipRules: 'Prompt · ohne KI',
  chipCancelled: 'Abgebrochen',
  chipFailed: 'Nicht gebaut',
  titleOffer: 'Daraus einen Agent-Prompt machen?',
  titleBuilding: 'Prompt wird gebaut …',
  titleDone: 'Dein Agent-Prompt ist fertig',
  titleCancelled: 'Prompt abgebrochen',
  titleFailed: 'Prompt hat nicht geklappt',
  offerWords: '{n} Wörter',
  offerAgent: 'klingt nach einem Auftrag für deinen Agenten',
  offerTech: 'klingt nach einem Auftrag ({tech})',
  offerTask: 'klingt nach einem Auftrag',
  buildingRules: 'Flow ordnet deine {n} Wörter nach Regeln …',
  buildingWait: 'Claude ordnet deine {n} Wörter …',
  buildingLive: 'Claude schreibt – {a} von ~{b} Wörtern',
  doneOriginalSub: 'Dein Original-Diktat · {n} Wörter',
  stoppedSub: 'Dein Original ist sicher – im Verlauf und in der Zwischenablage.',
  tasks1: '1 Anforderung',
  tasksN: '{n} Anforderungen',
  crit1: '1 Prüfpunkt',
  critN: '{n} Prüfpunkte',
  rules1: '1 Regel',
  rulesN: '{n} Regeln',
  open1: '1 offene Frage',
  openN: '{n} offene Fragen',
  btnBuild: 'Prompt bauen',
  btnNo: 'Nein',
  btnCancel: 'Abbrechen',
  originalReady: 'Original liegt schon in der Zwischenablage',
  btnCopy: 'Kopieren',
  btnCopied: 'Kopiert',
  btnInsert: 'Einfügen',
  btnInserted: 'Eingefügt',
  btnOpen: 'Ansehen',
  btnCopyOriginal: 'Original kopieren',
  btnInsertOriginal: 'Original einfügen',
  btnRetry: 'Nochmal',
  segPrompt: 'Prompt',
  segOriginal: 'Original',
  rulesNoCli: 'Regeln · ohne Claude-CLI',
  rulesWhy: 'Regeln · {why}',
  close: 'Schließen',
  promptInClipboard: 'Prompt liegt in der Zwischenablage',
  originalInClipboard: 'Original liegt in der Zwischenablage',
  // hub
  nav: 'Agent-Prompts',
  title: 'Deine <em>Agent-Prompts</em>',
  lead: 'Sag „Prompt: …“ und erzähl einfach – Flow macht daraus einen klaren Auftrag für deinen Coding-Agenten. Hier liegen die letzten 50, jeweils mit deinem Original.',
  emptyBig: 'Noch kein Agent-Prompt',
  emptyText: 'Sag „Prompt: …“ und erzähl einfach los – Flow macht daraus einen sauberen Auftrag für deinen Agenten.',
  copyPrompt: 'Prompt kopieren',
  copyOriginal: 'Original kopieren',
  deletePrompt: 'Prompt löschen (Original bleibt in ClipVault)',
  byRules: 'nach Regeln',
  rulesTag: 'Regeln',
  count: '{n} von 50',
  // settings
  secAgent: 'Agent-Prompts',
  mode: 'Agent-Prompts',
  mode_on: 'An',
  mode_explicitOnly: 'Nur auf Zuruf',
  mode_off: 'Aus',
  modeDesc_on: '„Prompt: …“ baut sofort einen Prompt. Lange Aufträge an einen Agenten erkennt Flow selbst und bietet es an (nur mit Claude-CLI).',
  modeDesc_explicitOnly: 'Nur wenn du „Prompt: …“ oder „Ich mache jetzt einen Prompt …“ sagst.',
  modeDesc_off: 'Nie – „Prompt …“ wird normal eingefügt.',
  howTo: 'So geht’s',
  howStart: 'Sag am Anfang „Prompt: …“, „Agent-Prompt …“ oder „Ich mache jetzt einen Prompt …“ und erzähl einfach. ',
  howClaude: 'Claude (Sonnet, Aufwand low) macht daraus einen sauberen Auftrag – dafür geht das Diktat (und bei Entwickler-Apps der Fenstertitel) über dein eigenes Claude-Konto an Anthropic. ',
  howRules: 'Ohne Claude-CLI baut Flow den Prompt lokal nach Regeln (Ziel, Aufgabe, Regeln, offene Punkte – nichts geht verloren, umformuliert wird nichts). Vorschläge bei langen Aufträgen gibt es erst mit der Claude-CLI. ',
  howEnd: 'Er landet in der Zwischenablage und unter Agent-Prompts. Dein Original bleibt immer als „Diktat (Original)“ in ClipVault.',
  cliFound: 'Claude-CLI gefunden',
  cliMissing: 'ohne Claude-CLI',
};

type Key = keyof typeof de;

const en: Record<Key, string> = {
  chipOffer: 'Suggestion',
  chipPrompt: 'Agent prompt',
  chipRules: 'Prompt · no AI',
  chipCancelled: 'Cancelled',
  chipFailed: 'Not built',
  titleOffer: 'Turn this into an agent prompt?',
  titleBuilding: 'Building your prompt …',
  titleDone: 'Your agent prompt is ready',
  titleCancelled: 'Prompt cancelled',
  titleFailed: 'The prompt did not work',
  offerWords: '{n} words',
  offerAgent: 'sounds like a task for your agent',
  offerTech: 'sounds like a task ({tech})',
  offerTask: 'sounds like a task',
  buildingRules: 'Flow is sorting your {n} words by rules …',
  buildingWait: 'Claude is sorting your {n} words …',
  buildingLive: 'Claude is writing – {a} of ~{b} words',
  doneOriginalSub: 'Your original dictation · {n} words',
  stoppedSub: 'Your original is safe – in the history and on the clipboard.',
  tasks1: '1 requirement',
  tasksN: '{n} requirements',
  crit1: '1 check',
  critN: '{n} checks',
  rules1: '1 rule',
  rulesN: '{n} rules',
  open1: '1 open question',
  openN: '{n} open questions',
  btnBuild: 'Build prompt',
  btnNo: 'No',
  btnCancel: 'Cancel',
  originalReady: 'Your original is already on the clipboard',
  btnCopy: 'Copy',
  btnCopied: 'Copied',
  btnInsert: 'Paste',
  btnInserted: 'Pasted',
  btnOpen: 'View',
  btnCopyOriginal: 'Copy original',
  btnInsertOriginal: 'Paste original',
  btnRetry: 'Try again',
  segPrompt: 'Prompt',
  segOriginal: 'Original',
  rulesNoCli: 'Rules · without Claude CLI',
  rulesWhy: 'Rules · {why}',
  close: 'Close',
  promptInClipboard: 'Prompt is on the clipboard',
  originalInClipboard: 'Original is on the clipboard',
  nav: 'Agent prompts',
  title: 'Your <em>agent prompts</em>',
  lead: 'Say “Prompt: …” and just talk – Flow turns it into a clear task for your coding agent. The last 50 live here, each with your original.',
  emptyBig: 'No agent prompt yet',
  emptyText: 'Say “Prompt: …” and just start talking – Flow turns it into a clean task for your agent.',
  copyPrompt: 'Copy prompt',
  copyOriginal: 'Copy original',
  deletePrompt: 'Delete prompt (the original stays in ClipVault)',
  byRules: 'by rules',
  rulesTag: 'Rules',
  count: '{n} of 50',
  secAgent: 'Agent prompts',
  mode: 'Agent prompts',
  mode_on: 'On',
  mode_explicitOnly: 'Only on request',
  mode_off: 'Off',
  modeDesc_on: '“Prompt: …” builds a prompt right away. Flow also spots long tasks for an agent and offers it (only with the Claude CLI).',
  modeDesc_explicitOnly: 'Only when you say “Prompt: …” or “I’m going to make a prompt …”.',
  modeDesc_off: 'Never – “Prompt …” is pasted like any dictation.',
  howTo: 'How it works',
  howStart: 'Start with “Prompt: …”, “Agent prompt …” or “I’m going to make a prompt …” and just talk. ',
  howClaude: 'Claude (Sonnet, effort low) turns it into a clean task – for that the dictation (and, in developer apps, the window title) goes to Anthropic through your own Claude account. ',
  howRules: 'Without the Claude CLI Flow builds the prompt locally by rules (goal, task, rules, open points – nothing is lost, nothing is reworded). Suggestions for long tasks need the Claude CLI. ',
  howEnd: 'It lands on the clipboard and under Agent prompts. Your original always stays in ClipVault as “Diktat (Original)”.',
  cliFound: 'Claude CLI found',
  cliMissing: 'without Claude CLI',
};

const dicts: Record<APLoc, Record<Key, string>> = { de, en };
export type APKey = Key;
export const apKeys = Object.keys(de) as Key[];

export function apt(loc: APLoc, key: Key, vars?: Record<string, string | number>): string {
  let s: string = dicts[loc]?.[key] ?? de[key] ?? String(key);
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.split(`{${k}}`).join(String(v));
  return s;
}

/** the builder's German reasons („Zeitlimit (45 s)“, „Claude nicht erreichbar“ …) in the UI language */
export function reasonText(loc: APLoc, why: string): string {
  if (loc === 'de') return why;
  const t = /^Zeitlimit \((\d+) s\)$/u.exec(why);
  if (t) return `time limit (${t[1]} s)`;
  const map: Record<string, string> = {
    'Claude nicht erreichbar': 'Claude not reachable', 'Claude-CLI fehlt': 'no Claude CLI', 'Claude-Antwort zu kurz': 'Claude’s answer too short',
    'Claude-Antwort viel zu lang': 'Claude’s answer far too long', 'Claude lieferte nichts': 'Claude returned nothing', 'Nichts gehört': 'nothing heard',
    Abgebrochen: 'cancelled', Fehler: 'error',
  };
  return map[why] ?? why;
}

export const _apDicts = dicts;
