// Notetaker controller (main process): recording, live transcript, call detection, audio import, background
// processing (diarization + timed transcription), summary, „Prompt für Agent“, retention. Electron-free: every
// platform piece (capture, clipboard, pill, decoder, call probe, Claude CLI) is injected, so it runs in tests.
import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { Engine } from '../asr/engine';
import { JsonFile } from '../main/store';
import { CallDetector, type ActiveCall, type Probe } from './detect';
import { decodeFile, DecodeError, findFfmpeg, isAudioFile, readTrack, type ChromiumDecode } from './decode';
import { createDiarizer, ensureDiarizationModels, isDiarizationReady, type Diarizer } from './diarizer';
import { timedTranscriber } from './engines';
import { meetingId, shortDate, speakerKeys, transcriptText, wordsIn } from './format';
import { mt, type MLoc } from './i18n';
import { segId } from './merge';
import { agentPrompt, writePackage } from './package';
import { processTracks, type ProcessStep } from './processor';
import { Recorder, type CaptureBackend, type LiveChunk } from './recorder';
import { MEETING_DEFAULTS, migrateMeetingSettings, type MeetingSettings } from './settings';
import { deletionDate, MeetingStore } from './store';
import { parseSummary, runClaude, SUMMARY_SYSTEM } from './claude';
import { MIC_FILE, SYSTEM_FILE, type Meeting, type MeetingHubState, type MeetingListItem, type Segment, type Turn, type Word } from './types';

export interface PillCard { kind: 'detected' | 'over'; title: string; sub: string; yes: string; no: string }
export interface PillPort {
  meeting(m: { startedAt: number; label: string } | null): void;
  task(t: { label: string; progress: number } | null): void;
  card(c: PillCard | null): void;
  toast(text: string, kind?: 'info' | 'success' | 'error', ms?: number): void;
  level(lv: number): void;
}

export interface MeetingDeps {
  root: string;
  modelsRoot: string;
  platform: NodeJS.Platform;
  locale: () => MLoc;
  micDeviceId: () => string;
  /** fillers / dictionary / voice commands – TextCleaner.applyRules with the dictation settings */
  clean: (text: string) => string;
  asr: () => Engine | null;
  /** resolves when an ASR engine is loaded (or rejects when none can be) */
  waitAsr: () => Promise<Engine>;
  capture: () => CaptureBackend;
  chromiumDecode?: ChromiumDecode;
  copyText: (text: string) => Promise<void> | void;
  pill: PillPort;
  log: (...a: unknown[]) => void;
  callProbe?: Probe;
  /** Flow's own exe (never counted as a call app) */
  ownExe?: string;
  /** better display name from window titles („Teams · Wochenplanung“, „Google Meet“) – naming hint only */
  callName?: (call: ActiveCall) => string | null;
  /** detection timings (tests shorten them) */
  timing?: { pollMs?: number; endGraceMs?: number; overTimeoutMs?: number; promptTimeoutMs?: number };
  claudeBin?: () => string | null;
  /** injectable for tests */
  diarizer?: () => Promise<Diarizer>;
  transcriber?: (engine: Engine) => (s: Float32Array, onProgress: (p: number) => void) => Promise<Word[]>;
  runClaude?: (bin: string, system: string, input: string) => Promise<string>;
  now?: () => number;
}

interface Rec { id: string; recorder: Recorder; startedAt: number; callId: string | null; callName: string | null; goneSince: number | null; auto: boolean; saveTimer: NodeJS.Timeout }

export class MeetingController extends EventEmitter {
  readonly store: MeetingStore;
  settings: MeetingSettings;
  private settingsFile: JsonFile<MeetingSettings>;
  private rec: Rec | null = null;
  private starting = false;
  private queue: string[] = [];
  private working: string | null = null;
  private diarizer: Diarizer | null = null;
  private diar: MeetingHubState['diarization'];
  private detector: CallDetector | null = null;
  private promptedFor = new Set<string>();
  private promptApp: ActiveCall | null = null;
  private cardTimer: NodeJS.Timeout | null = null;
  private liveBusy = 0;
  private liveChain: Promise<void> = Promise.resolve();
  private cleanupTimer: NodeJS.Timeout | null = null;
  private importing: MeetingHubState['importing'] = null;
  private summarizing = new Set<string>();

