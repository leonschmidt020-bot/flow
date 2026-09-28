// „Text dorthin, wo die Maus ist“ (Einstellungen › Einfügen, default OFF) – port of MouseTarget.swift.
//
// Flow:
//   1. hotkey pressed: `beginTracking()` – while the user speaks, a blue frame „Text kommt hierher“ follows the window
//      under the mouse (~8 Hz, only when it is NOT the active window; can be switched off).
//      Lesson from the Mac (27.09.2026): people press the key first and THEN move the mouse to the window the text should
//      go to – so the window under the mouse at key RELEASE counts, not the one at press.
//   2. hotkey released: `capture()` – WindowFromPoint → GetAncestor(GA_ROOT); own/tool/click-through windows are looked
//      through, desktop/taskbar/start menu are no target, cloaked/minimised windows are skipped. If it already is the
//      foreground window nothing special happens (method 0, 0 ms). Otherwise UI Automation is asked – in the background,
//      while speech recognition runs – what lies under the mouse (text field? password? xterm terminal? button?).
//   3. text ready: `prepare()` – bring the window to the front (SetForegroundWindow; Windows refuses that to background
//      processes, so: plain call right after our own hook saw the key release → AttachThreadInput to the foreground
//      thread → ALT tap), verified with GetForegroundWindow, ≤ 400 ms in total. Then pick the input:
//        a) text field under the mouse → UI Automation SetFocus (no click)
//        c) terminal / chat input: ONE left click at the release point – only on the client area (WM_NCHITTEST ==
//           HTCLIENT), never on buttons/links/tabs (UI Automation), never when something lies above the point
//        b) otherwise the window's remembered focus (Windows restores it on activation)
//        d) the window did not come to the front / password field → back, paste normally, toast
//   4. paste as usual; optionally Enter afterwards („Danach automatisch abschicken“, default OFF) – only when the paste
//      happened and the app is a terminal/chat (core/mouseTarget.ts › autoSend).
// Never: password fields, password-manager apps, clicks on anything but a terminal surface / chat input.
// Log: one line per dictation (app exe, method, extra ms) – never the dictated text, never window titles.
import {
  appKind, autoSend as autoSendRule, chatTitle, clickAllowed, moved, pasteConfirmed, physToDipRect, pickEditable, resolveTarget, scaleAt,
  SENDS_AFTER, type AppKind, type DisplayMap, type Method, type Pick, type Point, type Rect, type WinInfo,
} from '../../core/mouseTarget';
import type { UiaElement, UiaPort } from '../uia/types';
import type { FocusTechnique, NativeWindows } from './native';

export interface HighlightPort { show(rectDip: Rect, label: string): void; hide(): void }

export interface Capture {
  point: Point;
  win: WinInfo;
  kind: AppKind;
  chatSite: boolean;
  covered: boolean;
  alreadyForeground: boolean;
  /** foreground window at release (for „switched during dictation?“ and going back on d) */
  prev: WinInfo | null;
  /** element under the mouse, asked while speech recognition runs */
  plan: Promise<UiaElement | null> | null;
}
export type CaptureResult = { t: 'target'; cap: Capture } | { t: 'none'; why: string };

export interface Prepared {
  method: Method;
  note: string;
  extraMs: number;
  cap: Capture | null;
  focus?: FocusTechnique;
  toast?: string;
}

export type MouseTargetText = 'label' | 'toastNormal' | 'toastFocusFailed';

export interface MouseTargetDeps {
  native: NativeWindows;
  uia: UiaPort;
  highlight: HighlightPort | null;
  settings: () => { mouseTarget: boolean; mouseTargetHighlight: boolean };
  text: (k: MouseTargetText) => string;
  ownPid: number;
  displays: () => DisplayMap[];
  log?: (...a: unknown[]) => void;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /** our own injected keys (ALT tap, Enter) must not trigger the hotkey */
  markInjecting?: (ms: number) => void;
  hotkeyHeld?: () => boolean;
  timers?: { setInterval: typeof setInterval; clearInterval: typeof clearInterval };
}

export const TRACK_MS = 125; // ~8 Hz
export const FOCUS_BUDGET_MS = 400;

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function withTimeout<T>(p: Promise<T>, ms: number, sleep: (ms: number) => Promise<void>): Promise<T | null> {
  return Promise.race([p.catch(() => null), sleep(ms).then(() => null)]);
}

export class MouseTarget {
  private timer: ReturnType<typeof setInterval> | null = null;
  private last: Point | null = null;
  private shownFor = 0;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(private d: MouseTargetDeps) {
    this.now = d.now ?? (() => Date.now());
    this.sleep = d.sleep ?? defaultSleep;
  }

  private log(...a: unknown[]) { this.d.log?.(...a); }

  resolve(p: Point): Pick {
    return resolveTarget(this.d.native.windowFromPoint(p), () => this.d.native.zOrder(), p, this.d.ownPid);
  }

