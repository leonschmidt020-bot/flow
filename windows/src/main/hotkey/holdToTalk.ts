// Hold-to-talk state machine (pure; timers + clock injected so it is unit-testable).
//  • hold the combo → onStart('hold'); release → onStop()   (a very short press = tap → onCancel())
//  • double-tap (two taps within doubleTapMs) → hands-free: recording continues until the combo is pressed again
//  • another key pressed while holding (e.g. Ctrl+C) → it was a shortcut → onCancel()
//  • Esc cancels hands-free / hold recording
import { K, type Combo } from './keycodes';

export type Mode = 'hold' | 'handsfree';
export interface HoldCallbacks {
  onStart(mode: Mode): void;
  onStop(): void;
  onCancel(reason: 'tap' | 'chord' | 'escape'): void;
  /** hold recording was converted to hands-free */
  onHandsFree?(): void;
  /** combo became fully pressed (used e.g. to suppress the Start menu for Win combos) */
  onComboDown?(): void;
}
export interface HoldOptions { tapMs?: number; doubleTapMs?: number; doubleTap?: boolean; now?: () => number }

type State = 'idle' | 'holding' | 'handsfree' | 'handsfreeStopping';

export class HoldToTalk {
  private pressed = new Set<number>();
  private state: State = 'idle';
  private pressAt = 0;
  private lastTapAt = -Infinity;
  private enabled = true;
  private readonly tapMs: number;
  private readonly doubleTapMs: number;
  private readonly now: () => number;
  doubleTap: boolean;

  constructor(private combo: Combo, private cb: HoldCallbacks, o: HoldOptions = {}) {
    this.tapMs = o.tapMs ?? 250;
    this.doubleTapMs = o.doubleTapMs ?? 400;
    this.doubleTap = o.doubleTap ?? true;
    this.now = o.now ?? (() => Date.now());
  }

  get current(): State { return this.state; }
  get keysDown(): ReadonlySet<number> { return this.pressed; }
  setCombo(c: Combo) { this.combo = c; this.reset(); }
  setEnabled(v: boolean) { this.enabled = v; if (!v) this.reset(); }
  reset() { this.pressed.clear(); this.state = 'idle'; this.lastTapAt = -Infinity; }

  private isComboKey(code: number) { return this.combo.some((g) => g.includes(code)); }
  private comboDown() { return this.combo.every((g) => g.some((k) => this.pressed.has(k))); }

  keyDown(code: number): void {
    if (!code) return; // injected / unknown keys
    const wasDown = this.pressed.has(code);
    this.pressed.add(code);
    if (!this.enabled || wasDown) return; // auto-repeat
    if (code === K.Escape && (this.state === 'handsfree' || this.state === 'holding')) {
      this.state = 'idle';
      this.cb.onCancel('escape');
      return;
    }
    if (!this.isComboKey(code)) {
      if (this.state === 'holding' && this.comboDown()) { this.state = 'idle'; this.lastTapAt = -Infinity; this.cb.onCancel('chord'); }
      return;
    }
    if (!this.comboDown()) return;
    this.cb.onComboDown?.();
    if (this.state === 'idle') {
      // other non-combo keys already held → it's a shortcut like Ctrl+Shift+…, not dictation
      if ([...this.pressed].some((k) => !this.isComboKey(k))) return;
      this.state = 'holding';
      this.pressAt = this.now();
      this.cb.onStart('hold');
    } else if (this.state === 'handsfree') {
      this.state = 'handsfreeStopping';
      this.cb.onStop();
    }
  }

  keyUp(code: number): void {
    if (!code) return;
    const was = this.comboDown();
    this.pressed.delete(code);
    if (!this.enabled) return;
    if (this.state === 'handsfreeStopping') { if (!this.comboDown() && this.combo.every((g) => g.every((k) => !this.pressed.has(k)))) this.state = 'idle'; return; }
    if (this.state !== 'holding' || !was || !this.isComboKey(code)) return;
    const held = this.now() - this.pressAt;
    if (held < this.tapMs) {
      const t = this.now();
      if (this.doubleTap && t - this.lastTapAt <= this.doubleTapMs) {
        this.lastTapAt = -Infinity;
        this.state = 'handsfree';
        this.cb.onHandsFree?.();
      } else {
        this.lastTapAt = t;
        this.state = 'idle';
        this.cb.onCancel('tap');
      }
      return;
    }
    this.state = 'idle';
    this.lastTapAt = -Infinity;
    this.cb.onStop();
  }

  /** external stop/cancel (pill buttons, errors) */
  forceIdle() { this.state = 'idle'; }
}
