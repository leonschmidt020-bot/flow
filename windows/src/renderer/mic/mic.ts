// Hidden capture page. getUserMedia → AudioWorklet → main (IPC).
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

let ctx: AudioContext | null = null;
let stream: MediaStream | null = null;
let node: AudioWorkletNode | null = null;
let record = false;
let session = 0;

async function open(deviceId: string, rec: boolean) {
  const my = ++session;
  await close(false);
  record = rec;
  const constraints = (id: string): MediaStreamConstraints => ({
    audio: { deviceId: id ? { exact: id } : undefined, channelCount: 1, echoCancellation: false, noiseSuppression: true, autoGainControl: true },
    video: false,
  });
  try {
    try {
      stream = await navigator.mediaDevices.getUserMedia(constraints(deviceId));
    } catch (e) {
      if (!deviceId) throw e;
      stream = await navigator.mediaDevices.getUserMedia(constraints('')); // device gone → default
    }
    if (my !== session) { stream.getTracks().forEach((t) => t.stop()); return; }
    ctx = new AudioContext({ sampleRate: 16000, latencyHint: 'interactive' });
    await ctx.audioWorklet.addModule('worklet.js');
    const src = ctx.createMediaStreamSource(stream);
    node = new AudioWorkletNode(ctx, 'flow-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1 });
    node.port.onmessage = (e: MessageEvent) => {
      const d = e.data as { type: string; samples?: Float32Array; rms?: number };
      if (d.type === 'chunk' && record && d.samples) api.chunk(d.samples);
      else if (d.type === 'level') api.level(d.rms ?? 0);
      else if (d.type === 'flushed') finish();
    };
    const mute = ctx.createGain();
    mute.gain.value = 0;
    src.connect(node).connect(mute).connect(ctx.destination);
    api.started({ label: stream.getAudioTracks()[0]?.label ?? '', sampleRate: ctx.sampleRate });
  } catch (e) {
    const err = e as DOMException;
    api.error({ name: err.name ?? 'Error', message: err.message ?? String(e) });
    await close(false);
  }
}

let finishTimer: number | undefined;
function finish() {
  if (finishTimer) clearTimeout(finishTimer);
  finishTimer = undefined;
  void close(true);
}

async function close(notify: boolean) {
  const n = node, c = ctx, s = stream;
  node = null; ctx = null; stream = null;
  try { n?.disconnect(); } catch { /* */ }
  s?.getTracks().forEach((t) => t.stop());
  if (c && c.state !== 'closed') await c.close().catch(() => undefined);
  if (notify) api.stopped();
}

api.onStart((o) => void open(o.deviceId, true));
api.onMonitor((o) => void open(o.deviceId, false));
api.onStop(() => {
  if (node) {
    node.port.postMessage('flush');
    finishTimer = window.setTimeout(finish, 300);
  } else {
    void close(true);
  }
});

(window as unknown as { __flowDevices: () => Promise<{ deviceId: string; label: string }[]> }).__flowDevices = async () => {
  const list = await navigator.mediaDevices.enumerateDevices();
  return list.filter((d) => d.kind === 'audioinput' && d.deviceId !== 'default' && d.deviceId !== 'communications')
    .map((d) => ({ deviceId: d.deviceId, label: d.label || 'Mikrofon' }));
};

export {};