  constructor(private d: MeetingDeps) {
    super();
    mkdirSync(d.root, { recursive: true });
    this.store = new MeetingStore(d.root);
    this.settingsFile = new JsonFile<MeetingSettings>(path.join(d.root, 'settings.json'));
    this.settings = migrateMeetingSettings(this.settingsFile.load(() => MEETING_DEFAULTS).value);
    this.diar = { status: isDiarizationReady(d.modelsRoot) ? 'ready' : 'missing', progress: 0, error: '' };
  }

  private now() { return this.d.now ? this.d.now() : Date.now(); }
  private L() { return this.d.locale(); }
  private changed() { this.emit('change'); }

  init() {
    this.store.load();
    this.cleanup();
    this.cleanupTimer = setInterval(() => this.cleanup(), 3600_000);
    this.cleanupTimer.unref?.();
    // interrupted recordings/processing stay „failed“ with „Neu auswerten“ (no automatic retry: a crash must not loop)
    if (this.d.callProbe) {
      this.detector = new CallDetector(this.d.callProbe, this.d.timing?.pollMs ?? 3000, this.d.ownExe ?? '');
      this.detector.on('change', (apps: ActiveCall[]) => this.appsChanged(apps));
      if (this.settings.detection !== 'off') this.detector.start();
    }
  }

  dispose() {
    this.detector?.stop();
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
    if (this.rec) { clearInterval(this.rec.saveTimer); void this.rec.recorder.stop(); }
    this.settingsFile.flush();
  }

  // ── settings ──
  setSettings(patch: Partial<MeetingSettings>): MeetingSettings {
    const prev = this.settings;
    this.settings = migrateMeetingSettings({ ...this.settings, ...patch });
    this.settingsFile.save(this.settings);
    if (prev.detection !== this.settings.detection) {
      if (this.settings.detection === 'off') { this.detector?.stop(); this.dismissPrompt(); } else this.detector?.start();
    }
    if (prev.retentionDays !== this.settings.retentionDays) this.cleanup();
    this.changed();
    return this.settings;
  }

  get isRecording() { return !!this.rec; }
  get recordingStartedAt() { return this.rec?.startedAt ?? null; }
  /** FLOW_NO_FFMPEG=1 forces Electron's built-in decoder (self-test) */
  ffmpeg() { return process.env.FLOW_NO_FFMPEG === '1' ? null : findFfmpeg(this.settings.ffmpegPath); }
  claude() { return this.d.claudeBin?.() ?? null; }

  // ── recording ──
  toggle() { return this.rec ? this.stop() : this.start(null); }

