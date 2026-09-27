// Dictation flow: hotkey → mic → ASR → text pipeline → insert at cursor → history.
import { EventEmitter } from 'node:events';
import type { Mic } from './mic';
import type { AsrService } from './asrService';
import type { Pill } from './windows';
import type { History } from './history';
import type { Settings } from '../shared/settings';
import { t } from '../shared/i18n';
import { processTranscript, wordCount } from '../core/pipeline';
import { targetForExe } from '../core/smartLists';
import { insertText, type ClipboardPort, type InsertPhase, type KeySender } from './insert/inserter';
import { log, logText } from './log';

export type DictState = 'idle' | 'recording' | 'handsfree' | 'transcribing' | 'inserting';

export interface DictationDeps {
  mic: Mic;
  asr: AsrService;
  pill: Pill;
  history: History;
  settings: () => Settings;
  clipboard: ClipboardPort;
  keys: KeySender;
  foregroundExe: () => string;
  waitKeysReleased: () => Promise<void>;
  markInjecting: (ms: number) => void;
  onClipboardWrite: (phase: InsertPhase, text: string) => void;
  setWriting: (v: boolean) => void;
}

const MAX_SECONDS = 10 * 60;

export class Dictation extends EventEmitter {
  state: DictState = 'idle';
  private startedAt = 0;
  private app = '';
  private maxTimer: NodeJS.Timeout | null = null;
  constructor(private d: DictationDeps) { super(); }

  private L() { return this.d.settings().locale; }
  private set(s: DictState) {
    this.state = s;
    const mode = s === 'recording' ? 'recording' : s === 'handsfree' ? 'handsfree' : s === 'transcribing' || s === 'inserting' ? 'transcribing' : 'idle';
    this.d.pill.state({ mode, alwaysVisible: this.d.settings().pillAlwaysVisible });
    this.emit('state', s);
  }

  /** hotkey pressed (hold) */
  async start(): Promise<void> {
    if (this.state !== 'idle') return;
    if (!this.d.asr.ready) {
      const st = this.d.asr.state.status;
      this.d.pill.toast(t(this.L(), st === 'missing' || st === 'error' ? 'toastNoModel' : 'toastModelLoading'), 'info');
      return;
    }
    this.app = this.d.foregroundExe();
    this.startedAt = Date.now();
    this.set('recording');
    try {
      await this.d.mic.start(this.d.settings().micDeviceId);
    } catch (e) {
      log('mic start failed', e);
      this.cancel();
      this.d.pill.toast(t(this.L(), 'toastMicError'), 'error');
      return;
    }
    if ((this.state as DictState) !== 'recording' && (this.state as DictState) !== 'handsfree') { this.d.mic.cancel(); return; }
    this.maxTimer = setTimeout(() => void this.stop(), MAX_SECONDS * 1000);
  }

  handsFree() {
    if (this.state !== 'recording') return;
    this.set('handsfree');
    this.d.pill.toast(t(this.L(), 'toastHandsFree'), 'info', 1800);
  }

  cancel() {
    if (this.maxTimer) clearTimeout(this.maxTimer);
    this.maxTimer = null;
    if (this.state === 'recording' || this.state === 'handsfree') this.d.mic.cancel();
    if (this.state !== 'transcribing' && this.state !== 'inserting') this.set('idle');
  }

  /** hotkey released (or hands-free finished) */
  async stop(): Promise<void> {
    if (this.state !== 'recording' && this.state !== 'handsfree') return;
    if (this.maxTimer) clearTimeout(this.maxTimer);
    this.maxTimer = null;
    this.set('transcribing');
    const audio = await this.d.mic.stop();
    await this.process(audio);
  }

  /** transcribe + insert a finished recording (also used by the smoke test with a WAV) */
  async process(audio: Float32Array): Promise<void> {
    this.set('transcribing');
    const sec = audio.length / 16000;
    if (sec < 0.3) { this.set('idle'); this.d.pill.toast(t(this.L(), 'toastTooShort'), 'info', 1500); return; }
    const engine = this.d.asr.getEngine();
    if (!engine) { this.set('idle'); return; }
    const s = this.d.settings();
    try {
      const r = await engine.transcribe(audio, s.language);
      const text = processTranscript(r.text, {
        removeFillers: s.removeFillers, voiceCommands: s.voiceCommands, dictionary: s.dictionary, polish: s.polish,
        target: targetForExe(this.app),
      });
      log(`dictation: ${sec.toFixed(1)} s audio, asr ${r.ms} ms, ${r.segments} chunk(s), ${wordCount(text)} words, app ${this.app || '?'}` + (logText ? ` → ${text}` : ''));
      if (!text) { this.set('idle'); this.d.pill.toast(t(this.L(), 'toastNothing'), 'info', 1600); return; }
      this.state = 'inserting';
      await this.d.waitKeysReleased();
      // a space in front when continuing a sentence is the target app's business; we insert exactly the text
      this.d.markInjecting(250);
      await insertText(text, {
        clipboard: this.d.clipboard, keys: this.d.keys, keepInClipboard: s.keepInClipboard,
        onPhase: this.d.onClipboardWrite, setWriting: this.d.setWriting,
      });
      if (s.historyEnabled) {
        this.d.history.add({ text, raw: r.text, app: this.app, durationSec: Math.round(sec * 10) / 10, words: wordCount(text), ms: r.ms });
      }
      this.emit('dictated', text);
    } catch (e) {
      log('dictation failed', e);
      this.d.pill.toast(String(e instanceof Error ? e.message : e).slice(0, 80), 'error');
    } finally {
      this.set('idle');
    }
  }
}
