// Meetings on disk: userData/meetings/<id>/meeting.json (atomic write + last-good .bak) + the audio tracks.
// Retention like the Mac (MeetingStore.cleanup): meetings older than N days are deleted for good unless „Behalten“,
// never while recording/processing; folders without meeting.json (aborted recordings) are removed by folder age;
// a folder whose meeting.json exists but is unreadable is shown as damaged and NEVER deleted automatically.
import { existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { readJsonSafe, writeJsonAtomic } from '../main/store';
import { META_FILE, MIC_FILE, SYSTEM_FILE, type Meeting, type MeetingStatus, type Segment } from './types';

const STATUSES: MeetingStatus[] = ['recording', 'processing', 'done', 'failed'];

/** validate whatever was on disk into a Meeting (null if it is not one) */
export function sanitizeMeeting(v: unknown, id: string): Meeting | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const r = v as Record<string, unknown>;
  if (typeof r.date !== 'string' || Number.isNaN(Date.parse(r.date))) return null;
  const segs: Segment[] = Array.isArray(r.segments) ? r.segments.filter((s): s is Segment => !!s && typeof s === 'object'
    && typeof (s as Segment).text === 'string' && typeof (s as Segment).start === 'number').map((s, i) => ({
    id: String(s.id ?? `s${i}`), speaker: String(s.speaker ?? 'S1'), start: Number(s.start) || 0,
    end: Number.isFinite(Number(s.end)) ? Number(s.end) : Number(s.start) || 0, text: s.text,
  })) : [];
  const names: Record<string, string> = {};
  if (r.speakerNames && typeof r.speakerNames === 'object') for (const [k, n] of Object.entries(r.speakerNames as Record<string, unknown>)) if (typeof n === 'string' && n.trim()) names[k] = n.slice(0, 80);
  const tracks = (r.tracks && typeof r.tracks === 'object' ? r.tracks : {}) as Record<string, unknown>;
  return {
    version: 1,
    id,
    title: typeof r.title === 'string' && r.title.trim() ? r.title.slice(0, 200) : 'Meeting',
    date: r.date,
    duration: Math.max(0, Number(r.duration) || 0),
    app: typeof r.app === 'string' ? r.app : null,
    source: r.source === 'import' ? 'import' : 'recording',
    sourcePath: typeof r.sourcePath === 'string' ? r.sourcePath : undefined,
    status: STATUSES.includes(r.status as MeetingStatus) ? (r.status as MeetingStatus) : 'done',
    progressNote: typeof r.progressNote === 'string' ? r.progressNote : undefined,
    segments: segs.sort((a, b) => a.start - b.start),
    speakerNames: names,
    summary: typeof r.summary === 'string' ? r.summary : undefined,
    keep: r.keep === true ? true : undefined,
    tracks: { mic: tracks.mic === true, system: tracks.system === true },
  };
}

/** when a meeting is deleted automatically (null = never) */
export function deletionDate(m: Pick<Meeting, 'date' | 'keep' | 'damaged'>, retentionDays: number): Date | null {
  if (retentionDays <= 0 || m.keep === true || m.damaged) return null;
  return new Date(Date.parse(m.date) + retentionDays * 86400_000);
}

export function isExpired(m: Meeting, retentionDays: number, now = Date.now()): boolean {
  if (m.status === 'recording' || m.status === 'processing') return false;
  const d = deletionDate(m, retentionDays);
  return !!d && d.getTime() < now;
}

export class MeetingStore {
  meetings: Meeting[] = [];
  /** ids that must not be touched by crash recovery (the recording/processing ones of this session) */
  readonly active = new Set<string>();
  constructor(readonly root: string) {}

  folder(id: string) { return path.join(this.root, id); }
  file(id: string) { return path.join(this.folder(id), META_FILE); }