  async start(app: string | null, auto = false): Promise<boolean> {
    if (this.rec || this.starting) return false;
    this.starting = true;
    try {
      this.dismissPrompt();
      const now = new Date(this.now());
      const L = this.L();
      const id = meetingId(now, randomUUID());
      const folder = this.store.folder(id);
      mkdirSync(folder, { recursive: true });
      const m: Meeting = {
        version: 1, id, title: `${app ? `${app.replace(/ \(.*\)$/, '')}-Meeting` : mt(L, 'meetingWord')} · ${shortDate(now, L)}`,
        date: now.toISOString(), duration: 0, app, source: 'recording', status: 'recording', segments: [], speakerNames: {},
        tracks: { mic: false, system: false },
      };
      const recorder = new Recorder(this.d.capture(), folder);
      recorder.on('live', (c: LiveChunk) => this.live(id, c));
      recorder.on('level', (track: string, lv: number) => { if (track === 'mic') this.d.pill.level(lv); });
      recorder.on('error', (msg: string) => this.d.log('meeting capture:', msg));
      this.store.active.add(id);
      const r = await recorder.start({ micDeviceId: this.d.micDeviceId(), systemAudio: this.settings.systemAudio });
      if (!r.mic) {
        this.store.active.delete(id);
        rmSync(folder, { recursive: true, force: true });
        this.d.pill.toast(mt(L, 'toastMicFailed'), 'error');
        this.d.log('meeting: mic failed', r.error);
        return false;
      }
      m.tracks = { mic: true, system: r.system };
      this.store.save(m);
      const call = this.detector?.active[0] ?? null;
      this.rec = { id, recorder, startedAt: now.getTime(), callId: call?.id ?? null, callName: call ? this.displayName(call) : app, goneSince: null, auto,
        saveTimer: setInterval(() => { const cur = this.store.get(id); if (cur) this.store.save({ ...cur, duration: recorder.seconds }); }, 30_000) };
      this.rec.saveTimer.unref?.();
      this.d.pill.meeting({ startedAt: now.getTime(), label: mt(L, 'pillRunning', { t: '' }).replace(/\s*·\s*$/, '') });
      if (this.settings.systemAudio && !r.system) this.d.pill.toast(mt(L, 'toastMicOnly'), 'info', 3500);
      else this.d.pill.toast(auto && app ? mt(L, 'toastAutoStarted', { app }) : mt(L, 'toastStarted'), 'success', 2200);
      this.d.log(`meeting started ${id} app=${app ?? '-'} system=${r.system}`);
      this.changed();
      return true;
    } finally {
      this.starting = false;
    }
  }

  /** live transcript: one after another, at most 3 waiting (oldest are skipped, like the Mac) */
  private live(id: string, c: LiveChunk) {
    if (this.liveBusy >= 3) return;
    const engine = this.d.asr();
    if (!engine) return;
    this.liveBusy++;
    this.liveChain = this.liveChain.then(async () => {
      try {
        const r = await engine.transcribe(c.samples, 'auto');
        const text = this.d.clean(r.text).trim();
        const m = this.store.get(id);
        if (!text || !m || m.status !== 'recording') return;
        const seg: Segment = { id: segId(), speaker: c.track === 'mic' ? 'me' : 'live', start: c.start, end: c.start + c.samples.length / 16000, text };
        const segments = [...m.segments, seg].sort((a, b) => a.start - b.start);
        this.store.upsert({ ...m, segments, duration: this.rec?.recorder.seconds ?? m.duration });
        this.changed();
      } catch (e) {
        this.d.log('live transcript failed', e);
      } finally {
        this.liveBusy--;
      }
    });
  }

  async stop(): Promise<void> {
    const rec = this.rec;
    if (!rec) return;
    this.rec = null;
    clearInterval(rec.saveTimer);
    this.clearCard();
    const res = await rec.recorder.stop();
    await this.liveChain.catch(() => undefined);
    const m = this.store.get(rec.id);
    this.d.pill.meeting(null);
    this.d.pill.level(0);
    if (!m) { this.store.active.delete(rec.id); return; }
    this.store.save({ ...m, duration: res.seconds || (this.now() - rec.startedAt) / 1000, status: 'processing', progressNote: 'diarizeOthers', progress: 0, tracks: { mic: res.mic, system: res.system } });
    this.d.pill.toast(mt(this.L(), 'toastSaved'), 'info', 2500);
    this.d.log(`meeting stopped ${rec.id}, ${Math.round(res.seconds)} s`);
    this.enqueue(rec.id);
    this.changed();
  }

  // ── import ──
  importFile(file: string): { ok: boolean; error?: string } {
    const L = this.L();
    if (!isAudioFile(file) || !existsSync(file)) { this.d.pill.toast(mt(L, 'toastUnsupported'), 'error'); return { ok: false, error: 'unsupported' }; }
    const now = new Date(this.now());
    const id = meetingId(now, randomUUID());
    const title = path.basename(file).replace(/\.[^.]+$/, '').slice(0, 120) || mt(L, 'fileMeeting');
    const m: Meeting = {
      version: 1, id, title, date: now.toISOString(), duration: 0, app: null, source: 'import', sourcePath: file,
      status: 'processing', progressNote: 'decode', progress: 0, segments: [], speakerNames: {}, tracks: { mic: false, system: false },
    };
    this.store.active.add(id);
    this.store.save(m);
    this.d.pill.toast(mt(L, 'toastImportQueued'), 'info', 1800);
    this.enqueue(id);
    this.changed();
    return { ok: true };
  }

