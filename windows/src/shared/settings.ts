// Settings schema, defaults and migration (pure – shared by main and renderer, unit-tested).
import type { DictEntry } from '../core/textCleaner';

export const SETTINGS_VERSION = 2;

export type HotkeyChoice = 'RightCtrl' | 'CtrlWin' | 'RightAlt' | 'F6' | 'F7' | 'F8' | 'F9' | 'F10' | 'F11' | 'F12';
export const HOTKEYS: HotkeyChoice[] = ['RightCtrl', 'CtrlWin', 'RightAlt', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];
export type DictationLanguage = 'auto' | 'de' | 'en';
export type EngineChoice = 'parakeet-v3' | 'whisper-turbo';
export type UiLocale = 'de' | 'en';

export interface Settings {
  version: number;
  locale: UiLocale;
  hotkey: HotkeyChoice;
  doubleTapHandsFree: boolean;
  language: DictationLanguage;
  engine: EngineChoice;
  micDeviceId: string;
  removeFillers: boolean;
  voiceCommands: boolean;
  polish: boolean;
  keepInClipboard: boolean;
  startWithWindows: boolean;
  autoUpdate: boolean;
  historyEnabled: boolean;
  historyRetentionDays: number;
  pillAlwaysVisible: boolean;
  /** „Text dorthin, wo die Maus ist“: on key release the text goes into the window under the mouse */
  mouseTarget: boolean;
  /** … and Enter afterwards – only in terminals/chats (core/mouseTarget.ts › autoSend) */
  mouseTargetAutoSend: boolean;
  /** blue frame „Text kommt hierher“ around the target window while speaking */
  mouseTargetHighlight: boolean;
  /** word learner: watch the field after pasting, ask „Wort gelernt?“ */
  learnFromEdits: boolean;
  dictionary: DictEntry[];
  onboardingDone: boolean;
}

export const DEFAULTS: Settings = {
  version: SETTINGS_VERSION,
  locale: 'de',
  hotkey: 'RightCtrl',
  doubleTapHandsFree: true,
  language: 'auto',
  engine: 'parakeet-v3',
  micDeviceId: '',
  removeFillers: true,
  voiceCommands: true,
  polish: true,
  keepInClipboard: false,
  startWithWindows: true,
  autoUpdate: true,
  historyEnabled: true,
  historyRetentionDays: 90,
  pillAlwaysVisible: true,
  mouseTarget: false,
  mouseTargetAutoSend: false,
  mouseTargetHighlight: true,
  learnFromEdits: true,
  dictionary: [],
  onboardingDone: false,
};

const bool = (v: unknown, d: boolean) => (typeof v === 'boolean' ? v : d);
const oneOf = <T extends string>(v: unknown, list: readonly T[], d: T): T => (typeof v === 'string' && (list as readonly string[]).includes(v) ? (v as T) : d);

/** legacy names (v1 = first preview builds + the Mac app's settings.json field names) */
const LEGACY_HOTKEY: Record<string, HotkeyChoice> = {
  rctrl: 'RightCtrl', rightctrl: 'RightCtrl', right_ctrl: 'RightCtrl', 'ctrl+win': 'CtrlWin', ctrlwin: 'CtrlWin', 'win+ctrl': 'CtrlWin',
  ralt: 'RightAlt', altgr: 'RightAlt', fn: 'RightCtrl',
};

export function sanitizeDictionary(v: unknown): DictEntry[] {
  const out: DictEntry[] = [];
  const seen = new Set<string>();
  const push = (heard: unknown, write: unknown, vocabOnly?: unknown) => {
    if (typeof heard !== 'string' || typeof write !== 'string') return;
    const h = heard.trim().slice(0, 200), w = write.slice(0, 500);
    if (!h || seen.has(h.toLowerCase())) return;
    seen.add(h.toLowerCase());
    out.push(vocabOnly === true ? { heard: h, write: w, vocabOnly: true } : { heard: h, write: w });
  };
  if (Array.isArray(v)) {
    for (const e of v) if (e && typeof e === 'object') { const o = e as Record<string, unknown>; push(o.heard ?? o.from, o.write ?? o.to, o.vocabOnly); }
  } else if (v && typeof v === 'object') {
    // v1: { "clip vault": "ClipVault" }
    for (const [k, w] of Object.entries(v as Record<string, unknown>)) push(k, w);
  }
  return out.slice(0, 2000);
}

