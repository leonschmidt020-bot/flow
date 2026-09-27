// Clipboard watcher – platform independent logic. The real clipboard is behind `ClipboardAdapter`
// (electron/clipboardAdapter.ts); tests inject a fake one. NEVER touch the real clipboard in tests.
//
// Poll every 250 ms. Cheap check first:
//   Windows: user32 GetClipboardSequenceNumber (koffi) – one syscall, no clipboard open.
//   elsewhere: a fingerprint of formats + text (+ image size), see adapter.fingerprint().
import { flagsReason, textReason, DEFAULT_SENSITIVE, type ClipboardFlags, type SensitiveOptions, type SkipReason } from './sensitive';
import type { NewImage, Store, FineLoader } from './store';
import type { ClipItem } from './types';

type MaybeP<T> = T | Promise<T>;

/** Electron >= 44 has an async clipboard API, so every read may be a promise. */
export interface ClipboardAdapter {
  /** change counter, or null if the platform has none (must be cheap + synchronous) */
  sequence(): number | null;
  /** used when sequence() is null: must change whenever the content changes (cheap!) */
  fingerprint(): MaybeP<string>;
  flags(): MaybeP<ClipboardFlags>;
  readFiles(): MaybeP<string[]>;
  readText(): MaybeP<string>;
  hasImage(): MaybeP<boolean>;
  readImage(): MaybeP<NewImage | null>;
  /** optional "source" label (e.g. an AI app) */
  sourceLabel?(): string | null;
}

export interface WatcherOptions {
  intervalMs?: number;
  sensitive?: () => SensitiveOptions;
  /** true while Flow writes the clipboard itself (dictation insert/restore) */
  isSuppressed?: () => boolean;
  loadFine?: FineLoader | null;
  log?: (...a: unknown[]) => void;
  onCaptured?: (item: ClipItem, isNew: boolean) => void;
  onSkipped?: (reason: SkipReason) => void;
  setInterval?: (fn: () => void, ms: number) => unknown;
  clearInterval?: (h: unknown) => void;
}

export type TickResult = 'unchanged' | 'suppressed' | 'paused' | 'skipped' | 'captured' | 'empty' | 'error';

export class ClipboardWatcher {
  private last: string | null = null;
  private timer: unknown = null;
  private paused = false;
  private busy = false;
  readonly intervalMs: number;

  constructor(private adapter: ClipboardAdapter, private store: Store, private opts: WatcherOptions = {}) {
    this.intervalMs = opts.intervalMs ?? 250;
  }

  private async marker(): Promise<string> {
    const s = this.adapter.sequence();
    return s !== null ? `seq:${s}` : `fp:${await this.adapter.fingerprint()}`;
  }

  /** Remember the current clipboard as "seen" (start-up, and after ClipVault/Flow wrote it). */
  async skipCurrent(): Promise<void> {
    try { this.last = await this.marker(); } catch { /* adapter failure: next tick */ }
  }

  /** starts polling; resolves once the current clipboard content is marked as "already there" */
  async start(): Promise<void> {
    if (this.timer) return;
    const si = this.opts.setInterval ?? ((fn, ms) => setInterval(fn, ms));
    this.timer = si(() => void this.tick(), this.intervalMs);
    await this.skipCurrent(); // what was on the clipboard before start is not new
  }

  stop(): void {
    if (!this.timer) return;
    const ci = this.opts.clearInterval ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>));
    ci(this.timer);
    this.timer = null;
  }

  async pause(p: boolean): Promise<void> {
    this.paused = p;
    if (!p) await this.skipCurrent();
  }
  get isPaused() { return this.paused; }

  /** One poll. Returns what happened (for tests / logs). */
  async tick(): Promise<TickResult> {
    if (this.busy) return 'unchanged';
    this.busy = true;
    try {
      let m: string;
      try { m = await this.marker(); } catch { return 'error'; }
      if (m === this.last) return 'unchanged';
      this.last = m;
      if (this.paused) return 'paused';
      if (this.opts.isSuppressed?.()) return 'suppressed';
      return await this.capture();
    } catch (e) {
      this.opts.log?.('[clipvault] capture failed', (e as Error)?.message ?? e);
      return 'error';
    } finally {
      this.busy = false;
    }
  }

  private skip(reason: SkipReason): 'skipped' {
    this.opts.log?.(`[clipvault] not stored (${reason})`); // never log the content itself
    this.opts.onSkipped?.(reason);
    return 'skipped';
  }

  private async capture(): Promise<TickResult> {
    const sens = this.opts.sensitive?.() ?? DEFAULT_SENSITIVE;
    const fr = flagsReason(await this.adapter.flags(), sens);
    if (fr) return this.skip(fr);
    const source = this.adapter.sourceLabel?.() ?? null;

    const files = await this.adapter.readFiles();
    if (files.length) {
      const r = this.store.addFiles(files, source);
      if (r) { this.opts.onCaptured?.(r.item, r.isNew); return 'captured'; }
    }
    const text = await this.adapter.readText();
    if (text && text.trim()) {
      const tr = textReason(text, sens);
      if (tr) return this.skip(tr);
      const r = this.store.addText(text, source);
      this.opts.onCaptured?.(r.item, r.isNew);
      return 'captured';
    }
    if (await this.adapter.hasImage()) {
      const img = await this.adapter.readImage();
      if (img && img.png.length) {
        const r = this.store.addImage(img, source, null, this.opts.loadFine ?? null);
        this.opts.onCaptured?.(r.item, r.isNew);
        return 'captured';
      }
    }
    return 'empty';
  }
}
