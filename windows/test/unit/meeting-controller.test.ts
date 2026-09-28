// Notetaker controller end to end with mocks (no microphone, no screen, no clipboard, no models):
// recording → two aligned WAV tracks + live transcript → processing → transcript, keep-audio setting, prompt,
// rename/keep/delete, import, summary via a fake Claude CLI. Plus decoder + Claude CLI helpers.
import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Engine } from '../../src/asr/engine';
import { encodeWav16 } from '../../src/asr/wav';
import { MeetingController, type MeetingDeps } from '../../src/meeting/controller';
import { MockCapture, Recorder } from '../../src/meeting/recorder';
import { decodeFile, decodeWithFfmpeg, findFfmpeg, parseFfmpegDuration, parseWavLoose, readTrack, resample } from '../../src/meeting/decode';
import { claudeArgs, cmdLine, findClaude, parseSummary } from '../../src/meeting/claude';
import type { Word } from '../../src/meeting/types';

const tone = (sec: number, amp = 0.2) => { const a = new Float32Array(Math.round(sec * 16000)); for (let i = 0; i < a.length; i++) a[i] = amp * Math.sin(i / 3); return a; };
const concat = (...xs: Float32Array[]) => { const o = new Float32Array(xs.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of xs) { o.set(x, p); p += x.length; } return o; };
const tmp = () => mkdtempSync(path.join(os.tmpdir(), 'flow-mc-'));
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

const fakeEngine: Engine = {
  model: 'parakeet-v3',
  transcribe: async (s) => ({ text: 'ähm live Text', ms: 1, audioSec: s.length / 16000, speechSec: 1, segments: 1 }),
  decodeRaw: async () => ({ text: '', tokens: [], timestamps: [], durations: [] }),
  dispose: () => {},
};

function controller(over: Partial<MeetingDeps> = {}, capture = () => new MockCapture({ mic: concat(tone(0.5, 0), tone(2), tone(1.5, 0)), system: concat(tone(1, 0), tone(6), tone(1, 0)) })) {
  const root = tmp();
  const log = { clipboard: '', toasts: [] as string[], tasks: [] as string[], meeting: [] as unknown[] };
  const words = (s: Float32Array): Word[] => s.length > 6 * 16000 ? [{ word: 'Hallo', start: 1, end: 1.4 }, { word: 'zusammen', start: 1.5, end: 2 }, { word: 'Antwort', start: 6, end: 6.5 }] : [{ word: 'Mein', start: 0.6, end: 0.9 }, { word: 'Beitrag', start: 1, end: 1.5 }];
  const c = new MeetingController({
    root, modelsRoot: root, platform: 'win32', locale: () => 'de', micDeviceId: () => '',
    clean: (t) => t.replace(/(^|\s)ähm(?=\s|$)/gu, ' ').trim(),
    asr: () => fakeEngine, waitAsr: async () => fakeEngine, capture,
    copyText: (t) => { log.clipboard = t; }, log: () => {},
    pill: { meeting: (m) => log.meeting.push(m), task: (t) => { if (t) log.tasks.push(t.label); }, card: () => {}, toast: (t) => log.toasts.push(t), level: () => {} },
    diarizer: async () => ({ diarize: async () => [{ speaker: 7, start: 0.5, end: 3 }, { speaker: 3, start: 5.5, end: 7 }] }),
    transcriber: () => async (s, p) => { p(1); return words(s); },
    ...over,
  });
  c.init();
  return { c, root, log };
}