  /** read all meetings; interrupted recordings/processing become „failed“ (can be re-processed) */
  load(): Meeting[] {
    mkdirSync(this.root, { recursive: true });
    const list: Meeting[] = [];
    for (const id of safeDirs(this.root)) {
      const f = this.file(id);
      if (!existsSync(f) && !existsSync(f + '.bak')) continue; // orphan → cleanup decides by age
      const r = readJsonSafe<unknown>(f, () => null);
      let m = r.value === null ? null : sanitizeMeeting(r.value, id);
      if (!m) m = this.rebuildDamaged(id);
      if ((m.status === 'recording' || m.status === 'processing') && !this.active.has(id)) {
        m.status = 'failed';
        m.progressNote = 'interrupted';
        m.progress = undefined;
        if (!m.damaged) this.write(m);
      }
      list.push(m);
    }
    this.meetings = list.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
    return this.meetings;
  }

  /** meeting.json and .bak unreadable – keep the folder, show it, never auto-delete */
  private rebuildDamaged(id: string): Meeting {
    const dir = this.folder(id);
    let date = new Date();
    try { date = statSync(dir).mtime; } catch { /* */ }
    return {
      version: 1, id, title: 'Meeting', date: date.toISOString(), duration: 0, app: null, source: 'recording', status: 'failed',
      progressNote: 'damaged', segments: [], speakerNames: {}, damaged: true,
      tracks: { mic: existsSync(path.join(dir, MIC_FILE)), system: existsSync(path.join(dir, SYSTEM_FILE)) },
    };
  }

  get(id: string) { return this.meetings.find((m) => m.id === id); }

  private write(m: Meeting) {
    const { damaged: _d, progress: _p, ...rest } = m;
    writeJsonAtomic(this.file(m.id), rest);
  }

  /** persist (atomic) + update the in-memory list */
  save(m: Meeting) {
    mkdirSync(this.folder(m.id), { recursive: true });
    const clean = { ...m, damaged: undefined };
    this.write(clean);
    this.upsert(clean);
  }

  /** memory only (live transcript while recording – saved at checkpoints) */
  upsert(m: Meeting) {
    const i = this.meetings.findIndex((x) => x.id === m.id);
    if (i >= 0) this.meetings[i] = m; else this.meetings.unshift(m);
    this.meetings.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
  }

  update(id: string, patch: Partial<Meeting>): Meeting | undefined {
    const m = this.get(id);
    if (!m) return undefined;
    const next = { ...m, ...patch };
    this.save(next);
    return next;
  }

  /** deleted for good (privacy), like the automatic cleanup */
  delete(id: string) {
    if (!/^[\w.-]+$/.test(id)) return;
    rmSync(this.folder(id), { recursive: true, force: true });
    this.meetings = this.meetings.filter((m) => m.id !== id);
  }

  /** retention: returns the ids that were removed */
  cleanup(retentionDays: number, now = Date.now()): string[] {
    const removed: string[] = [];
    for (const m of [...this.meetings]) {
      if (this.active.has(m.id) || !isExpired(m, retentionDays, now)) continue;
      this.delete(m.id);
      removed.push(m.id);
    }
    if (retentionDays > 0) {
      const cutoff = now - retentionDays * 86400_000;
      const known = new Set(this.meetings.map((m) => m.id));
      for (const id of safeDirs(this.root)) {
        if (known.has(id) || this.active.has(id)) continue;
        const dir = this.folder(id);
        // a meeting.json (even unreadable) means: not a leftover – never delete it unasked
        if (existsSync(path.join(dir, META_FILE)) || existsSync(path.join(dir, META_FILE + '.bak'))) continue;
        let mod = now;
        try { mod = statSync(dir).mtimeMs; } catch { /* */ }
        if (mod < cutoff) { rmSync(dir, { recursive: true, force: true }); removed.push(id); }
      }
    }
    return removed;
  }
}

function safeDirs(root: string): string[] {
  try {
    return readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory() && /^[\w.-]+$/.test(d.name)).map((d) => d.name);
  } catch { return []; }
}
