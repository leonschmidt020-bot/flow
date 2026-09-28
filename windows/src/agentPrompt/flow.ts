// Agent-Prompt: the flow (dictation → card → prompt → clipboard/insert/history). Port of APFlow.swift. Electron-free –
// everything that acts on the outside world is behind `APActions` / `APPresenter`, so the whole flow is unit-tested.
//
// Entry from Dictation.process (right after TextCleaner.applyRules, BEFORE list formatting/pasting):
//
//   if (flow.consume(cleaned, { duration, target, context })) return;
//
//   true  = „Prompt: …“ recognised → nothing is pasted. The original (without the trigger) is saved AT ONCE as
//           „Diktat (Original)“ (clipboard + ClipVault) and in the dictation history, then the prompt is built. Done →
//           the prompt goes to the clipboard as „Agent-Prompt“ + prompts/ (with the original). Cancel/failure → card with
//           „Original einfügen/kopieren“.
//   false = normal dictation. After pasting: `flow.offerIfLong(…)` – for a long task aimed at an agent the subtle card
//           „Daraus einen Agent-Prompt machen?“ appears (only with the Claude CLI, only with the setting „An“).
//
// Without the Claude CLI the prompt is built by rules on request (nothing lost, nothing reworded) and nothing is offered
// automatically. Never: clipboard contents to Claude. Context = app, window title (developer/agent apps only).
import { APBuilder, type APOutcome } from './builder';
import { detect, includesTitle, match, words, type APContext, type Detection } from './core';
import { newRecordId, type APRecord, type APStore } from './store';
import type { APAction, APFlash, APMode } from '../shared/agentPrompt';

/** where „Einfügen“ writes: the window that was the target of the dictation (under the mouse or in front) */
export interface APTarget {
  hwnd: number; pid: number; exe: string; title: string;
  /** platform window info (Windows: WinInfo for focusing + „Danach automatisch abschicken“) */
  win?: unknown;
}

export type APPhase =
  | { kind: 'offer'; detection: Detection }
  | { kind: 'building'; partial: string; words: number; started: number }
  | { kind: 'done'; record: APRecord }
  | { kind: 'stopped'; stop: 'cancelled' | 'failed'; reason: string; original: string };

export interface APPresenter {
  show(phase: APPhase): void;
  close(): void;
  readonly isShowing: boolean;
  onAction: (a: APAction) => void;
  /** briefly „Kopiert ✓“ / „Eingefügt ✓“ */
  flash(what: APFlash): void;
}

/** everything with an effect on the outside world – replaceable in tests (no clipboard, no pasting, no hub) */
export interface APActions {
  /** clipboard + ClipVault entry with this source („Diktat (Original)“ / „Agent-Prompt“) */
  copy(text: string, source: string): void;
  /** paste into the target window (brought to the front first); resolves false when it did not work */
  insert(text: string, source: string, target: APTarget | null): Promise<boolean>;
  openHub(id: string): void;
  addHistory(text: string, duration: number, exe: string): void;
  toast(text: string): void;
  /** pill shows „prompt is being built“ (true) or rests again (false) */
  pillBusy(on: boolean): void;
  now(): number;
  /** Claude CLI installed? (optional) – without it Flow builds by rules and offers nothing on its own */
  claudeAvailable(): boolean;
  /** one line – never dictated text */
  log(line: string): void;
  /** UI strings for the two toasts */
  text(key: 'promptInClipboard' | 'originalInClipboard'): string;
}

export interface APJobInput { duration: number; target: APTarget | null; context: APContext }

export const SOURCE_ORIGINAL = 'Diktat (Original)';
export const SOURCE_PROMPT = 'Agent-Prompt';

class Job {
  readonly id = newRecordId();
  readonly abort = new AbortController();
  record: APRecord | null = null;
  ended = false;
  constructor(readonly original: string, readonly context: APContext, readonly target: APTarget | null, readonly trigger: string, readonly started: number) {}
}

export interface APFlowDeps {
  mode: () => APMode;
  store: APStore;
  presenter: APPresenter;
  actions: APActions;
  makeBuilder: () => APBuilder;
  /** live text at most every … ms (Mac: ~12×/s) */
  partialMs?: number;
}

