// Atomic file writes: temp file + fsync + rename, with a few retries (Windows: a virus scanner or the
// indexer may briefly hold the target open -> EPERM/EBUSY on rename).
import * as fs from 'node:fs';
import * as path from 'node:path';

function sleepSync(ms: number): void {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  } catch {
    const end = Date.now() + ms;
    while (Date.now() < end) { /* spin */ }
  }
}

export function writeFileAtomic(file: string, data: Buffer | string, mode = 0o600): void {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${file}.tmp-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const fd = fs.openSync(tmp, 'w', mode);
  try {
    fs.writeSync(fd, typeof data === 'string' ? Buffer.from(data, 'utf8') : data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  let lastErr: unknown;
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      fs.renameSync(tmp, file);
      return;
    } catch (e) {
      lastErr = e;
      const code = (e as NodeJS.ErrnoException).code;
      if (code !== 'EPERM' && code !== 'EBUSY' && code !== 'EACCES') break;
      sleepSync(15 * (attempt + 1));
    }
  }
  try { fs.unlinkSync(tmp); } catch { /* already gone */ }
  throw lastErr;
}

export function readFileOrNull(file: string): Buffer | null {
  try {
    return fs.readFileSync(file);
  } catch {
    return null;
  }
}

/** Remove a file or directory inside `root` only (guards against path tricks in stored names). */
export function removeInside(root: string, rel: string): void {
  const abs = path.resolve(root, rel);
  const r = path.resolve(root) + path.sep;
  if (!abs.startsWith(r)) return;
  try { fs.rmSync(abs, { recursive: true, force: true }); } catch { /* ignore */ }
}

export function fileSize(p: string): number {
  try {
    return fs.statSync(p).size;
  } catch {
    return 0;
  }
}
