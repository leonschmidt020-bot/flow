// Audio import: any audio/video file → 16 kHz mono float32.
//   1. WAV            parsed directly (PCM 8/16/24/32, float; any rate/channels → resampled)
//   2. ffmpeg         the user's ffmpeg (setting, PATH, winget/scoop/choco locations) – streams, so hours of audio work
//   3. Chromium       Electron's built-in decoder (mp3, m4a/aac, mp4, ogg/opus, flac, webm) for files up to 400 MB when
//                     no ffmpeg is installed (decodes in one piece → memory-bound, hence the limit)
// Flow does NOT bundle ffmpeg: the common static Windows builds (ffmpeg-static, BtbN "gpl") are GPL-licensed and ~80 MB;
// shipping one would put GPL source-offer obligations on every Flow release and double the installer. Electron's own
// ffmpeg (LGPL, dynamically linked, already in the app) covers the usual formats instead.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

export const AUDIO_EXTS = ['wav', 'mp3', 'm4a', 'aac', 'mp4', 'mov', 'mkv', 'webm', 'ogg', 'opus', 'flac', 'wma', 'aiff', 'aif', 'caf', 'm4v', '3gp', 'amr'];
export const CHROMIUM_MAX_BYTES = 400 * 1024 * 1024;

export const isAudioFile = (f: string) => AUDIO_EXTS.includes(path.extname(f).slice(1).toLowerCase());

export type DecodeProgress = (p: number) => void;
export type ChromiumDecode = (file: string) => Promise<Float32Array>;

export class DecodeError extends Error {
  constructor(message: string, readonly code: 'unsupported' | 'tooLarge' | 'failed' | 'missing') { super(message); }
}

/** tolerant WAV reader: data size 0 / too large (crashed recording) → reads to the end of the file */
export function parseWavLoose(buf: Buffer): { samples: Float32Array; sampleRate: number } {
  if (buf.length < 12 || buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new DecodeError('not a WAV file', 'unsupported');
  let off = 12;
  let fmt: { format: number; channels: number; rate: number; bits: number } | null = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      let format = buf.readUInt16LE(body);
      if (format === 0xfffe && size >= 26) format = buf.readUInt16LE(body + 24); // WAVE_FORMAT_EXTENSIBLE → sub-format
      fmt = { format, channels: buf.readUInt16LE(body + 2), rate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
    } else if (id === 'data' && fmt) {
      const end = size === 0 || body + size > buf.length ? buf.length : body + size;
      const bytes = fmt.bits / 8;
      if (![1, 3].includes(fmt.format) || ![8, 16, 24, 32].includes(fmt.bits) || fmt.channels < 1) throw new DecodeError(`WAV format ${fmt.format}/${fmt.bits} bit`, 'unsupported');
      const frames = Math.floor((end - body) / (bytes * fmt.channels));
      const out = new Float32Array(frames);
      for (let i = 0; i < frames; i++) {
        let acc = 0;
        for (let c = 0; c < fmt.channels; c++) {
          const p = body + (i * fmt.channels + c) * bytes;
          acc += fmt.format === 3 ? (fmt.bits === 64 ? buf.readDoubleLE(p) : buf.readFloatLE(p))
            : fmt.bits === 16 ? buf.readInt16LE(p) / 32768 : fmt.bits === 24 ? buf.readIntLE(p, 3) / 8388608
              : fmt.bits === 32 ? buf.readInt32LE(p) / 2147483648 : (buf.readUInt8(p) - 128) / 128;
        }
        out[i] = acc / fmt.channels;
      }
      return { samples: out, sampleRate: fmt.rate };
    }
    off = body + size + (size % 2);
  }
  throw new DecodeError('WAV without data chunk', 'unsupported');
}

/** resample to `to` Hz: box filter when downsampling (cheap anti-aliasing), linear interpolation */
export function resample(s: Float32Array, from: number, to = 16000): Float32Array {
  if (from === to || s.length === 0) return s;
  const ratio = from / to;
  const n = Math.floor(s.length / ratio);
  const out = new Float32Array(n);
  if (ratio > 1) {
    for (let i = 0; i < n; i++) {
      const a = i * ratio, b = Math.min(s.length, (i + 1) * ratio);
      let sum = 0, cnt = 0;
      for (let j = Math.floor(a); j < b; j++) { sum += s[j]!; cnt++; }
      out[i] = cnt ? sum / cnt : 0;
    }
  } else {
    for (let i = 0; i < n; i++) {
      const x = i * ratio, j = Math.floor(x), f = x - j;
      out[i] = (s[j] ?? 0) * (1 - f) + (s[j + 1] ?? s[j] ?? 0) * f;
    }
  }
  return out;
}