export class APFlow {
  private job: Job | null = null;
  /** open offer (auto-detection): text + target until the click */
  private offer: { text: string; duration: number; target: APTarget | null; context: APContext; detection: Detection } | null = null;
  /** times for the tempo line in the log */
  lastTimings: { cardMs: number; firstTextMs: number | null; doneMs: number | null } = { cardMs: 0, firstTextMs: null, doneMs: null };

  constructor(private d: APFlowDeps) {
    d.presenter.onAction = (a) => this.handle(a);
  }

  get isBuilding(): boolean { return !!this.job && !this.job.ended; }
  get currentJob(): { id: string; original: string; record: APRecord | null; ended: boolean } | null { return this.job; }

  // MARK: 1. on request („Prompt: …“)

  /** returns true when the dictation was a prompt request (then it must not be pasted) */
  consume(text: string, o: APJobInput): boolean {
    if (this.d.mode() === 'off') return false;
    const m = match(text);
    if (!m) return false;
    this.d.actions.log(`Agent-Prompt: Auslöser erkannt – ${words(m.body)} Wörter${m.atEnd ? ' (am Ende)' : ''}`);
    // the original is NEVER lost: clipboard + ClipVault („Diktat (Original)“) + dictation history at once
    this.d.actions.copy(m.body, SOURCE_ORIGINAL);
    this.d.actions.addHistory(m.body, o.duration, o.target?.exe ?? o.context.exe);
    this.start(m.body, o.context, o.target, 'zuruf');
    return true;
  }

  // MARK: 2. detected automatically (after the normal paste)

  /** right after pasting. Shows at most one subtle offer card. */
  offerIfLong(text: string, o: APJobInput): Detection | null {
    if (this.d.mode() !== 'on' || this.isBuilding || this.d.presenter.isShowing) return null;
    // without the Claude CLI only on request (the rule prompt is a good fallback, but no reason to interrupt unasked)
    if (!this.d.actions.claudeAvailable()) return null;
    const det = detect({ text, duration: o.duration, exe: o.target?.exe ?? o.context.exe, title: o.target?.title ?? o.context.windowTitle });
    this.d.actions.log(`Agent-Prompt-Erkennung: ${det.offer ? 'Vorschlag' : 'nein'} · Punkte ${det.score} · ${det.words} Wörter · ${Math.round(o.duration)} s`
      + (det.agentApp ? ' · Agent-App' : '') + ` · ${det.imperative.length} Auftrag · ${det.technical.length} Technik · ${det.chatty.length} Plaudern`);
    if (!det.offer) return det;
    this.offer = { text, duration: o.duration, target: o.target, context: o.context, detection: det };
    this.d.presenter.show({ kind: 'offer', detection: det });
    return det;
  }

  // MARK: building

  private start(original: string, context: APContext, target: APTarget | null, trigger: string) {
    this.job?.abort.abort();
    const a = this.d.actions;
    const j = new Job(original, context, target, trigger, a.now());
    this.job = j;
    const n = words(original);
    const tCard = a.now();
    this.d.presenter.show({ kind: 'building', partial: '', words: n, started: j.started });
    this.lastTimings = { cardMs: Math.round(a.now() - tCard), firstTextMs: null, doneMs: null };
    a.pillBusy(true);
    const builder = this.d.makeBuilder();
    let lastShown = -Infinity;
    const every = this.d.partialMs ?? 80;
    void builder.build({ transcript: original, context }, (partial) => {
      if (this.job !== j || j.ended || !partial) return;
      if (this.lastTimings.firstTextMs === null) this.lastTimings.firstTextMs = Math.round(a.now() - j.started);
      if (a.now() - lastShown < every) return;
      lastShown = a.now();
      this.d.presenter.show({ kind: 'building', partial, words: n, started: j.started });
    }, j.abort.signal).then((r) => this.finishBuild(j, r), () => this.finishBuild(j, { t: 'failed', why: 'Fehler' }));
  }

