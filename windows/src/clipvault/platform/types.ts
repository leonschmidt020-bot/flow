import type { ClipboardFlags } from '../core/sensitive';
import type { IndexCodec } from '../core/store';

/** native window handle (HWND as integer) */
export type WindowRef = number | bigint;

export interface Platform {
  name: 'win32' | 'generic';
  /** cheap clipboard change counter (Windows: GetClipboardSequenceNumber), null elsewhere */
  clipboardSequence(): number | null;
  /** exclusion markers + owner process (see core/sensitive.ts) */
  clipboardFlags(): ClipboardFlags;
  /** CF_HDROP file list; null = not supported here (caller falls back) */
  readFileList(): string[] | null;
  /** put files on the clipboard as CF_HDROP (Explorer/Mail/WhatsApp can paste them) */
  writeFileList(paths: string[], owner: WindowRef | null): boolean;
  /** window that had the focus before the panel opened */
  foregroundWindow(): WindowRef | null;
  /** give the focus back */
  restoreForeground(w: WindowRef): boolean;
  /** synthesize Ctrl+V into the focused window (SendInput) */
  sendPaste(): boolean;
  /** DPAPI (CurrentUser) for data at rest; null where unavailable */
  dpapi: IndexCodec | null;
}

export const genericPlatform: Platform = {
  name: 'generic',
  clipboardSequence: () => null,
  clipboardFlags: () => ({}),
  readFileList: () => null,
  writeFileList: () => false,
  foregroundWindow: () => null,
  restoreForeground: () => false,
  sendPaste: () => false,
  dpapi: null,
};
