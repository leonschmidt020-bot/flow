// AudioWorklet: mono float32 blocks of 100 ms (16 kHz) + RMS level every ~50 ms. Resamples if the context is not 16 kHz.
declare const sampleRate: number;
declare class AudioWorkletProcessor { readonly port: MessagePort; constructor(); }
declare function registerProcessor(name: string, ctor: unknown): void;

const TARGET = 16000;

class FlowCapture extends AudioWorkletProcessor {
  private buf = new Float32Array(1600);
  private n = 0;
  private lvSum = 0;
  private lvN = 0;
  private ratio = sampleRate / TARGET;
  private pos = 0; // fractional read position for resampling
  private prev = 0;

  constructor() {
    super();
    this.port.onmessage = (e: MessageEvent) => {
      if (e.data === 'flush') {
        if (this.n > 0) this.port.postMessage({ type: 'chunk', samples: this.buf.slice(0, this.n) });
        this.n = 0;
        this.port.postMessage({ type: 'flushed' });
      }
    };
  }

  private push(x: number) {
    this.buf[this.n++] = x;
    this.lvSum += x * x;
    this.lvN++;
    if (this.n === this.buf.length) { this.port.postMessage({ type: 'chunk', samples: this.buf.slice() }); this.n = 0; }
    if (this.lvN >= 800) { this.port.postMessage({ type: 'level', rms: Math.sqrt(this.lvSum / this.lvN) }); this.lvSum = 0; this.lvN = 0; }
  }

  process(inputs: Float32Array[][]): boolean {
    const chans = inputs[0];
    if (!chans || chans.length === 0 || !chans[0]) return true;
    const len = chans[0].length;
    for (let i = 0; i < len; i++) {
      let x = 0;
      for (const c of chans) x += c[i] ?? 0;
      x /= chans.length;
      if (this.ratio === 1) { this.push(x); continue; }
      // linear resampling to 16 kHz
      while (this.pos <= 1) { this.push(this.prev + (x - this.prev) * this.pos); this.pos += this.ratio; }
      this.pos -= 1;
      this.prev = x;
    }
    return true;
  }
}

registerProcessor('flow-capture', FlowCapture);