/** Bring any stored JSON (older version, partial, garbage) into a valid current Settings object. */
export function migrateSettings(raw: unknown): Settings {
  const r: Record<string, unknown> = raw && typeof raw === 'object' && !Array.isArray(raw) ? { ...(raw as Record<string, unknown>) } : {};
  const version = typeof r.version === 'number' ? r.version : 1;
  if (version < 2) {
    // v1 → v2 renames
    if (r.lang !== undefined && r.language === undefined) r.language = r.lang;
    if (r.languageMode !== undefined && r.language === undefined) r.language = r.languageMode;
    if (r.uiLanguage !== undefined && r.locale === undefined) r.locale = r.uiLanguage;
    if (r.fillers !== undefined && r.removeFillers === undefined) r.removeFillers = r.fillers;
    if (r.commands !== undefined && r.voiceCommands === undefined) r.voiceCommands = r.commands;
    if (r.autostart !== undefined && r.startWithWindows === undefined) r.startWithWindows = r.autostart;
    if (r.micUID !== undefined && r.micDeviceId === undefined) r.micDeviceId = r.micUID;
    if (typeof r.aiPolish === 'string' && r.polish === undefined) r.polish = r.aiPolish !== 'off' && r.aiPolish !== 'aus';
    if (typeof r.hotkey === 'string') r.hotkey = LEGACY_HOTKEY[r.hotkey.toLowerCase()] ?? r.hotkey;
    if (r.engine === 'parakeet' || r.engine === 'parakeetUltra') r.engine = 'parakeet-v3';
    if (r.engine === 'whisper' || r.engine === 'whisperTurbo') r.engine = 'whisper-turbo';
    if (r.language === 'german') r.language = 'de';
    if (r.language === 'english') r.language = 'en';
  }
  const days = typeof r.historyRetentionDays === 'number' && Number.isFinite(r.historyRetentionDays) ? Math.round(r.historyRetentionDays) : DEFAULTS.historyRetentionDays;
  return {
    version: SETTINGS_VERSION,
    locale: oneOf(r.locale, ['de', 'en'] as const, DEFAULTS.locale),
    hotkey: oneOf(r.hotkey, HOTKEYS, DEFAULTS.hotkey),
    doubleTapHandsFree: bool(r.doubleTapHandsFree, DEFAULTS.doubleTapHandsFree),
    language: oneOf(r.language, ['auto', 'de', 'en'] as const, DEFAULTS.language),
    engine: oneOf(r.engine, ['parakeet-v3', 'whisper-turbo'] as const, DEFAULTS.engine),
    micDeviceId: typeof r.micDeviceId === 'string' ? r.micDeviceId : '',
    removeFillers: bool(r.removeFillers, DEFAULTS.removeFillers),
    voiceCommands: bool(r.voiceCommands, DEFAULTS.voiceCommands),
    polish: bool(r.polish, DEFAULTS.polish),
    keepInClipboard: bool(r.keepInClipboard, DEFAULTS.keepInClipboard),
    startWithWindows: bool(r.startWithWindows, DEFAULTS.startWithWindows),
    autoUpdate: bool(r.autoUpdate, DEFAULTS.autoUpdate),
    historyEnabled: bool(r.historyEnabled, DEFAULTS.historyEnabled),
    historyRetentionDays: Math.min(3650, Math.max(1, days)),
    pillAlwaysVisible: bool(r.pillAlwaysVisible, DEFAULTS.pillAlwaysVisible),
    mouseTarget: bool(r.mouseTarget, DEFAULTS.mouseTarget),
    mouseTargetAutoSend: bool(r.mouseTargetAutoSend, DEFAULTS.mouseTargetAutoSend),
    mouseTargetHighlight: bool(r.mouseTargetHighlight, DEFAULTS.mouseTargetHighlight),
    learnFromEdits: bool(r.learnFromEdits, DEFAULTS.learnFromEdits),
    dictionary: sanitizeDictionary(r.dictionary),
    onboardingDone: bool(r.onboardingDone, false),
  };
}

/** apply a partial update from the UI (validated through the same migration path) */
export function patchSettings(cur: Settings, patch: Partial<Settings>): Settings {
  return migrateSettings({ ...cur, ...patch, version: SETTINGS_VERSION });
}
