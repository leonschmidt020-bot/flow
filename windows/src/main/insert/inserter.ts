// Insert text at the cursor: save clipboard → write text → Ctrl+V → restore after ~300 ms.
// Platform access is behind two tiny ports so the sequence is unit-tested with mocks.

export interface ClipSnapshot { formats: Record<string, unknown>; text: string }
/** async, because Electron ≥ 40 exposes the W3C-style async clipboard */
export interface ClipboardPort {
  snapshot(): Promise<ClipSnapshot> | ClipSnapshot;
  restore(s: ClipSnapshot): Promise<void> | void;
  writeText(t: string): Promise<void> | void;
  readText(): Promise<string> | string;
}
export interface KeySender {
  /** Ctrl+V into the foreground window */
  paste(): Promise<void> | void;
}
export type InsertPhase = 'insert' | 'restore' | 'keep';

export interface InsertOptions {
  clipboard: ClipboardPort;
  keys: KeySender;
  keepInClipboard: boolean;
  restoreDelayMs?: number;
  settleMs?: number;
  sleep?: (ms: number) => Promise<void>;
  onPhase?: (p: InsertPhase, text: string) => void;
  setWriting?: (v: boolean) => void;
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function insertText(text: string, o: InsertOptions): Promise<{ restored: boolean }> {
  if (!text) return { restored: false };
  const sleep = o.sleep ?? defaultSleep;
  o.setWriting?.(true);
  try {
    const snap = o.keepInClipboard ? null : await o.clipboard.snapshot();
    await o.clipboard.writeText(text);
    o.onPhase?.(o.keepInClipboard ? 'keep' : 'insert', text);
    await sleep(o.settleMs ?? 40);
    await o.keys.paste();
    if (!snap) return { restored: false };
    await sleep(o.restoreDelayMs ?? 300);
    // user (or another app) copied something in the meantime → leave it alone
    if ((await o.clipboard.readText()) !== text) return { restored: false };
    await o.clipboard.restore(snap);
    o.onPhase?.('restore', snap.text);
    return { restored: true };
  } finally {
    o.setWriting?.(false);
  }
}
