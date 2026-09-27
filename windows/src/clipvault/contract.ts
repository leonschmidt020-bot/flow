// Owned by WIN-FLOW. Contract between Flow (Windows) and the ClipVault module.
// See INTERFACE.md. Do not import 'electron' at runtime here (types only).
import type { App } from 'electron';

export type ToastKind = 'info' | 'success' | 'error';

export interface FlowClipboardWrite {
  text: string;
  /** insert = transient write before Ctrl+V, restore = old clipboard put back, keep = dictation stays (user setting) */
  phase: 'insert' | 'restore' | 'keep';
}

export interface ClipVaultContext {
  app: App;
  /** app.getPath('userData'), e.g. %APPDATA%/Flow. Store your data in <userDataDir>/clipvault/. */
  userDataDir: string;
  /** Electron accelerator, e.g. "Control+Shift+V". Returns unregister fn, or null if disabled/taken. */
  registerHotkey(accelerator: string, handler: () => void): (() => void) | null;
  /** Show a toast in the Flow pill. */
  onToast(message: string, kind?: ToastKind): void;
  locale: 'de' | 'en';
  /** true while Flow inserts a dictation via the clipboard – ignore clipboard changes then. */
  isFlowWritingClipboard(): boolean;
  /** Push notification of Flow's own clipboard writes. Returns unsubscribe. */
  onFlowClipboardWrite(cb: (w: FlowClipboardWrite) => void): () => void;
  /** Push an event to mounted ClipVault UIs (api.on(channel)). */
  sendToUi(channel: string, payload?: unknown): void;
  log(...args: unknown[]): void;
  isDev: boolean;
  /** Absolute path to dist/clipvault/assets */
  assetsDir: string;
}

export interface ClipVaultHandle {
  openPanel(): void;
  dispose(): void | Promise<void>;
}

export type InitClipVault = (ctx: ClipVaultContext) => ClipVaultHandle | Promise<ClipVaultHandle>;

export interface ClipVaultUiApi {
  invoke<T = unknown>(name: string, ...args: unknown[]): Promise<T>;
  on(name: string, cb: (payload: unknown) => void): () => void;
  locale: 'de' | 'en';
}

export type MountClipVault = (root: ShadowRoot, api: ClipVaultUiApi) => () => void;