  private canReprocess(m: Meeting): boolean {
    if (m.source === 'import') return !!m.sourcePath && existsSync(m.sourcePath);
    return existsSync(path.join(this.store.folder(m.id), MIC_FILE)) || existsSync(path.join(this.store.folder(m.id), SYSTEM_FILE));
  }

  reprocess(id: string): boolean {
    const m = this.store.get(id);
    if (!m || m.status === 'recording' || this.queue.includes(id) || this.working === id) return false;
    if (!this.canReprocess(m)) { this.store.save({ ...m, status: 'failed', progressNote: m.source === 'import' ? 'missingSource' : 'noAudio' }); this.changed(); return false; }
    this.store.active.add(id);
    this.store.save({ ...m, status: 'processing', progressNote: m.source === 'import' ? 'decode' : 'diarizeOthers', progress: 0, damaged: undefined });
    this.enqueue(id);
    this.changed();
    return true;
  }

  // ── processing queue (one at a time) ──
  private enqueue(id: string) {
    if (!this.queue.includes(id)) this.queue.push(id);
    void this.pump();
  }

  /** resolves when the queue is empty (tests, self-test) */
  async idle(): Promise<void> {
    while (this.working || this.queue.length) await new Promise((r) => setTimeout(r, 50));
  }

  private async pump() {
    if (this.working) return;
    const id = this.queue.shift();
    if (!id) return;
    this.working = id;
    try { await this.process(id); } catch (e) { this.d.log('meeting processing', e); }
    finally {
      this.working = null;
      this.store.active.delete(id);
      if (this.importing && !this.queue.some((q) => this.store.get(q)?.source === 'import')) { this.importing = null; this.d.pill.task(null); }
      this.changed();
      void this.pump();
    }
  }

  private async getDiarizer(onProgress: (p: number) => void): Promise<Diarizer> {
    if (this.d.diarizer) return this.d.diarizer();
    if (this.diarizer) return this.diarizer;
    if (!isDiarizationReady(this.d.modelsRoot)) {
      this.diar = { status: 'downloading', progress: 0, error: '' };
      this.changed();
      try {
        await ensureDiarizationModels(this.d.modelsRoot, (p) => {
          if (p.phase === 'download' && p.total) { this.diar = { status: 'downloading', progress: p.received / p.total, error: '' }; onProgress(p.received / p.total); this.changed(); }
        });
      } catch (e) {
        this.diar = { status: 'error', progress: 0, error: e instanceof Error ? e.message : String(e) };
        this.changed();
        throw e;
      }
    }
    this.diarizer = createDiarizer(this.d.modelsRoot);
    this.diar = { status: 'ready', progress: 1, error: '' };
    return this.diarizer;
  }

