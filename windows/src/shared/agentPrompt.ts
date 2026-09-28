// Agent-Prompt: types shared by the main process (flow, presenter, hub IPC) and the renderers (pill card, hub page).

/** Einstellungen › Agent-Prompts */
export type APMode = 'on' | 'explicitOnly' | 'off';
export const AP_MODES: readonly APMode[] = ['on', 'explicitOnly', 'off'];

export type APAction = 'build' | 'dismissOffer' | 'cancel' | 'copy' | 'insert' | 'open' | 'copyOriginal' | 'insertOriginal' | 'retry' | 'close';
export const AP_ACTIONS: readonly APAction[] = ['build', 'dismissOffer', 'cancel', 'copy', 'insert', 'open', 'copyOriginal', 'insertOriginal', 'retry', 'close'];
export type APFlash = 'copied' | 'copiedOriginal' | 'inserted';

export interface APGistView { goal: string; tasks: number; criteria: number; rules: number; open: number }

/** what the pill card shows – plain data, localised in the renderer */
export type APCardView =
  | { kind: 'offer'; words: number; agentApp: boolean; technical: string[] }
  | { kind: 'building'; partial: string; words: number; startedAt: number; claude: boolean }
  | {
    kind: 'done'; id: string; prompt: string; original: string; source: string; note: string; buildMs: number;
    byRules: boolean; gist: APGistView;
  }
  | { kind: 'stopped'; stop: 'cancelled' | 'failed'; reason: string; original: string };

export interface APCardMessage {
  /** changes whenever a NEW card starts (not on live-text updates) */
  seq: number;
  view: APCardView;
  locale: 'de' | 'en';
}

/** one prompt in the hub list */
export interface APRecordView {
  id: string; created: string; prompt: string; original: string; appName: string; source: string; note: string;
  trigger: string; buildMs: number; byRules: boolean; title: string; tasks: number;
}
