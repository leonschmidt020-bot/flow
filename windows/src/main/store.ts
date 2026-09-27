// Atomic JSON persistence: write temp + fsync + rename, keep the previous good file as .bak.
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync, copyFileSync, unlinkSync } from 'node:fs';
import path from 'node:path';

export function writeJsonAtomic(file: string, data: unknown): void {
  mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  const body = JSON.stringify(data, null, 1);
  const fd = openSync(tmp, 'w', 0o600);
  try {
    writeSync(fd, body);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  // current file parses → it becomes the last-good backup
  if (existsSync(file)) {
    try { JSON.parse(readFileSync(file, 'utf8')); copyFileSync(file, file + '.bak'); } catch { /* broken current file: keep old .bak */ }
  }
  renameSync(tmp, file);
}

export interface LoadResult<T> { value: T; source: 'file' | 'backup' | 'default' }

/** Load JSON; on missing/corrupt file fall back to .bak, then to `fallback()`. */
export function readJsonSafe<T>(file: string, fallback: () => T): LoadResult<T> {
  for (const [f, source] of [[file, 'file'], [file + '.bak', 'backup']] as const) {
    if (!existsSync(f)) continue;
    try {
      return { value: JSON.parse(readFileSync(f, 'utf8')) as T, source };
    } catch { /* try next */ }
  }
  return { value: fallback(), source: 'default' };
}

/** Debounced atomic saver */
export class JsonFile<T> {
  private timer: NodeJS.Timeout | null = null;
  private pending: T | null = null;
  constructor(readonly file: string, private delayMs = 150) {}
  load(fallback: () => T): LoadResult<T> { return readJsonSafe(this.file, fallback); }
  save(v: T): void {
    this.pending = v;
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), this.delayMs);
  }
  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    if (this.pending === null) return;
    const v = this.pending;
    this.pending = null;
    writeJsonAtomic(this.file, v);
  }
  remove(): void { for (const f of [this.file, this.file + '.bak']) if (existsSync(f)) unlinkSync(f); }
}
