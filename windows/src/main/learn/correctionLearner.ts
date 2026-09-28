// Word learner („Wort gelernt?“) – port of CorrectionLearner.swift (the watching part; the rules are in core/learner.ts).
//
// Flow (Mac 1.7.15):
//   1. right after the paste: find the spot (`Anchor`) – in the text field, in Claude Code's input box or in the terminal
//      rows (Windows Terminal/conhost via UI Automation TextPattern, xterm.js in VS Code & co. via its row list).
//      Up to 8 tries, 0.5 s apart – terminals draw the pasted text late.
//   2. every 1.5 s read again and compare (`reading`), decide in `Tracker.step`.
//   3. ask when the same change stood for three readings – or right away when editing is over: message sent (Claude
//      Code: the text now stands as „❯ …“ in the history, chat field emptied), new dictation (`finish`), text gone, 3 min up.
// Never: password fields (UIA IsPassword), password-manager apps. Only reads while the watched app is in front.
// The log never contains the text – only what happened („beobachte Code.exe (Claude-Code-Eingabe)“).
import {
  locateInsert, options, PLACE_LABEL, readable, reading, screenFromRead, Tracker, knownWords, norm, words,
  type Anchor, type ReadResult, type Suggestion,
} from '../../core/learner';
import { isPasswordApp } from '../../core/mouseTarget';
import type { UiaPort } from '../uia/types';

export interface LearnerDeps {
  uia: UiaPort;
  /** foreground process right now (pid + exe) */
  foreground: () => { pid: number; exe: string } | null;
  onCandidate: (s: Suggestion[]) => void;
  /** pairs the user said „Nein“ to in this session */
  isRejected?: (old: string, nw: string) => boolean;
  log?: (...a: unknown[]) => void;
  now?: () => number;
  timers?: { setTimeout: typeof setTimeout; clearTimeout: typeof clearTimeout; setInterval: typeof setInterval; clearInterval: typeof clearInterval };
}

interface Session {
  pid: number;
  exe: string;
  anchor: Anchor;
  started: number;
  gen: number;
  tracker: Tracker;
  asked: boolean;
}

export const WATCH_SECONDS = 180;
export const POLL_MS = 1500;
export const ATTEMPTS = 8;

export class CorrectionLearner {
  private session: Session | null = null;
  private generation = 0;
  private interval: ReturnType<typeof setInterval> | null = null;
  private pendingTimer: ReturnType<typeof setTimeout> | null = null;
  private busy = false;
  private readonly now: () => number;
  private readonly t: NonNullable<LearnerDeps['timers']>;

  constructor(private d: LearnerDeps) {
    this.now = d.now ?? (() => Date.now());
    this.t = d.timers ?? { setTimeout, clearTimeout, setInterval, clearInterval };
  }

  private log(m: string) { this.d.log?.(`Lernen: ${m}`); }
  get watching(): boolean { return this.session !== null; }

  /** right after pasting */
  watch(inserted: string, target: { pid: number; exe: string } | null): void {
    this.stop();
    const gen = this.generation;
    if (!this.d.uia.available) { this.log('aus – UI Automation nicht verfügbar'); return; }
    const fg = target ?? this.d.foreground();
    if (!fg || !fg.pid) { this.log('keine App im Vordergrund'); return; }
    if (isPasswordApp(fg.exe)) { this.log('übersprungen (Passwort-App)'); return; }
    const ins = norm(inserted);
    if (!words(ins).length) { this.log('übersprungen (kein Wort)'); return; }
    let tries = 0;
    let sawElement = false;
    const attempt = async () => {
      this.pendingTimer = null;
      if (gen !== this.generation) return;
      tries++;
      let r: ReadResult | null = null;
      try { r = await this.d.uia.read(); } catch { r = null; }
      if (gen !== this.generation) return;
      if (r?.pwd) { this.log('Passwortfeld – übersprungen'); return; }
      if (r && r.pid && r.pid !== fg.pid) r = null; // focus is somewhere else (our pill never takes it)
      if (r && r.kind !== 'none') sawElement = true;
      const found = r && r.kind !== 'none' ? locateInsert(ins, r) : null;
      if (found?.result.t === 'found') {
        const a = found.result.anchor;
        this.log(`beobachte ${fg.exe || '?'}${a.place === 'field' ? '' : ` (${PLACE_LABEL[a.place]})`}`);
        this.session = { pid: fg.pid, exe: fg.exe, anchor: a, started: this.now(), gen, tracker: new Tracker(), asked: false };
        this.interval = this.t.setInterval(() => void this.poll(false), POLL_MS);
        return;
      }
      if (found?.result.t === 'sentAlready') { this.log('Text schon abgeschickt – nichts zu beobachten'); return; }
      if (tries < ATTEMPTS) { this.pendingTimer = this.t.setTimeout(() => void attempt(), 500); return; }
      if (!sawElement) { this.log(`kein Textfeld lesbar in ${fg.exe || '?'}`); return; }
      const score = found?.result.t === 'notFound' ? found.result.score : 0;
      const hint = r?.kind === 'xterm' && !(r.rows ?? []).some((x) => x.trim())
        ? ' – VS Code zeigt Terminal-Zeilen nur mit eingeschalteter Bildschirmleser-Unterstützung (editor.accessibilitySupport)'
        : found?.screen.collapsed ? ' – Claude Code zeigt ihn eingeklappt („[Pasted text …]“), dort nicht lesbar' : '';
      this.log(`Text nicht gefunden in ${fg.exe || '?'} (bester Treffer ${score}/${words(ins).length} Wörter)${hint}`);
    };
    this.pendingTimer = this.t.setTimeout(() => void attempt(), 400);
  }

