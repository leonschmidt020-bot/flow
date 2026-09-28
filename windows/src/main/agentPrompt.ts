// Electron glue for Agent-Prompts (src/agentPrompt): pill presenter, clipboard/ClipVault, „Einfügen“ into the dictation's
// target window, dictation history, hub IPC. index.ts only calls initAgentPrompt() and hands the hook to the dictation.
import { ipcMain, type BrowserWindow } from 'electron';
import path from 'node:path';
import { APBuilder } from '../agentPrompt/builder';
import { claudeStream, findClaudeBin } from '../agentPrompt/claudeCli';
import { appName, emptyContext, words, type APContext } from '../agentPrompt/core';
import { APFlow, type APActions, type APPhase, type APPresenter, type APTarget } from '../agentPrompt/flow';
import { apt } from '../agentPrompt/i18n';
import { APStore, byRules, recordGist, recordTitle, type APRecord } from '../agentPrompt/store';
import { appKind, chatTitle, type WinInfo } from '../core/mouseTarget';
import { wordCount } from '../core/pipeline';
import type { APAction, APCardView, APFlash, APRecordView } from '../shared/agentPrompt';
import type { Settings } from '../shared/settings';
import type { History } from './history';
import { insertText, type ClipboardPort, type InsertPhase, type KeySender } from './insert/inserter';
import type { CaptureResult, MouseTarget, Prepared } from './mouse/mouseTarget';
import type { NativeWindows } from './mouse/native';
import type { Pill } from './windows';

export interface AgentPromptInit {
  userData: string;
  pill: Pill;
  settings: () => Settings;
  clipboard: ClipboardPort;
  keys: KeySender;
  onClipboardWrite: (phase: InsertPhase, text: string, source?: string) => void;
  setWriting: (v: boolean) => void;
  markInjecting: (ms: number) => void;
  native: NativeWindows | null;
  mouse: MouseTarget | null;
  history: History;
  pushState: () => void;
  openHub: (page: string) => void;
  hubs: () => BrowserWindow[];
  log: (...a: unknown[]) => void;
  /** override for tests/self checks (default: search PATH + the usual install folders) */
  claudeBin?: () => string | null;
}

export interface DictationInfo { duration: number; exe: string; cap: CaptureResult | null }

export interface AgentPromptHandle {
  flow: APFlow;
  store: APStore;
  /** called by the dictation right after TextCleaner.applyRules – true = „Prompt: …“, do not paste */
  consume(cleaned: string, info: DictationInfo): boolean;
  /** after a normal paste: maybe offer the card (0.7 s later, like the Mac) */
  offerLater(text: string, info: { duration: number; exe: string; prep: Prepared | null }): void;
  /** global Esc (nothing else is using it) */
  escape(): void;
  claudeAvailable(): boolean;
}

/** Claude CLI lookup, cached for 30 s (installing it later works without a restart) */
function cachedLookup(find: () => string | null): () => string | null {
  let at = 0;
  let bin: string | null = null;
  return () => {
    const now = Date.now();
    if (now - at > 30_000) { at = now; try { bin = find(); } catch { bin = null; } }
    return bin;
  };
}

export function toRecordView(r: APRecord): APRecordView {
  return {
    id: r.id, created: r.created, prompt: r.prompt, original: r.original, appName: r.appName, source: r.source, note: r.note, trigger: r.trigger,
    buildMs: r.buildMs, byRules: byRules(r), title: recordTitle(r), tasks: recordGist(r).tasks,
  };
}

export function phaseView(p: APPhase, claude: boolean): APCardView {
  switch (p.kind) {
    case 'offer': return { kind: 'offer', words: p.detection.words, agentApp: p.detection.agentApp, technical: p.detection.technical.slice(0, 4) };
    case 'building': return { kind: 'building', partial: p.partial, words: p.words, startedAt: p.started, claude };
    case 'done': {
      const r = p.record;
      return { kind: 'done', id: r.id, prompt: r.prompt, original: r.original, source: r.source, note: r.note, buildMs: r.buildMs, byRules: byRules(r), gist: recordGist(r) };
    }
    case 'stopped': return { kind: 'stopped', stop: p.stop, reason: p.reason, original: p.original };
  }
}

/** the card lives in the pill window */
class PillPresenter implements APPresenter {
  isShowing = false;
  onAction: (a: APAction) => void = () => {};
  private seq = 0;
  constructor(private pill: Pill, private locale: () => 'de' | 'en', private claude: () => boolean) {
    pill.onAgentAction = (a) => this.onAction(a);
  }
  show(p: APPhase) {
    if (!this.isShowing) this.seq++;
    this.isShowing = true;
    this.pill.agentCard({ seq: this.seq, view: phaseView(p, this.claude()), locale: this.locale() });
  }
  close() {
    if (!this.isShowing) return;
    this.isShowing = false;
    this.pill.agentCard(null);
  }
  flash(f: APFlash) { this.pill.agentFlash(f); }
}