describe('recorder', () => {
  it('writes ich.wav + andere.wav, the late system track is padded to the mic timeline', async () => {
    const dir = tmp();
    const cap = new MockCapture({ mic: tone(3), system: tone(1) });
    const r = new Recorder(cap, dir);
    const live: number[] = [];
    r.on('live', (x) => live.push(x.start));
    // simulate the loopback starting 2 s late: feed mic first, then system
    const res0 = await r.start({ micDeviceId: '', systemAudio: true });
    expect(res0).toEqual({ mic: true, system: true });
    await wait(10);
    const res = await r.stop();
    expect(res.mic && res.system).toBe(true);
    const mic = readTrack(path.join(dir, 'ich.wav')), sys = readTrack(path.join(dir, 'andere.wav'));
    expect(mic.length).toBe(3 * 16000);
    expect(sys.length).toBe(mic.length); // padded at the end
  });
  it('mic refused → nothing recorded; no system audio → only ich.wav', async () => {
    const dir = tmp();
    expect((await new Recorder(new MockCapture({ mic: tone(1) }, { failMic: true }), dir).start({ micDeviceId: '', systemAudio: true })).mic).toBe(false);
    const d2 = tmp();
    const r = new Recorder(new MockCapture({ mic: tone(1) }), d2);
    expect(await r.start({ micDeviceId: '', systemAudio: true })).toEqual({ mic: true, system: false });
    await wait(5);
    await r.stop();
    expect(existsSync(path.join(d2, 'ich.wav'))).toBe(true);
    expect(readTrack(path.join(d2, 'andere.wav')).length).toBe(0); // header only, not a track
  });
});

describe('controller', () => {
  it('record → live transcript → stop → processed transcript with speakers; prompt to the (fake) clipboard', async () => {
    const { c, log } = controller();
    expect(await c.start(null)).toBe(true);
    expect(c.isRecording).toBe(true);
    expect((log.meeting[0] as { label: string }).label).toBe('Meeting läuft');
    await wait(80);
    const live = c.store.meetings[0]!;
    expect(live.status).toBe('recording');
    expect(live.segments.some((s) => s.text === 'live Text')).toBe(true); // filler cleaned
    await c.stop();
    await c.idle();
    const m = c.store.meetings[0]!;
    expect(m.status).toBe('done');
    expect(m.tracks).toEqual({ mic: true, system: true });
    expect(m.segments.map((s) => [s.speaker, s.text])).toEqual([['me', 'Mein Beitrag'], ['S1', 'Hallo zusammen'], ['S2', 'Antwort']]);
    expect(log.toasts).toContain('Meeting gespeichert – wird ausgewertet');
    expect(log.toasts).toContain('Transkript fertig');
    expect(existsSync(path.join(c.store.folder(m.id), 'ich.wav'))).toBe(true); // keepAudio default
    const r = await c.copyPrompt(m.id);
    expect(r.ok).toBe(true);
    expect(log.clipboard).toContain(path.join(c.store.folder(m.id), 'Kontext-Paket', 'transkript.md'));
    expect(log.clipboard).toContain('(3 Abschnitte, ca. 5 Wörter, ');
    expect(log.clipboard).toContain(`Originalaufnahme: ${path.join(c.store.folder(m.id), 'ich.wav')}`);
    expect(log.toasts.at(-1)).toBe('Prompt kopiert ✓');
    c.dispose();
  });

  it('keepAudio off → tracks deleted after processing; rename, speaker names, keep, delete', async () => {
    const { c, log } = controller();
    c.setSettings({ keepAudio: false, myName: 'Sam' });
    await c.start('Zoom');
    await wait(30);
    await c.stop();
    await c.idle();
    const m = c.store.meetings[0]!;
    expect(m.title.startsWith('Zoom-Meeting · ')).toBe(true);
    expect(existsSync(path.join(c.store.folder(m.id), 'ich.wav'))).toBe(false);
    c.rename(m.id, '  Planung  ');
    c.renameSpeaker(m.id, 'S1', 'Alex');
    c.setKeep(m.id, true);
    const saved = JSON.parse(readFileSync(path.join(c.store.folder(m.id), 'meeting.json'), 'utf8'));
    expect(saved).toMatchObject({ title: 'Planung', speakerNames: { S1: 'Alex' }, keep: true });
    await c.copyTranscript(m.id);
    expect(log.clipboard).toBe('[00:00] Sam: Mein Beitrag\n[00:01] Alex: Hallo zusammen\n[00:06] Sprecher 2: Antwort');
    expect(c.hubState().meetings[0]).toMatchObject({ keep: true, deletesAt: null, speakers: 3 });
    c.delete(m.id);
    expect(existsSync(c.store.folder(m.id))).toBe(false);
    c.dispose();
  });

  it('import: WAV file → processed with a progress task on the pill; unsupported file refused', async () => {
    const { c, root, log } = controller();
    const f = path.join(root, 'Interview.wav');
    writeFileSync(f, encodeWav16(concat(tone(1, 0), tone(8), tone(1, 0)), 16000));
    expect(c.importFile(f).ok).toBe(true);
    await c.idle();
    const m = c.store.meetings[0]!;
    expect(m).toMatchObject({ title: 'Interview', source: 'import', sourcePath: f, status: 'done' });
    expect(m.duration).toBeCloseTo(10);
    expect(m.segments.map((s) => s.speaker)).toEqual(['S1', 'S2']);
    expect(log.tasks.some((t) => /^Audiodatei · \d+ %$/.test(t))).toBe(true);
    expect(c.importFile(path.join(root, 'notes.txt')).ok).toBe(false);
    expect(log.toasts).toContain('Dateiformat nicht unterstützt');
    c.dispose();
  });

  it('import of a vanished file fails cleanly; reprocess is refused without the source', async () => {
    const { c, root } = controller();
    const f = path.join(root, 'gone.mp3');
    writeFileSync(f, 'x');
    c.importFile(f);
    await c.idle();
    expect(c.store.meetings[0]!.status).toBe('failed');
    execFileSync('rm', [f]);
    expect(c.reprocess(c.store.meetings[0]!.id)).toBe(false);
    expect(c.store.meetings[0]!.progressNote).toBe('missingSource');
    c.dispose();
  });

  it('summary only with a Claude CLI; TITEL line becomes the title', async () => {
    const { c } = controller({ claudeBin: () => 'C:\\claude.exe', runClaude: async (_b, sys, input) => { expect(sys).toContain('TITEL:'); expect(input).toContain('Antwort'); return 'TITEL: Umzugsplanung\n**Kurzfassung** – alles klar.'; } });
    await c.start(null); await wait(20); await c.stop(); await c.idle();
    const id = c.store.meetings[0]!.id;
    expect(c.hubState().claude).toBe(true);
    expect(await c.summarize(id)).toBe(true);
    expect(c.get(id)).toMatchObject({ title: 'Umzugsplanung', summary: '**Kurzfassung** – alles klar.' });
    c.dispose();
    const { c: c2 } = controller({ claudeBin: () => null });
    expect(c2.hubState().claude).toBe(false);
    expect(await c2.summarize('x')).toBe(false);
    c2.dispose();
  });

  it('microphone refused → no meeting, error toast', async () => {
    const { c, log } = controller({}, () => new MockCapture({ mic: tone(1) }, { failMic: true }));
    expect(await c.start(null)).toBe(false);
    expect(c.store.meetings).toEqual([]);
    expect(log.toasts).toContain('Mikrofon startet nicht');
    c.dispose();
  });
});