  private async process(id: string) {
    const m0 = this.store.get(id);
    if (!m0) return;
    const L = this.L();
    const folder = this.store.folder(id);
    const isImport = m0.source === 'import';
    let lastSave = 0;
    const note = (key: string, progress: number) => {
      const cur = this.store.get(id);
      if (!cur) return;
      const next = { ...cur, progressNote: key, progress };
      // persist sometimes, keep the UI live always
      if (this.now() - lastSave > 5000) { lastSave = this.now(); this.store.save(next); } else this.store.upsert(next);
      if (isImport) {
        this.importing = { file: path.basename(cur.sourcePath ?? cur.title), progress, note: key };
        this.d.pill.task({ label: key === 'decode' && progress < 0.02 ? mt(L, 'pillImportDecode') : mt(L, 'pillImport', { pct: Math.round(progress * 100) }), progress });
      }
      this.changed();
    };
    try {
      // 1. audio
      let samples: Float32Array | null = null;
      if (isImport) {
        note('decode', 0);
        const r = await decodeFile(m0.sourcePath ?? '', { ffmpeg: this.ffmpeg(), chromium: this.d.chromiumDecode, onProgress: (p) => note('decode', 0.1 * p) });
        samples = r.samples;
        this.d.log(`meeting import: decoded via ${r.via}, ${(samples.length / 16000).toFixed(1)} s`);
        const cur = this.store.get(id)!;
        this.store.upsert({ ...cur, duration: samples.length / 16000 });
      }
      // 2. engines
      let engine = this.d.asr();
      if (!engine) { note('waitAsr', isImport ? 0.1 : 0); engine = await this.d.waitAsr(); }
      note('models', isImport ? 0.1 : 0);
      const diarizer = await this.getDiarizer((p) => note('models', (isImport ? 0.1 : 0) + 0.02 * p));
      const transcribe = (this.d.transcriber ?? ((e: Engine) => timedTranscriber(e, this.d.modelsRoot)))(engine);
      // overall progress: import = decode 10 %, diarize 15 %, transcribe 75 %; recording: others/me split
      const span: Record<ProcessStep, [number, number]> = isImport
        ? { diarizeRoom: [0.1, 0.15], transcribeRoom: [0.25, 0.75], diarizeOthers: [0.1, 0.15], transcribeOthers: [0.25, 0.4], transcribeMe: [0.65, 0.35] }
        : { diarizeOthers: [0, 0.15], transcribeOthers: [0.15, 0.45], transcribeMe: [0.6, 0.4], diarizeRoom: [0, 0.2], transcribeRoom: [0.2, 0.8] };
      const micFile = path.join(folder, MIC_FILE), sysFile = path.join(folder, SYSTEM_FILE);
      const segments = await processTracks(isImport ? { mic: () => samples! } : {
        mic: existsSync(micFile) ? () => readTrack(micFile) : undefined,
        system: existsSync(sysFile) ? () => readTrack(sysFile) : undefined,
      }, {
        transcribe: (s, p) => transcribe(s, p),
        diarize: (s, p) => diarizer.diarize(s, p),
        clean: this.d.clean,
        note: (k, p) => { const [a, w] = span[k]; note(k, a + w * p); },
      });
      samples = null;
      const cur = this.store.get(id)!;
      const done: Meeting = { ...cur, segments, status: 'done', progressNote: undefined, progress: undefined };
      if (!isImport && !this.settings.keepAudio) {
        rmSync(micFile, { force: true }); rmSync(sysFile, { force: true });
      }
      this.store.save(done);
      this.d.log(`meeting processed ${id}: ${segments.length} segments, ${speakerKeys(done).length} speakers`);
      this.d.pill.toast(mt(L, 'toastReady'), 'success', 2500);
      this.emit('processed', id);
      if (this.settings.autoSummary && segments.length && this.claude()) void this.summarize(id);
    } catch (e) {
      const msg = e instanceof DecodeError ? (e.code === 'tooLarge' ? mt(L, 'toastTooLarge') : e.code === 'unsupported' ? mt(L, 'toastUnsupported') : e.message) : e instanceof Error ? e.message : String(e);
      this.d.log('meeting processing failed', id, e);
      const cur = this.store.get(id);
      if (cur) this.store.save({ ...cur, status: 'failed', progressNote: msg.slice(0, 300), progress: undefined });
      if (isImport) this.d.pill.toast(mt(L, 'toastImportFailed', { msg: msg.slice(0, 60) }), 'error', 4000);
    }
  }

  // ── summary (optional, local claude CLI) ──
  async summarize(id: string): Promise<boolean> {
    const bin = this.claude();
    const m = this.store.get(id);
    if (!bin || !m || !m.segments.length || this.summarizing.has(id)) return false;
    this.summarizing.add(id);
    this.changed();
    try {
      const out = await (this.d.runClaude ?? ((b, s, i) => runClaude(b, s, i)))(bin, SUMMARY_SYSTEM, transcriptText(m, this.settings.myName, this.L()));
      const { title, summary } = parseSummary(out);
      const cur = this.store.get(id);
      if (cur) this.store.save({ ...cur, summary, title: title ?? cur.title });
      return true;
    } catch (e) {
      this.d.log('summary failed', e);
      this.d.pill.toast(String(e instanceof Error ? e.message : e).slice(0, 70), 'error', 3500);
      return false;
    } finally {
      this.summarizing.delete(id);
      this.changed();
    }
  }

