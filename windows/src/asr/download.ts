// Resumable, checksummed downloads + archive extraction. Plain Node (no Electron) so the ASR test can use it.
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, promises as fsp } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';
import { MODELS, VAD, type ArchiveModel, type ModelId } from './models';

export interface Progress { phase: 'download' | 'verify' | 'extract' | 'done'; received: number; total: number; bytesPerSec: number }
export type OnProgress = (p: Progress) => void;

export interface DownloadOptions {
  sha256: string | null;
  size?: number;
  onProgress?: OnProgress;
  signal?: AbortSignal;
  retries?: number;
  /** injectable for tests */
  fetchImpl?: typeof fetch;
}

export async function sha256File(file: string): Promise<string> {
  const h = createHash('sha256');
  await pipeline(createReadStream(file), h);
  return h.digest('hex');
}

/**
 * Downloads `url` to `dest`. Partial data lives in `dest + '.part'` and is resumed with an HTTP Range request.
 * The file only appears at `dest` after size + sha256 check passed.
 */
export async function downloadFile(url: string, dest: string, o: DownloadOptions): Promise<void> {
  const part = dest + '.part';
  const f = o.fetchImpl ?? fetch;
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  const retries = o.retries ?? 4;
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (o.signal?.aborted) throw new Error('aborted');
    try {
      let have = existsSync(part) ? (await fsp.stat(part)).size : 0;
      if (o.size && have > o.size) { await fsp.rm(part, { force: true }); have = 0; }
      if (!(o.size && have === o.size)) {
        const headers: Record<string, string> = {};
        if (have > 0) headers.Range = `bytes=${have}-`;
        const res = await f(url, { headers, redirect: 'follow', signal: o.signal });
        if (res.status === 416) { await fsp.rm(part, { force: true }); throw new Error('range not satisfiable – restarting'); }
        if (!res.ok || !res.body) throw new Error(`HTTP ${res.status} for ${url}`);
        const resumed = res.status === 206;
        if (!resumed) have = 0;
        const len = Number(res.headers.get('content-length') ?? 0);
        const total = o.size ?? (len ? have + len : 0);
        // write chunk by chunk (awaited): whatever arrived before a dropped connection stays on disk for the resume
        const fh = await fsp.open(part, resumed ? 'a' : 'w');
        let received = have;
        let t0 = Date.now();
        let r0 = received;
        let rate = 0;
        try {
          for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
            await fh.write(chunk);
            received += chunk.length;
            const now = Date.now();
            if (now - t0 >= 250) {
              rate = ((received - r0) * 1000) / (now - t0);
              t0 = now; r0 = received;
              o.onProgress?.({ phase: 'download', received, total, bytesPerSec: rate });
            }
          }
        } finally {
          await fh.close();
        }
        o.onProgress?.({ phase: 'download', received, total, bytesPerSec: rate });
      }
      const size = (await fsp.stat(part)).size;
      if (o.size && size !== o.size) throw new Error(`incomplete download (${size}/${o.size} bytes)`);
      if (o.sha256) {
        o.onProgress?.({ phase: 'verify', received: size, total: size, bytesPerSec: 0 });
        const got = await sha256File(part);
        if (got !== o.sha256) {
          await fsp.rm(part, { force: true });
          throw new ChecksumError(`checksum mismatch for ${path.basename(dest)}: ${got}`);
        }
      }
      await fsp.rename(part, dest);
      return;
    } catch (e) {
      lastErr = e;
      if (o.signal?.aborted) throw e;
      if (attempt < retries) await new Promise((r) => setTimeout(r, Math.min(15000, 1000 * 2 ** attempt)));
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

export class ChecksumError extends Error {}

/** `tar -xjf` – uses Windows' built-in bsdtar (System32\tar.exe, Windows 10 1803+) or the system tar elsewhere */
export function tarBinary(): string {
  if (process.platform === 'win32') {
    const sys = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe');
    return sys;
  }
  return 'tar';
}

export function extractTarBz2(archive: string, destDir: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(tarBinary(), ['-xjf', archive, '-C', destDir], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
    let err = '';
    p.stderr.on('data', (d) => { err += String(d); });
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`tar exited ${code}: ${err.slice(0, 400)}`))));
  });
}

export const modelDir = (root: string, m: ArchiveModel) => path.join(root, m.dir);

export function modelFiles(root: string, id: ModelId): Record<string, string> {
  const m = MODELS[id];
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(m.files)) out[k] = path.join(root, m.dir, v);
  return out;
}

export function isModelReady(root: string, id: ModelId): boolean {
  return Object.values(modelFiles(root, id)).every((f) => existsSync(f)) && existsSync(path.join(root, m_marker(id)));
}
const m_marker = (id: ModelId) => path.join(MODELS[id].dir, '.flow-ok');

export const vadPath = (root: string) => path.join(root, VAD.file);

/** Make sure model + VAD exist under `root`; downloads/extracts what's missing. Idempotent. */
export async function ensureModel(root: string, id: ModelId, onProgress?: OnProgress, signal?: AbortSignal): Promise<void> {
  const m = MODELS[id];
  await fsp.mkdir(root, { recursive: true });
  if (!existsSync(vadPath(root))) {
    await downloadFile(VAD.url, vadPath(root), { sha256: VAD.sha256, size: VAD.size, signal });
  }
  if (isModelReady(root, id)) { onProgress?.({ phase: 'done', received: m.size, total: m.size, bytesPerSec: 0 }); return; }
  const dl = path.join(root, 'downloads');
  const archive = path.join(dl, m.archive);
  if (!existsSync(archive)) await downloadFile(m.url, archive, { sha256: m.sha256, size: m.size, onProgress, signal });
  onProgress?.({ phase: 'extract', received: m.size, total: m.size, bytesPerSec: 0 });
  const tmp = path.join(root, `.extract-${id}-${process.pid}`);
  await fsp.rm(tmp, { recursive: true, force: true });
  await fsp.mkdir(tmp, { recursive: true });
  try {
    await extractTarBz2(archive, tmp);
    const src = path.join(tmp, m.dir);
    for (const f of Object.values(m.files)) {
      if (!existsSync(path.join(src, f))) throw new Error(`archive is missing ${f}`);
    }
    await fsp.rm(path.join(src, 'test_wavs'), { recursive: true, force: true });
    const final = modelDir(root, m);
    await fsp.rm(final, { recursive: true, force: true });
    await fsp.rename(src, final);
    await fsp.writeFile(path.join(final, '.flow-ok'), JSON.stringify({ id, sha256: m.sha256, at: new Date().toISOString() }));
  } finally {
    await fsp.rm(tmp, { recursive: true, force: true });
  }
  // archive no longer needed
  await fsp.rm(archive, { force: true });
  onProgress?.({ phase: 'done', received: m.size, total: m.size, bytesPerSec: 0 });
}
