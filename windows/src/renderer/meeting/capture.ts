// Hidden meeting capture page: microphone + system-audio loopback → the dictation worklet (16 kHz mono, 100 ms blocks)
// → main. Also decodes imported files with Chromium's decoder. Never shows anything, never reads a video frame.
interface CapApi {
  onStart(cb: (id: number, o: { micDeviceId: string; systemAudio: boolean }) => void): void;
  onStop(cb: (id: number) => void): void;
  onDecode(cb: (id: number, bytes: ArrayBuffer) => void): void;
  reply(id: number, ok: boolean, payload: unknown): void;
  chunk(track: string, s: Float32Array): void;
  level(track: string, rms: number): void;
  error(msg: string): void;
  ended(track: string): void;
}
const api = (window as unknown as { flowMeetingCap: CapApi }).flowMeetingCap;

let ctx: AudioContext | null = null;
const streams: MediaStream[] = [];
const nodes: AudioWorkletNode[] = [];

async function attach(track: 'mic' | 'system', stream: MediaStream) {
  if (!ctx) return;
  const src = ctx.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(ctx, 'flow-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1 });
  node.port.onmessage = (e: MessageEvent) => {
    const d = e.data as { type: string; samples?: Float32Array; rms?: number };
    if (d.type === 'chunk' && d.samples) api.chunk(track, d.samples);
    else if (d.type === 'level') api.level(track, d.rms ?? 0);
  };
  const mute = ctx.createGain();
  mute.gain.value = 0; // never play the loopback back (feedback)
  src.connect(node).connect(mute).connect(ctx.destination);
  nodes.push(node);
  stream.getAudioTracks().forEach((t) => t.addEventListener('ended', () => api.ended(track)));
}

async function start(o: { micDeviceId: string; systemAudio: boolean }) {
  await stop();
  ctx = new AudioContext({ sampleRate: 16000, latencyHint: 'playback' });
  await ctx.audioWorklet.addModule('../mic/worklet.js');
  const micConstraints = (id: string): MediaStreamConstraints => ({
    audio: { deviceId: id ? { exact: id } : undefined, channelCount: 1, echoCancellation: false, noiseSuppression: true, autoGainControl: true },
    video: false,
  });
  let mic: MediaStream;
  try { mic = await navigator.mediaDevices.getUserMedia(micConstraints(o.micDeviceId)); }
  catch (e) { if (!o.micDeviceId) throw e; mic = await navigator.mediaDevices.getUserMedia(micConstraints('')); }
  streams.push(mic);
  await attach('mic', mic);
  let system = false;
  if (o.systemAudio) {
    try {
      const d = await navigator.mediaDevices.getDisplayMedia({ audio: true, video: true });
      d.getVideoTracks().forEach((t) => t.stop()); // audio only – the screen is never looked at
      if (d.getAudioTracks().length > 0) { streams.push(d); await attach('system', d); system = true; }
    } catch (e) {
      api.error('system audio: ' + ((e as Error).message ?? String(e)));
    }
  }
  return { mic: true, system };
}

async function stop() {
  // flush the last partial block of every worklet
  for (const n of nodes) n.port.postMessage('flush');
  await new Promise((r) => setTimeout(r, nodes.length ? 150 : 0));
  for (const n of nodes) { try { n.disconnect(); } catch { /* */ } }
  nodes.length = 0;
  for (const s of streams) s.getTracks().forEach((t) => t.stop());
  streams.length = 0;
  const c = ctx; ctx = null;
  if (c && c.state !== 'closed') await c.close().catch(() => undefined);
}

async function decode(bytes: ArrayBuffer): Promise<Float32Array> {
  // an OfflineAudioContext at 16 kHz makes decodeAudioData resample for us
  const oc = new OfflineAudioContext(1, 1, 16000);
  const buf = await oc.decodeAudioData(bytes);
  const n = buf.length, ch = buf.numberOfChannels;
  const out = new Float32Array(n);
  for (let c = 0; c < ch; c++) { const d = buf.getChannelData(c); for (let i = 0; i < n; i++) out[i]! += d[i]! / ch; }
  return out;
}

api.onStart((id, o) => { start(o).then((r) => api.reply(id, true, r), (e: DOMException) => { void stop(); api.reply(id, true, { mic: false, system: false, error: e?.name || String(e) }); }); });
api.onStop((id) => { stop().then(() => api.reply(id, true, null), () => api.reply(id, true, null)); });
api.onDecode((id, bytes) => { decode(bytes).then((s) => api.reply(id, true, s), (e: Error) => api.reply(id, false, e?.message ?? String(e))); });

export {};