  // MARK: 1. while speaking – the frame follows the mouse

  beginTracking(): void {
    this.endTracking();
    if (!this.d.settings().mouseTarget) return;
    this.last = null;
    this.tick();
    const t = this.d.timers ?? { setInterval, clearInterval };
    this.timer = t.setInterval(() => this.tick(), TRACK_MS);
  }

  /** one tracking step (public for tests) */
  tick(): void {
    const hl = this.d.highlight;
    if (!hl) return;
    try {
      if (!this.d.settings().mouseTargetHighlight) { this.hideFrame(); return; }
      const p = this.d.native.cursorPos();
      if (!moved(this.last, p)) return;
      this.last = p;
      const pick = this.resolve(p);
      const fg = this.d.native.foreground();
      if (pick.t !== 'target' || (fg && fg.hwnd === pick.win.hwnd) || pick.win.rect.width <= 40 || pick.win.rect.height <= 40) { this.hideFrame(); return; }
      hl.show(physToDipRect(pick.win.rect, this.d.displays()), this.d.text('label'));
      this.shownFor = pick.win.hwnd;
    } catch (e) {
      this.log('mouse-target: tracking', e);
      this.hideFrame();
    }
  }

  private hideFrame() { if (this.shownFor !== -1) { this.d.highlight?.hide(); this.shownFor = -1; } }

  endTracking(): void {
    if (this.timer) (this.d.timers ?? { setInterval, clearInterval }).clearInterval(this.timer);
    this.timer = null;
    this.last = null;
    this.shownFor = 0;
    this.d.highlight?.hide();
  }

  get tracking(): boolean { return this.timer !== null; }

  // MARK: 2. key released

  capture(): CaptureResult {
    try {
      const p = this.d.native.cursorPos();
      const pick = this.resolve(p);
      if (pick.t !== 'target') return { t: 'none', why: pick.why };
      const win = pick.win;
      const prev = this.d.native.foreground();
      const alreadyForeground = !!prev && prev.hwnd === win.hwnd;
      const kind = appKind(win.exe, win.cls);
      const cap: Capture = {
        point: p, win, kind, chatSite: kind === 'browser' && chatTitle(win.title), covered: pick.covered, alreadyForeground, prev, plan: null,
      };
      if (!alreadyForeground && this.d.uia.available) cap.plan = this.d.uia.at(p).catch(() => null);
      return { t: 'target', cap };
    } catch (e) {
      this.log('mouse-target: capture', e);
      return { t: 'none', why: 'Fehler beim Suchen' };
    }
  }

  // MARK: 3. before pasting

  private async poll(ms: number, cond: () => boolean | Promise<boolean>): Promise<boolean> {
    const end = this.now() + ms;
    do {
      if (await cond()) return true;
      await this.sleep(8);
    } while (this.now() < end);
    return !!(await cond());
  }

  /** bring `hwnd` to the front; returns the technique that worked or null (≤ FOCUS_BUDGET_MS) */
  async focusWindow(hwnd: number): Promise<FocusTechnique | null> {
    const deadline = this.now() + FOCUS_BUDGET_MS;
    const isFront = () => this.d.native.foreground()?.hwnd === hwnd;
    for (const how of ['direct', 'attach', 'alt'] as const) {
      if (how === 'alt') this.d.markInjecting?.(120);
      try { this.d.native.setForeground(hwnd, how); } catch (e) { this.log('mouse-target: setForeground', how, e); }
      const left = deadline - this.now();
      const budget = how === 'direct' ? Math.min(60, left) : how === 'attach' ? Math.min(120, left) : left;
      if (budget > 0 && await this.poll(budget, isFront)) return how;
      if (isFront()) return how;
      if (this.now() >= deadline) break;
    }
    return null;
  }

  private async restore(prev: WinInfo | null) {
    if (!prev) return;
    if (this.d.native.foreground()?.hwnd === prev.hwnd) return;
    await this.focusWindow(prev.hwnd);
  }