  /** stop without a last comparison */
  stop(): void {
    this.generation++;
    if (this.interval) this.t.clearInterval(this.interval);
    if (this.pendingTimer) this.t.clearTimeout(this.pendingTimer);
    this.interval = null;
    this.pendingTimer = null;
    this.session = null;
  }

  /** a new dictation starts: the user is done correcting → read and compare one last time, then end.
   *  (Before Mac 1.7.15 the session was just dropped here – a correction right before the next dictation got lost.) */
  async finish(): Promise<void> {
    const s = this.session;
    this.generation++;
    if (this.interval) this.t.clearInterval(this.interval);
    if (this.pendingTimer) this.t.clearTimeout(this.pendingTimer);
    this.interval = null;
    this.pendingTimer = null;
    if (!s) return;
    await this.poll(true, s);
    if (this.session === s) this.session = null;
  }

  /** one reading (public for tests). `final` = editing is over (new dictation). */
  async poll(final: boolean, sess?: Session): Promise<void> {
    const s = sess ?? this.session;
    if (!s || (this.busy && !final)) return;
    const timeUp = this.now() - s.started > WATCH_SECONDS * 1000;
    if (!final && !timeUp) {
      // briefly somewhere else → wait (never read another app's field)
      if (this.d.foreground()?.pid !== s.pid) return;
    }
    this.busy = true;
    let r: ReadResult | null = null;
    try { r = await this.d.uia.reread(); } catch { r = null; } finally { this.busy = false; }
    if (r && r.pid && r.pid !== s.pid) r = null;
    if (r?.pwd) { this.log('Passwortfeld – Beobachtung beendet'); this.end(s, final); return; }
    const ok = readable(r);
    const rd = ok && r ? reading(s.anchor, screenFromRead(r, knownWords(s.anchor.inserted))) : null;
    const step = s.tracker.step(rd, ok, final || timeUp);
    for (const n of s.tracker.notes) this.log(n);
    if (step.grammarOnly) this.log('Änderung ist nur Grammatik/Groß-klein – nicht gefragt');
    if (step.ask.length) {
      const open = step.ask.filter((p) => !this.d.isRejected?.(p.old, p.new));
      if (open.length) {
        s.asked = true;
        this.log(`erkannt ${open.length} Korrektur(en)`);
        this.d.onCandidate(open.map((p) => ({ old: p.old, options: options(p.old, p.new, s.tracker.seen.get(p.old) ?? []) })));
      }
    }
    if (!step.end) return;
    const t = s.tracker;
    const what = s.asked ? 'gefragt' : t.everSaw ? 'Änderung gesehen, aber nicht stabil' : 'keine Änderung gesehen';
    const stats = ` (${t.reads} Lesungen${t.unreadable > 0 ? `, ${t.unreadable} ohne Text – UI Automation?` : ''})`;
    if (step.end === 'abgeschickt') this.log(`abgeschickt – gesendete Fassung verglichen, ${what}`);
    else if (step.end === 'Text nicht mehr da') this.log(`Text nicht mehr da – ${what}${stats}`);
    else this.log(`Sitzung beendet ${timeUp && !final ? 'nach 3 Min.' : '(neues Diktat)'} – ${what}${stats}`);
    this.end(s, final);
  }

  private end(s: Session, final: boolean) {
    if (this.session !== s) return;
    this.session = null;
    if (!final && s.gen === this.generation) this.stop();
  }
}