  // ── actions from the hub ──
  rename(id: string, title: string) { const t = title.trim().slice(0, 200); if (t) { this.store.update(id, { title: t }); this.changed(); } }
  renameSpeaker(id: string, key: string, name: string) {
    const m = this.store.get(id);
    if (!m) return;
    const names = { ...m.speakerNames };
    if (name.trim()) names[key] = name.trim().slice(0, 80); else delete names[key];
    this.store.save({ ...m, speakerNames: names });
    this.changed();
  }
  setKeep(id: string, keep: boolean) { this.store.update(id, { keep: keep || undefined }); this.changed(); }
  delete(id: string) {
    if (this.rec?.id === id || this.working === id) return false;
    this.queue = this.queue.filter((q) => q !== id);
    this.store.delete(id);
    this.changed();
    return true;
  }

  /** „Prompt für Agent“: rebuild the package, prompt → clipboard, toast on the pill */
  async copyPrompt(id: string): Promise<{ ok: boolean; prompt?: string }> {
    const m = this.store.get(id);
    const L = this.L();
    if (!m) return { ok: false };
    try {
      const r = writePackage(m, this.store.folder(id), { loc: L, myName: this.settings.myName });
      const prompt = agentPrompt(m, r, { loc: L, myName: this.settings.myName });
      await this.d.copyText(prompt);
      this.d.pill.toast(mt(L, 'promptCopied'), 'success', 2200);
      return { ok: true, prompt };
    } catch (e) {
      this.d.log('package failed', e);
      this.d.pill.toast(mt(L, 'packageFailed'), 'error');
      return { ok: false };
    }
  }

  async copyTranscript(id: string) {
    const m = this.store.get(id);
    if (!m) return false;
    await this.d.copyText(transcriptText(m, this.settings.myName, this.L()));
    return true;
  }

  cleanup() {
    const removed = this.store.cleanup(this.settings.retentionDays, this.now());
    if (removed.length) { this.d.log(`notetaker cleanup: ${removed.length} removed`); this.changed(); }
  }

  // ── call detection (like MeetingController.appsChanged) ──
  private displayName(call: ActiveCall): string {
    let hint: string | null = null;
    try { hint = this.d.callName?.(call) ?? null; } catch { hint = null; }
    return hint ?? call.name;
  }

  private appsChanged(apps: ActiveCall[]) {
    // apps that released the mic may ask again next time
    this.promptedFor = new Set([...this.promptedFor].filter((id) => apps.some((a) => a.id === id)));
    const L = this.L();
    const T = { endGraceMs: 4000, overTimeoutMs: 90_000, promptTimeoutMs: 25_000, ...this.d.timing };
    if (this.rec) {
      const rec = this.rec;
      // which call belongs to this meeting? (also for a recording started by hand)
      if (!rec.callId && apps[0]) { rec.callId = apps[0].id; rec.callName = this.displayName(apps[0]); }
      if (!rec.callId) return;
      if (apps.some((a) => a.id === rec.callId)) { rec.goneSince = null; if (this.cardKind === 'over') this.clearCard(); return; }
      if (rec.goneSince !== null) return;
      rec.goneSince = this.now();
      this.d.log(`meeting: ${rec.callName ?? rec.callId} released the microphone`);
      // short dropouts happen → wait a moment, then: auto-started → stop; otherwise ask („Meeting vorbei?“, stops by itself after 90 s)
      setTimeout(() => {
        if (this.rec !== rec || rec.goneSince === null) return;
        const name = (rec.callName ?? '').replace(/ \(.*\)$/, '').trim() || mt(L, 'meetingWord');
        if (rec.auto) { this.d.pill.toast(mt(L, 'toastMeetingOver', { app: name }), 'info', 3000); void this.stop(); return; }
        this.showCard({ kind: 'over', title: name, sub: mt(L, 'cardOver'), yes: mt(L, 'cardStop'), no: mt(L, 'cardContinue') }, T.overTimeoutMs,
          () => { if (this.rec === rec) { this.d.pill.toast(mt(L, 'toastMeetingOver', { app: name }), 'info', 3000); void this.stop(); } });
      }, T.endGraceMs);
      return;
    }
    if (this.promptApp && !apps.some((a) => a.id === this.promptApp!.id)) this.dismissPrompt();
    if (this.settings.detection === 'off') return;
    const app = apps.find((a) => !this.promptedFor.has(a.id));
    if (!app) return;
    this.promptedFor.add(app.id);
    const name = this.displayName(app);
    if (this.settings.detection === 'auto') { void this.start(name, true); return; }
    this.promptApp = { ...app, name };
    this.showCard({ kind: 'detected', title: mt(L, 'cardDetected', { app: name.replace(/ \(.*\)$/, '') }), sub: mt(L, 'cardAsk'), yes: mt(L, 'cardRecord'), no: mt(L, 'cardLater') }, T.promptTimeoutMs, () => this.dismissPrompt());
    this.changed();
  }