  async prepare(c: CaptureResult | null): Promise<Prepared> {
    const t0 = this.now();
    const ms = () => Math.max(0, Math.round(this.now() - t0));
    if (!c) return { method: '–', note: 'aus', extraMs: 0, cap: null };
    if (c.t === 'none') return { method: '–', note: c.why, extraMs: 0, cap: null };
    const cap = c.cap;
    const res = (method: Method, note: string, extra: Partial<Prepared> = {}): Prepared => ({ method, note, extraMs: ms(), cap, ...extra });
    if (cap.alreadyForeground) return { method: '0', note: 'Maus über dem aktiven Fenster', extraMs: 0, cap };
    // did the user click somewhere else during the dictation? Then that choice counts.
    const fgNow = this.d.native.foreground();
    if (!fgNow || !cap.prev || fgNow.hwnd !== cap.prev.hwnd) return { method: '–', note: 'Fokus während des Diktats gewechselt – normal eingefügt', extraMs: 0, cap };

    // plan BEFORE switching: what lies under the mouse?
    let plan = cap.plan ? await withTimeout(cap.plan, 350, this.sleep) : null;
    // two windows of the same app on top of each other: the answer may come from the OTHER window → ignore it
    if (plan && plan.root && plan.root !== cap.win.hwnd) plan = null;
    const editable = plan ? pickEditable(plan.chain) : { t: 'none' as const };
    if (editable.t === 'secure') return res('d', 'Passwortfeld unter der Maus – normal eingefügt');
    let hit: number | null = null;
    try { hit = this.d.native.hitTest(cap.win.hwnd, cap.point); } catch { hit = null; }
    const scale = scaleAt(cap.point, this.d.displays());
    const clickOK = clickAllowed({
      kind: cap.kind, chatSite: cap.chatSite, exe: cap.win.exe, cls: cap.win.cls, hit, chain: plan?.chain ?? null, covered: cap.covered,
      offset: { x: cap.point.x - cap.win.rect.x, y: cap.point.y - cap.win.rect.y }, scale,
    });

    const how = await this.focusWindow(cap.win.hwnd);
    if (!how) {
      await this.restore(cap.prev);
      return res('d', 'Fenster ließ sich nicht nach vorne holen', { toast: this.d.text('toastFocusFailed') });
    }
    // a) text field under the mouse (UI Automation SetFocus – no click needed)
    if (editable.t === 'at' && this.d.uia.dpiAware) {
      let ok = false;
      try { ok = await this.d.uia.setFocusAt(cap.point); } catch { ok = false; }
      if (ok) return res('a', 'Textfeld unter der Maus', { focus: how });
    }
    // c) terminal / chat input: one click at the release point. Before clicking once more: is OUR window on top there,
    //    with nothing above it?
    if (clickOK) {
      const again = this.resolve(cap.point);
      if (again.t === 'target' && again.win.hwnd === cap.win.hwnd && !again.covered && this.d.native.foreground()?.hwnd === cap.win.hwnd) {
        await this.d.native.click(cap.point);
        return res('c', cap.kind === 'terminal' || cap.kind === 'xtermEditor' ? 'Klick ins Terminal' : 'Klick ins Chat-Feld', { focus: how });
      }
    }
    // b) the field the window remembered – but never a password field
    if (this.d.uia.available) {
      let f: UiaElement | null = null;
      try { f = await withTimeout(this.d.uia.focused(), 300, this.sleep); } catch { f = null; }
      if (f?.pwd) {
        await this.restore(cap.prev);
        return res('d', 'Passwortfeld – normal eingefügt', { toast: this.d.text('toastNormal') });
      }
    }
    return res('b', 'zuletzt benutztes Feld im Fenster', { focus: how });
  }

  // MARK: 4. after pasting: Enter?

  /** Presses Enter only when the paste is confirmed and the app is on the Enter list. Returns the log suffix. */
  async autoSend(inserted: string, prep: Prepared): Promise<string> {
    if (!SENDS_AFTER.has(prep.method) || !prep.cap) return 'kein Enter: nicht ins Maus-Ziel eingefügt';
    const cap = prep.cap;
    const expect = cap.win.hwnd;
    const t0 = this.now();
    if (this.d.native.foreground()?.hwnd !== expect) return 'kein Enter: Fenster gewechselt';
    let el: UiaElement | null = null;
    if (this.d.uia.available) { try { el = await withTimeout(this.d.uia.focused(), 400, this.sleep); } catch { el = null; } }
    const d = autoSendRule(cap.kind, cap.chatSite, el?.chain ?? null);
    if (!d.send) return `kein Enter: ${d.why}`;
    // paste confirmed? A readable field must contain the text (wait ≤ 300 ms). Terminals are not read (whole buffer,
    // Claude Code's frame characters, wrapped rows) – there the focus check is enough.
    let ok: boolean | undefined;
    if (el && cap.kind !== 'terminal' && cap.kind !== 'xtermEditor') {
      await this.poll(300, async () => {
        const v = await withTimeout(this.d.uia.focused({ value: true }), 250, this.sleep).catch(() => null);
        ok = pasteConfirmed(inserted, v?.value);
        return ok !== false;
      });
    }
    if (ok === false) return 'kein Enter: Einfügen nicht bestätigt';
    // terminals process Ctrl+V asynchronously (bracketed paste) – give them a moment, otherwise Enter comes too early
    const waited = this.now() - t0;
    if (ok === undefined && waited < 180) await this.sleep(180 - waited);
    if (this.d.native.foreground()?.hwnd !== expect || this.d.hotkeyHeld?.()) return 'kein Enter: Fokus/Taste geändert';
    this.d.markInjecting?.(80);
    this.d.native.pressEnter();
    return 'Enter gesendet';
  }
}