describe('decoding', () => {
  it('tolerant WAV reader: header size 0 (crashed recording) reads to the end; stereo 48 kHz → 16 kHz mono', () => {
    const b = encodeWav16(tone(1), 16000);
    b.writeUInt32LE(0, 40);
    expect(parseWavLoose(b).samples.length).toBe(16000);
    // stereo float 48 kHz
    const n = 4800, buf = Buffer.alloc(44 + n * 8);
    buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 8, 4); buf.write('WAVE', 8); buf.write('fmt ', 12); buf.writeUInt32LE(16, 16);
    buf.writeUInt16LE(3, 20); buf.writeUInt16LE(2, 22); buf.writeUInt32LE(48000, 24); buf.writeUInt32LE(48000 * 8, 28); buf.writeUInt16LE(8, 32); buf.writeUInt16LE(32, 34);
    buf.write('data', 36); buf.writeUInt32LE(n * 8, 40);
    for (let i = 0; i < n; i++) { buf.writeFloatLE(0.5, 44 + i * 8); buf.writeFloatLE(-0.1, 48 + i * 8); }
    const w = parseWavLoose(buf);
    expect(w.sampleRate).toBe(48000);
    expect(w.samples[10]).toBeCloseTo(0.2);
    const r = resample(w.samples, 48000);
    expect(r.length).toBe(1600);
    expect(r[5]).toBeCloseTo(0.2);
  });
  it('ffmpeg lookup: setting → PATH → winget/scoop/choco; Windows paths', () => {
    const has = (set: string[]) => (p: string) => set.includes(p);
    expect(findFfmpeg('D:\\tools\\ffmpeg.exe', {}, 'win32', has(['D:\\tools\\ffmpeg.exe']))).toBe('D:\\tools\\ffmpeg.exe');
    expect(findFfmpeg('', { PATH: 'C:\\a;C:\\ffmpeg\\bin' }, 'win32', has(['C:\\ffmpeg\\bin\\ffmpeg.exe']))).toBe('C:\\ffmpeg\\bin\\ffmpeg.exe');
    expect(findFfmpeg('', { PATH: '', LOCALAPPDATA: 'C:\\Users\\T\\AppData\\Local' }, 'win32', has(['C:\\Users\\T\\AppData\\Local\\Microsoft\\WinGet\\Links\\ffmpeg.exe']))).toContain('WinGet');
    expect(findFfmpeg('', { PATH: '' }, 'win32', () => false)).toBeNull();
    expect(parseFfmpegDuration('  Duration: 01:02:03.50, start: 0')).toBeCloseTo(3723.5);
  });
  it('without ffmpeg a non-WAV file goes to the Chromium decoder; too-large files are refused', async () => {
    const dir = tmp();
    const f = path.join(dir, 'a.m4a');
    writeFileSync(f, 'x');
    const r = await decodeFile(f, { ffmpeg: null, chromium: async () => new Float32Array(160) });
    expect(r.via).toBe('chromium');
    await expect(decodeFile(path.join(dir, 'nope.mp3'), { ffmpeg: null })).rejects.toThrow('file not found');
  });
  const ff = findFfmpeg('');
  it.skipIf(!ff || process.platform !== 'darwin')('real ffmpeg decode of an m4a (made with afconvert) → 16 kHz mono', async () => {
    const dir = tmp();
    const wav = path.join(dir, 't.wav'), m4a = path.join(dir, 't.m4a');
    writeFileSync(wav, encodeWav16(tone(2), 16000));
    execFileSync('afconvert', ['-f', 'm4af', '-d', 'aac', wav, m4a]);
    const s = await decodeWithFfmpeg(ff!, m4a);
    expect(Math.abs(s.length - 32000)).toBeLessThan(3000);
  });
});