  private cardKind: PillCard['kind'] | null = null;
  private showCard(c: PillCard, timeoutMs: number, onTimeout: () => void) {
    this.clearCard();
    this.cardKind = c.kind;
    this.d.pill.card(c);
    this.cardTimer = setTimeout(() => { this.cardTimer = null; onTimeout(); this.clearCard(); }, timeoutMs);
  }
  private clearCard() {
    if (this.cardTimer) clearTimeout(this.cardTimer);
    this.cardTimer = null;
    if (this.cardKind) { this.cardKind = null; this.d.pill.card(null); }
  }

  /** pill card buttons */
  cardAnswer(yes: boolean) {
    const kind = this.cardKind;
    this.clearCard();
    if (kind === 'detected') { if (yes) this.acceptPrompt(); else this.dismissPrompt(); }
    else if (kind === 'over' && this.rec) { if (yes) void this.stop(); else { this.rec.goneSince = null; this.rec.callId = null; } }
  }
  acceptPrompt() { const app = this.promptApp; this.promptApp = null; this.clearCard(); if (app) void this.start(app.name); }
  dismissPrompt() { this.promptApp = null; if (this.cardKind === 'detected') this.clearCard(); this.changed(); }

  /** for tests / the self-test: pretend these call apps are using the mic */
  simulateCalls(apps: ActiveCall[]) { this.appsChanged(apps); }

  // ── hub view ──
  listItem(m: Meeting): MeetingListItem {
    const del = deletionDate(m, this.settings.retentionDays);
    return {
      id: m.id, title: m.title, date: m.date, duration: m.id === this.rec?.id ? (this.now() - this.rec.startedAt) / 1000 : m.duration, app: m.app, source: m.source,
      status: m.status, progressNote: this.summarizing.has(m.id) ? 'summarizing' : m.progressNote, progress: m.progress, keep: m.keep === true,
      deletesAt: del ? del.toISOString() : null, speakers: speakerKeys(m).length, words: m.segments.reduce((n, s) => n + wordsIn(s.text), 0),
      hasSummary: !!m.summary, damaged: !!m.damaged,
      haystack: (m.title + '\n' + (m.summary ?? '') + '\n' + m.segments.map((s) => s.text).join(' ')).toLowerCase(),
    };
  }

  hubState(): MeetingHubState {
    return {
      meetings: this.store.meetings.map((m) => this.listItem(m)),
      recording: this.rec ? { id: this.rec.id, startedAt: new Date(this.rec.startedAt).toISOString(), system: this.store.get(this.rec.id)?.tracks.system ?? false } : null,
      prompt: this.promptApp ? { app: this.promptApp.name } : null,
      importing: this.importing,
      claude: !!this.claude(),
      ffmpeg: this.ffmpeg(),
      diarization: this.diar,
      settings: this.settings,
      platform: this.d.platform,
    };
  }

  get(id: string): Meeting | undefined { return this.store.get(id); }
}

export type { Turn };