export function readTrack(file: string): Float32Array {
  const w = parseWavLoose(readFileSync(file));
  return resample(w.samples, w.sampleRate, 16000);
}

/** ffmpeg: explicit setting → PATH → common package-manager locations. null if none. */
export function findFfmpeg(explicit: string, env: NodeJS.ProcessEnv = process.env, platform = process.platform, exists: (p: string) => boolean = existsSync): string | null {
  if (explicit && exists(explicit)) return explicit;
  const exe = platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const sep = platform === 'win32' ? ';' : ':';
  const P = platform === 'win32' ? path.win32 : path.posix;
  const dirs = (env.PATH ?? env.Path ?? '').split(sep).filter(Boolean);
  if (platform === 'win32') {
    if (env.LOCALAPPDATA) dirs.push(P.join(env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links'));
    if (env.USERPROFILE) dirs.push(P.join(env.USERPROFILE, 'scoop', 'shims'));
    if (env.ProgramData) dirs.push(P.join(env.ProgramData, 'chocolatey', 'bin'));
  } else {
    dirs.push('/opt/homebrew/bin', '/usr/local/bin', '/usr/bin');
  }
  for (const d of dirs) {
    const f = P.join(d.replace(/^"|"$/g, ''), exe);
    if (exists(f)) return f;
  }
  return null;
}

/** "Duration: 00:01:02.34" from ffmpeg's stderr */
export function parseFfmpegDuration(stderr: string): number | null {
  const m = /Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)/.exec(stderr);
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : null;
}

export function decodeWithFfmpeg(ffmpeg: string, file: string, onProgress?: DecodeProgress, signal?: AbortSignal): Promise<Float32Array> {
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, ['-nostdin', '-hide_banner', '-nostats', '-i', file, '-vn', '-sn', '-dn', '-ac', '1', '-ar', '16000', '-f', 's16le', '-acodec', 'pcm_s16le', 'pipe:1'],
      { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    const chunks: Buffer[] = [];
    let bytes = 0, err = '', dur: number | null = null, last = 0;
    const onAbort = () => p.kill();
    signal?.addEventListener('abort', onAbort, { once: true });
    p.stdout.on('data', (d: Buffer) => {
      chunks.push(d); bytes += d.length;
      if (dur && onProgress && Date.now() - last > 200) { last = Date.now(); onProgress(Math.min(1, bytes / (dur * 32000))); }
    });
    p.stderr.on('data', (d) => { if (err.length < 20000) err += String(d); if (dur === null) dur = parseFfmpegDuration(err); });
    p.on('error', (e) => reject(new DecodeError(`ffmpeg: ${e.message}`, 'failed')));
    p.on('close', (code) => {
      signal?.removeEventListener('abort', onAbort);
      if (signal?.aborted) return reject(new Error('aborted'));
      if (code !== 0) return reject(new DecodeError(`ffmpeg exited ${code}: ${err.split('\n').filter(Boolean).slice(-2).join(' ').slice(0, 300)}`, 'failed'));
      const buf = Buffer.concat(chunks);
      const out = new Float32Array(Math.floor(buf.length / 2));
      for (let i = 0; i < out.length; i++) out[i] = buf.readInt16LE(i * 2) / 32768;
      onProgress?.(1);
      resolve(out);
    });
  });
}

export interface DecodeDeps { ffmpeg: string | null; chromium?: ChromiumDecode; onProgress?: DecodeProgress; signal?: AbortSignal }

export async function decodeFile(file: string, d: DecodeDeps): Promise<{ samples: Float32Array; via: 'wav' | 'ffmpeg' | 'chromium' }> {
  if (!existsSync(file)) throw new DecodeError('file not found', 'missing');
  if (path.extname(file).toLowerCase() === '.wav') {
    try { const s = readTrack(file); d.onProgress?.(1); return { samples: s, via: 'wav' }; } catch (e) { if (!d.ffmpeg && !d.chromium) throw e; }
  }
  if (d.ffmpeg) return { samples: await decodeWithFfmpeg(d.ffmpeg, file, d.onProgress, d.signal), via: 'ffmpeg' };
  if (!d.chromium) throw new DecodeError('no decoder', 'unsupported');
  if (statSync(file).size > CHROMIUM_MAX_BYTES) throw new DecodeError('file too large without ffmpeg', 'tooLarge');
  d.onProgress?.(0.05);
  const s = await d.chromium(file);
  d.onProgress?.(1);
  return { samples: s, via: 'chromium' };
}
