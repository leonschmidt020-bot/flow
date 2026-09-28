// Streaming 16-bit mono WAV writer (half the size of float). The header is written up front with size 0 and patched
// on close; `pad(to)` fills silence so both tracks stay time-aligned (WavWriter.swift port).
import { closeSync, fsyncSync, openSync, writeSync } from 'node:fs';

export class WavWriter {
  private fd: number | null;
  framesWritten = 0;
  constructor(readonly file: string, readonly sampleRate = 16000) {
    this.fd = openSync(file, 'w', 0o600);
    writeSync(this.fd, header(0, sampleRate));
  }

  write(s: Float32Array) {
    if (this.fd === null || s.length === 0) return;
    const b = Buffer.alloc(s.length * 2);
    for (let i = 0; i < s.length; i++) b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(s[i]! * 32767))), i * 2);
    writeSync(this.fd, b);
    this.framesWritten += s.length;
  }

  /** silence up to `frames` (max 1 h in one go) */
  pad(frames: number) {
    const missing = frames - this.framesWritten;
    if (this.fd === null || missing <= 0 || missing > this.sampleRate * 3600) return;
    const b = Buffer.alloc(missing * 2);
    writeSync(this.fd, b);
    this.framesWritten += missing;
  }

  close() {
    if (this.fd === null) return;
    writeSync(this.fd, header(this.framesWritten, this.sampleRate), 0, 44, 0);
    try { fsyncSync(this.fd); } catch { /* */ }
    closeSync(this.fd);
    this.fd = null;
  }
}

function header(frames: number, sr: number): Buffer {
  const buf = Buffer.alloc(44);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + frames * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sr, 24); buf.writeUInt32LE(sr * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(frames * 2, 40);
  return buf;
}
