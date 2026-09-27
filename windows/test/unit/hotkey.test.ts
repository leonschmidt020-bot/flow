import { describe, expect, it, beforeEach } from 'vitest';
import { HoldToTalk } from '../../src/main/hotkey/holdToTalk';
import { comboFor, K } from '../../src/main/hotkey/keycodes';

let now = 0;
let log: string[] = [];
const cb = {
  onStart: (m: string) => log.push('start:' + m),
  onStop: () => log.push('stop'),
  onCancel: (r: string) => log.push('cancel:' + r),
  onHandsFree: () => log.push('handsfree'),
};
beforeEach(() => { now = 1000; log = []; });
const mk = (h: Parameters<typeof comboFor>[0] = 'RightCtrl', doubleTap = true) => new HoldToTalk(comboFor(h), cb, { now: () => now, doubleTap });

describe('hold to talk', () => {
  it('hold → start, release → stop', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 800; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'stop']);
  });
  it('auto-repeat keydowns are ignored', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); h.keyDown(K.CtrlRight); h.keyDown(K.CtrlRight); now += 500; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'stop']);
  });
  it('short tap cancels', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'cancel:tap']);
  });
  it('double tap → hands-free, next press stops', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight);
    now += 150; h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'cancel:tap', 'start:hold', 'handsfree']);
    now += 5000; h.keyDown(K.CtrlRight); now += 100; h.keyUp(K.CtrlRight);
    expect(log.slice(-1)).toEqual(['stop']);
    expect(h.current).toBe('idle');
  });
  it('double tap disabled → two cancels', () => {
    const h = mk('RightCtrl', false);
    h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight); now += 100; h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'cancel:tap', 'start:hold', 'cancel:tap']);
  });
  it('slow second tap is not a double tap', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight); now += 900; h.keyDown(K.CtrlRight); now += 80; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'cancel:tap', 'start:hold', 'cancel:tap']);
  });
  it('Esc cancels hands-free', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 50; h.keyUp(K.CtrlRight); now += 50; h.keyDown(K.CtrlRight); now += 50; h.keyUp(K.CtrlRight);
    h.keyDown(K.Escape);
    expect(log.slice(-1)).toEqual(['cancel:escape']);
  });
  it('other key while holding = shortcut → cancel (Right Ctrl + C)', () => {
    const h = mk();
    h.keyDown(K.CtrlRight); now += 100; h.keyDown(46); now += 300; h.keyUp(46); h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'cancel:chord']);
  });
  it('combo pressed while another key is already held is ignored (Shift + Right Ctrl)', () => {
    const h = mk();
    h.keyDown(K.Shift); h.keyDown(K.CtrlRight); now += 600; h.keyUp(K.CtrlRight);
    expect(log).toEqual([]);
  });
  it('Ctrl+Win: needs both, either Ctrl works, stops on first release', () => {
    const h = mk('CtrlWin');
    h.keyDown(K.Ctrl); expect(log).toEqual([]);
    h.keyDown(K.Meta); now += 700; h.keyUp(K.Meta); h.keyUp(K.Ctrl);
    expect(log).toEqual(['start:hold', 'stop']);
    log = [];
    h.keyDown(K.MetaRight); h.keyDown(K.CtrlRight); now += 700; h.keyUp(K.CtrlRight);
    expect(log).toEqual(['start:hold', 'stop']);
  });
  it('F-keys', () => {
    const h = mk('F9');
    h.keyDown(K.F9); now += 400; h.keyUp(K.F9);
    expect(log).toEqual(['start:hold', 'stop']);
  });
  it('injected/unknown keys (code 0) never interfere', () => {
    const h = mk('CtrlWin');
    h.keyDown(K.Ctrl); h.keyDown(K.Meta); h.keyDown(0); h.keyUp(0); now += 600; h.keyUp(K.Meta);
    expect(log).toEqual(['start:hold', 'stop']);
  });
  it('disabled → nothing', () => {
    const h = mk();
    h.setEnabled(false);
    h.keyDown(K.CtrlRight); now += 600; h.keyUp(K.CtrlRight);
    expect(log).toEqual([]);
  });
});