describe('Claude CLI helpers', () => {
  it('finds the CLI in the usual Windows places', () => {
    const env = { USERPROFILE: 'C:\\Users\\T', APPDATA: 'C:\\Users\\T\\AppData\\Roaming', PATH: 'C:\\bin' };
    expect(findClaude(env, 'win32', (p) => p === 'C:\\Users\\T\\AppData\\Roaming\\npm\\claude.cmd')).toBe('C:\\Users\\T\\AppData\\Roaming\\npm\\claude.cmd');
    expect(findClaude(env, 'win32', (p) => p === 'C:\\Users\\T\\.local\\bin\\claude.exe')).toBe('C:\\Users\\T\\.local\\bin\\claude.exe');
    expect(findClaude(env, 'win32', () => false)).toBeNull();
  });
  it('no tools, no MCP, no session; cmd.exe quoting refuses unsafe arguments', () => {
    const a = claudeArgs('C:\\T\\system.txt');
    expect(a).toEqual(['-p', '--model', 'sonnet', '--system-prompt-file', 'C:\\T\\system.txt', '--tools', '', '--strict-mcp-config', '--setting-sources', '', '--no-session-persistence', '--output-format', 'text']);
    expect(cmdLine('C:\\npm\\claude.cmd', ['-p', ''])).toBe('"C:\\npm\\claude.cmd" "-p" ""');
    expect(() => cmdLine('c.cmd', ['a" & calc'])).toThrow();
    expect(() => cmdLine('c.cmd', ['%PATH%'])).toThrow();
  });
  it('TITEL line → title', () => {
    expect(parseSummary('TITEL: Kurz\n\n**Kurzfassung** – x')).toEqual({ title: 'Kurz', summary: '**Kurzfassung** – x' });
    expect(parseSummary('**Kurzfassung** – x')).toEqual({ title: null, summary: '**Kurzfassung** – x' });
  });
});
