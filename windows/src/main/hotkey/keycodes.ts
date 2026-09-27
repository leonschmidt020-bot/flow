// libuiohook virtual key codes (as used by uiohook-napi's UiohookKey) – duplicated here so the
// pure hotkey logic can be tested without the native module.
export const K = {
  Escape: 1, Ctrl: 29, CtrlRight: 3613, Shift: 42, ShiftRight: 54, Alt: 56, AltRight: 3640, Meta: 3675, MetaRight: 3676,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68, F11: 87, F12: 88, V: 47,
} as const;

import type { HotkeyChoice } from '../../shared/settings';

/** A combo is a list of groups; each group is satisfied by any of its keys. */
export type Combo = number[][];

export function comboFor(h: HotkeyChoice): Combo {
  switch (h) {
    case 'RightCtrl': return [[K.CtrlRight]];
    case 'CtrlWin': return [[K.Ctrl, K.CtrlRight], [K.Meta, K.MetaRight]];
    case 'RightAlt': return [[K.AltRight]];
    default: return [[K[h]]];
  }
}

export const comboUsesWin = (c: Combo) => c.some((g) => g.includes(K.Meta) || g.includes(K.MetaRight));
