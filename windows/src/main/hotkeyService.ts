// Global keyboard hook (uiohook-napi) → HoldToTalk state machine. Disabled with --no-hotkey.
import { HoldToTalk, type HoldCallbacks } from './hotkey/holdToTalk';
import { comboFor, comboUsesWin, K } from './hotkey/keycodes';
import type { HotkeyChoice } from '../shared/settings';
import { log } from './log';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type UIO = any;

export class HotkeyService {
  readonly machine: HoldToTalk;
  private hook: UIO = null;
  private started = false;
  /** while Flow injects keys (Ctrl+V), hook events are ignored */
  private injectingUntil = 0;
  onComboDown: () => void = () => {};
  /** Esc while no dictation runs (Agent-Prompt card) */
  onEscape: () => void = () => {};

  constructor(private choice: HotkeyChoice, cb: HoldCallbacks, doubleTap: boolean) {
    this.machine = new HoldToTalk(comboFor(choice), { ...cb, onComboDown: () => this.onComboDown() }, { doubleTap });
  }

  get usesWin() { return comboUsesWin(comboFor(this.choice)); }

  start(): boolean {
    if (this.started) return true;
    try {

      const { uIOhook } = require('uiohook-napi');
      this.hook = uIOhook;
      uIOhook.on('keydown', (e: { keycode: number }) => {
        if (Date.now() < this.injectingUntil) return;
        const idle = this.machine.current === 'idle';
        const repeat = this.machine.keysDown.has(e.keycode);
        this.machine.keyDown(e.keycode);
        if (e.keycode === K.Escape && idle && !repeat) { try { this.onEscape(); } catch (err) { log('hotkey: escape', err); } }
      });
      // key-ups always count (keeps the pressed set honest); injected key-downs are ignored
      uIOhook.on('keyup', (e: { keycode: number }) => this.machine.keyUp(e.keycode));
      uIOhook.start();
      this.started = true;
      log('hotkey: hook started', this.choice);
      return true;
    } catch (e) {
      log('hotkey: hook failed', e);
      return false;
    }
  }

  setChoice(choice: HotkeyChoice, doubleTap: boolean) {
    this.choice = choice;
    this.machine.setCombo(comboFor(choice));
    this.machine.doubleTap = doubleTap;
  }

  /** mark a window in which our own SendInput events come back through the hook */
  injecting(ms: number) { this.injectingUntil = Date.now() + ms; }

  /** is a key of the combo held right now (per our hook)? */
  comboHeld(): boolean { return comboFor(this.choice).flat().some((k) => this.machine.keysDown.has(k)); }

  /** resolves once none of the combo keys is held (max `timeout` ms) */
  async waitReleased(timeout = 1200): Promise<void> {
    const t0 = Date.now();
    const combo = comboFor(this.choice).flat();
    while (Date.now() - t0 < timeout && combo.some((k) => this.machine.keysDown.has(k))) await new Promise((r) => setTimeout(r, 15));
  }

  stop() {
    if (!this.started) return;
    try { this.hook?.stop(); } catch { /* */ }
    this.started = false;
  }
}