  private finishBuild(j: Job, r: APOutcome) {
    if (this.job !== j || j.ended) return;   // cancelled meanwhile / newer job: a late answer changes nothing
    j.ended = true;
    const a = this.d.actions;
    a.pillBusy(false);
    const ms = Math.round(a.now() - j.started);
    this.lastTimings.doneMs = ms;
    if (r.t === 'ok') {
      const res = r.res;
      const rec: APRecord = {
        id: j.id, created: new Date(a.now()).toISOString(), prompt: res.prompt, original: j.original, appName: j.context.appName,
        windowTitle: includesTitle(j.context) ? j.context.windowTitle : '', source: res.source, note: res.note, trigger: j.trigger, buildMs: res.ms,
      };
      j.record = rec;
      this.d.store.add(rec);
      a.copy(res.prompt, SOURCE_PROMPT);
      this.d.presenter.show({ kind: 'done', record: rec });
      const t = this.lastTimings;
      a.log(`Agent-Prompt fertig: ${res.source}${res.note ? ` (${res.note})` : ''} · ${words(j.original)} → ${words(res.prompt)} Wörter · `
        + `Karte ${t.cardMs} ms, erstes Wort ${t.firstTextMs !== null ? `${t.firstTextMs} ms` : '–'}, fertig ${ms} ms`
        + (res.missing.length ? ` · ${res.missing.length} Zahl(en)/Datei(en) nicht wörtlich übernommen` : ''));
    } else if (r.t === 'failed') {
      this.d.presenter.show({ kind: 'stopped', stop: 'failed', reason: r.why, original: j.original });
      a.log(`Agent-Prompt nicht gebaut: ${r.why} · ${ms} ms`);
    } else {
      this.d.presenter.show({ kind: 'stopped', stop: 'cancelled', reason: 'Abgebrochen', original: j.original });
      a.log(`Agent-Prompt abgebrochen · ${ms} ms`);
    }
  }

  cancel(): void {
    const j = this.job;
    if (!j || j.ended) return;
    j.abort.abort();
    // switch at once (the process is ended in the background)
    this.finishBuild(j, { t: 'cancelled' });
  }

  // MARK: card

  /** Esc (global key): while building only with the mouse on the card (Esc in Claude Code must not cancel the prompt by
   *  accident) – otherwise close the card. Nothing is lost. */
  escape(mouseOnCard: boolean): void {
    if (!this.d.presenter.isShowing) return;
    if (this.isBuilding) { if (mouseOnCard) this.cancel(); return; }
    this.handle('close');
  }

  handle(action: APAction): void {
    const a = this.d.actions;
    const p = this.d.presenter;
    switch (action) {
      case 'build': {
        const o = this.offer;
        if (!o) { p.close(); return; }
        this.offer = null;
        this.start(o.text, o.context, o.target, 'vorschlag');
        return;
      }
      case 'dismissOffer':
        this.offer = null;
        p.close();
        return;
      case 'cancel':
        this.cancel();
        return;
      case 'close':
        if (this.isBuilding) { this.cancel(); return; }
        this.offer = null;
        p.close();
        return;
      case 'copy': {
        const r = this.job?.record;
        if (!r) return;
        a.copy(r.prompt, SOURCE_PROMPT);
        p.flash('copied');
        return;
      }
      case 'insert': {
        const r = this.job?.record;
        if (!r) return;
        const target = this.job?.target ?? null;
        p.close();
        void a.insert(r.prompt, SOURCE_PROMPT, target).then((ok) => { if (!ok) a.toast(a.text('promptInClipboard')); });
        return;
      }
      case 'open': {
        const r = this.job?.record;
        if (!r) return;
        p.close();
        a.openHub(r.id);
        return;
      }
      case 'copyOriginal': {
        const o = this.job?.original;
        if (!o) return;
        a.copy(o, SOURCE_ORIGINAL);
        p.flash('copiedOriginal');
        return;
      }
      case 'insertOriginal': {
        const j = this.job;
        if (!j) return;
        p.close();
        void a.insert(j.original, SOURCE_ORIGINAL, j.target).then((ok) => { if (!ok) a.toast(a.text('originalInClipboard')); });
        return;
      }
      case 'retry': {
        const j = this.job;
        if (!j || !j.ended) return;
        this.start(j.original, j.context, j.target, j.trigger);
        return;
      }
    }
  }
}