export function initAgentPrompt(o: AgentPromptInit): AgentPromptHandle {
  const log = (line: string) => o.log(line);
  const bin = o.claudeBin ?? cachedLookup(() => findClaudeBin());
  const claudeAvailable = () => !!bin();
  const store = new APStore(path.join(o.userData, 'prompts'), log);
  const presenter = new PillPresenter(o.pill, () => o.settings().locale, claudeAvailable);

  // clipboard writes in order (original first, then the prompt) – ClipVault gets the entry with its source
  let clipQueue: Promise<void> = Promise.resolve();
  const copy = (text: string, source: string) => {
    clipQueue = clipQueue.then(async () => {
      o.setWriting(true);
      try {
        await o.clipboard.writeText(text);
        o.onClipboardWrite('keep', text, source);
      } catch (e) { o.log('agent-prompt: clipboard', e); } finally { o.setWriting(false); }
    });
  };

  /** „Einfügen“: the dictation's target window to the front (if it is not already), paste, Enter only with the setting */
  const insert = async (text: string, source: string, target: APTarget | null): Promise<boolean> => {
    await clipQueue;
    try {
      const n = o.native;
      if (target && n) {
        const fg = n.foreground();
        if (!fg || fg.hwnd !== target.hwnd) {
          const how = o.mouse ? await o.mouse.focusWindow(target.hwnd) : null;
          if (!how) return false;
        }
      }
      o.markInjecting(250);
      await insertText(text, {
        clipboard: o.clipboard, keys: o.keys, keepInClipboard: true,
        onPhase: (phase, t) => o.onClipboardWrite(phase, t, source), setWriting: o.setWriting,
      });
      const s = o.settings();
      const win = target?.win as WinInfo | undefined;
      if (s.mouseTarget && s.mouseTargetAutoSend && o.mouse && win) {
        const kind = appKind(win.exe, win.cls);
        const prep: Prepared = {
          method: '0', note: 'Agent-Prompt', extraMs: 0,
          cap: { point: { x: win.rect.x + win.rect.width / 2, y: win.rect.y + win.rect.height / 2 }, win, kind, chatSite: kind === 'browser' && chatTitle(win.title), covered: false, alreadyForeground: true, prev: null, plan: null },
        };
        const extra = await o.mouse.autoSend(text, prep);
        log(`Agent-Prompt eingefügt · ${extra}`);
      }
      return true;
    } catch (e) {
      o.log('agent-prompt: insert failed', e);
      return false;
    }
  };

  const actions: APActions = {
    copy,
    insert,
    openHub: (id) => o.openHub('prompts:' + id),
    addHistory: (text, duration, exe) => {
      if (!o.settings().historyEnabled) return;
      o.history.add({ text, raw: text, app: exe, durationSec: Math.round(duration * 10) / 10, words: wordCount(text), ms: 0 });
      o.pushState();
    },
    toast: (t) => o.pill.toast(t, 'info', 2400),
    pillBusy: (on) => o.pill.state({ apBusy: on }),
    now: () => Date.now(),
    claudeAvailable,
    log,
    text: (k) => apt(o.settings().locale, k),
  };

  const flow = new APFlow({
    mode: () => o.settings().agentPrompts,
    store, presenter, actions,
    makeBuilder: () => new APBuilder({ runner: claudeStream({ bin }), available: claudeAvailable, log }),
  });

  /** the target of the dictation: window under the mouse (mouse target) or the foreground window – never Flow itself */
  const target = (cap: CaptureResult | null, winOverride?: WinInfo | null): APTarget | null => {
    let win: WinInfo | null = winOverride ?? null;
    if (!win && cap?.t === 'target') win = cap.cap.win;
    if (!win) { try { win = o.native?.foreground() ?? null; } catch { win = null; } }
    if (!win || win.pid === process.pid) return null;
    return { hwnd: win.hwnd, pid: win.pid, exe: win.exe, title: win.title, win };
  };
  const context = (t: APTarget | null, exe: string): APContext => {
    const e = t?.exe || exe;
    return { ...emptyContext(), appName: appName(e), exe: e, windowTitle: t?.title ?? '' };
  };

  // hub
  ipcMain.handle('prompts:list', () => store.records.map(toRecordView));
  ipcMain.handle('prompts:delete', (_e, id: unknown) => { if (typeof id === 'string') store.delete(id); });
  ipcMain.handle('prompts:copy', (_e, id: unknown, which: unknown) => {
    const r = store.record(typeof id === 'string' ? id : null);
    if (!r) return false;
    if (which === 'original') copy(r.original, 'Diktat (Original)'); else copy(r.prompt, 'Agent-Prompt');
    return true;
  });
  store.onChange = () => { for (const w of o.hubs()) if (!w.isDestroyed()) w.webContents.send('prompts:changed'); };

  return {
    flow, store, claudeAvailable,
    consume(cleaned, info) {
      if (o.settings().agentPrompts === 'off') return false;
      const t = target(info.cap);
      return flow.consume(cleaned, { duration: info.duration, target: t, context: context(t, info.exe) });
    },
    offerLater(text, info) {
      if (o.settings().agentPrompts !== 'on' || words(text) < 35) return;
      const intoTarget = info.prep?.cap && ['0', 'a', 'b', 'c'].includes(info.prep.method) ? info.prep.cap.win : null;
      setTimeout(() => {
        const t = target(null, intoTarget);
        flow.offerIfLong(text, { duration: info.duration, target: t, context: context(t, info.exe) });
      }, 700);
    },
    escape() { flow.escape(o.pill.agentHover); },
  };
}
