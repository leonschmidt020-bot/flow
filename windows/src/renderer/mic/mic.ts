// Hidden capture page. getUserMedia → AudioWorklet → main (IPC).
//
// 11/2026 (slow first words on Windows laptops): opening the mic cold costs 300–1000 ms (getUserMedia + a new
// AudioContext + loading the worklet) – everything said in that time was lost. Now, like the Mac:
//  • the AudioContext + worklet are created once and kept (suspended while no mic is open),
//  • after a dictation the mic stays open WARM_MS, so the next press starts instantly,
//  • while warm, the last PREROLL samples (0.4 s) are kept and handed over at the next press,
//  • the page reports when audio really flows (`flowing`) – the pill only shows „listening“ from then on.
interface MicApi {
  onStart(cb: (o: { deviceId: string }) => void): void;
  onMonitor(cb: (o: { deviceId: string }) => void): void;
  onStop(cb: () => void): void;
  chunk(s: Float32Array): void;
  level(rms: number): void;
  started(info: unknown): void;
  stopped(): void;
  error(e: { name: string; message: string }): void;
}
const api = (window as unknown as { flowMic: MicApi }).flowMic;

/** keep the mic open this long after the last dictation (the taskbar mic icon goes away afterwards) */
const WARM_MS = 60_000;
/** 0.4 s at 16 kHz taken over from just before the key press (only while warm) */
const PREROLL = 6400;

let ctx: AudioContext | null = null;
let ctxReady: Promise<AudioContext> | null = null;
let stream: MediaStream | null = null;
let streamDevice = '';
let src: MediaStreamAudioSourceNode | null = null;
let node: AudioWorkletNode | null = null;
let record = false;
let monitor = false;
let session = 0;
let ring: Float32Array[] = [];
let ringLen = 0;
let warmTimer: number | undefined;
let finishTimer: number | undefined;
let flushing = false;

function context(): Promise<AudioContext> {
  if (ctx && ctxReady && ctx.state !== 'closed') return ctxReady;
  const c = new AudioContext({ sampleRate: 16000, latencyHint: 'interactive' });
  ctx = c;
  ctxReady = c.audioWorklet.addModule('worklet.js').then(() => {
    node = new AudioWorkletNode(c, 'flow-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1 });
    node.port.onmessage = onWorklet;
    const mute = c.createGain();
    mute.gain.value = 0;
    node.connect(mute).connect(c.destination);
    return c;
  });
  ctxReady.catch(() => { ctx = null; ctxReady = null; });
  return ctxReady;
}

function onWorklet(e: MessageEvent) {
  const d = e.data as { type: string; samples?: Float32Array; rms?: number };
  if (d.type === 'chunk' && d.samples) {
    if (record) api.chunk(d.samples);
    else if (stream) {
      // warm: keep the last 0.4 s for the next press
      ring.push(d.samples); ringLen += d.samples.length;
      while (ring.length > 1 && ringLen - ring[0]!.length >= PREROLL) ringLen -= ring.shift()!.length;
    }
  } else if (d.type === 'level') {
    if (record || monitor) api.level(d.rms ?? 0);
  } else if (d.type === 'flushed') finish();
}

const constraints = (id: string): MediaStreamConstraints => ({
  // no browser noise suppression / AGC: both smear the start of words and hurt recognition – the level is
  // normalised before the ASR instead (src/asr/engine.ts › normalise)
  audio: { deviceId: id ? { exact: id } : undefined, channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
  video: false,
});

function streamLive() { return !!stream && stream.getAudioTracks().some((t) => t.readyState === 'live'); }

async function open(deviceId: string, rec: boolean) {
  const my = ++session;
  if (warmTimer) { clearTimeout(warmTimer); warmTimer = undefined; }
  if (finishTimer) { clearTimeout(finishTimer); finishTimer = undefined; }
  flushing = false;
  const t0 = performance.now();
  try {
    const c = await context();
    if (my !== session) return;
    let warm = streamLive() && streamDevice === deviceId;
    if (!warm) {
      closeStream();
      let s: MediaStream;
      try {
        s = await navigator.mediaDevices.getUserMedia(constraints(deviceId));
      } catch (e) {
        if (!deviceId) throw e;
        s = await navigator.mediaDevices.getUserMedia(constraints('')); // device gone → default
      }
      if (my !== session) { s.getTracks().forEach((t) => t.stop()); return; }
      stream = s;
      streamDevice = deviceId;
      s.getAudioTracks().forEach((t) => t.addEventListener('ended', () => { if (stream === s) closeStream(); }));
      src = c.createMediaStreamSource(s);
      src.connect(node!);
      warm = false;
    }
    if (c.state !== 'running') await c.resume();
    if (my !== session) return;
    monitor = !rec;
    record = rec;
    if (rec && warm && ringLen > 0) {
      // the 0.4 s before the press (people start speaking while pressing)
      const pre = new Float32Array(ringLen);
      let o = 0;
      for (const r of ring) { pre.set(r, o); o += r.length; }
      api.chunk(pre.length > PREROLL ? pre.subarray(pre.length - PREROLL) : pre);
    }
    ring = []; ringLen = 0;
    api.started({ label: stream?.getAudioTracks()[0]?.label ?? '', sampleRate: c.sampleRate, warm, openMs: Math.round(performance.now() - t0) });
  } catch (e) {
    const err = e as DOMException;
    api.error({ name: err.name ?? 'Error', message: err.message ?? String(e) });
    record = false; monitor = false;
    closeStream();
  }
}

function closeStream() {
  try { src?.disconnect(); } catch { /* */ }
  src = null;
  stream?.getTracks().forEach((t) => t.stop());
  stream = null;
  streamDevice = '';
  ring = []; ringLen = 0;
  if (ctx && ctx.state === 'running') void ctx.suspend().catch(() => undefined);
}

function finish() {
  if (finishTimer) clearTimeout(finishTimer);
  finishTimer = undefined;
  if (!flushing) return;
  flushing = false;
  record = false;
  monitor = false;
  api.stopped();
  // stay warm for the next press, then let the mic go
  if (warmTimer) clearTimeout(warmTimer);
  warmTimer = window.setTimeout(() => { warmTimer = undefined; if (!record && !monitor) closeStream(); }, WARM_MS);
}

api.onStart((o) => void open(o.deviceId, true));
api.onMonitor((o) => void open(o.deviceId, false));
api.onStop(() => {
  session++; // a start still opening is cancelled
  if (node && record) {
    flushing = true;
    node.port.postMessage('flush');
    finishTimer = window.setTimeout(finish, 300);
  } else {
    flushing = true;
    finish();
  }
});

(window as unknown as { __flowDevices: () => Promise<{ deviceId: string; label: string }[]> }).__flowDevices = async () => {
  const list = await navigator.mediaDevices.enumerateDevices();
  return list.filter((d) => d.kind === 'audioinput' && d.deviceId !== 'default' && d.deviceId !== 'communications')
    .map((d) => ({ deviceId: d.deviceId, label: d.label || 'Mikrofon' }));
};

// create the context + worklet right away (the expensive part of a cold start)
void context().then((c) => c.suspend()).catch(() => undefined);

export {};
