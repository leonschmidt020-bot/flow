// Minimal WAV reader (PCM16 / float32, any channel count → mono float32).
import { readFileSync } from 'node:fs';

export function readWav(file: string): { samples: Float32Array; sampleRate: number } {
  return parseWav(readFileSync(file));
}

export function parseWav(buf: Buffer): { samples: Float32Array; sampleRate: number } {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new Error('not a WAV file');
  let off = 12;
  let fmt: { format: number; channels: number; rate: number; bits: number } | null = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      fmt = { format: buf.readUInt16LE(body), channels: buf.readUInt16LE(body + 2), rate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
    } else if (id === 'data' && fmt) {
      const end = Math.min(buf.length, body + size);
      const bytes = fmt.bits / 8;
      const frames = Math.floor((end - body) / (bytes * fmt.channels));
      const out = new Float32Array(frames);
      for (let i = 0; i < frames; i++) {
        let acc = 0;
        for (let c = 0; c < fmt.channels; c++) {
          const p = body + (i * fmt.channels + c) * bytes;
          acc += fmt.format === 3 ? buf.readFloatLE(p) : fmt.bits === 16 ? buf.readInt16LE(p) / 32768 : buf.readInt32LE(p) / 2147483648;
        }
        out[i] = acc / fmt.channels;
      }
      return { samples: out, sampleRate: fmt.rate };
    }
    off = body + size + (size % 2);
  }
  throw new Error('WAV without data chunk');
}

export function encodeWav16(samples: Float32Array, sampleRate: number): Buffer {
  const buf = Buffer.alloc(44 + samples.length * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + samples.length * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24); buf.writeUInt32LE(sampleRate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(samples.length * 2, 40);
  for (let i = 0; i < samples.length; i++) buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(samples[i]! * 32767))), 44 + i * 2);
  return buf;
}
