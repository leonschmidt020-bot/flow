// Notetaker settings – kept in their own file (userData/meetings/settings.json) so the dictation settings schema stays
// untouched. Pure (shared with the renderer), validated like the main settings.

export type DetectionMode = 'off' | 'ask' | 'auto';

export interface MeetingSettings {
  version: 1;
  /**
   * Call detection. Default „ask“ (like the Mac app): Flow only looks at which apps Windows reports as using the
   * microphone (local registry, no network, no screen) and then *asks* with a card – it never records on its own.
   */
  detection: DetectionMode;
  /** record the other side via system-audio loopback (otherwise microphone only) */
  systemAudio: boolean;
  /** keep the WAV tracks after the transcript is done (deleted with the meeting after the retention period) */
  keepAudio: boolean;
  /** meetings are deleted after N days unless „Behalten“; 0 = never */
  retentionDays: number;
  /** shown for the own microphone track instead of „Ich“ */
  myName: string;
  /** summary via a local `claude` CLI right after processing (off by default: it sends the transcript to your Claude account) */
  autoSummary: boolean;
  /** Ctrl+Alt+M starts/stops a recording */
  hotkey: boolean;
  /** optional explicit ffmpeg.exe; empty = ffmpeg from PATH */
  ffmpegPath: string;
}

export const MEETING_DEFAULTS: MeetingSettings = {
  version: 1,
  detection: 'ask',
  systemAudio: true,
  keepAudio: true,
  retentionDays: 3,
  myName: '',
  autoSummary: false,
  hotkey: true,
  ffmpegPath: '',
};

export const RETENTION_CHOICES = [1, 3, 7, 14, 30, 0] as const;

const bool = (v: unknown, d: boolean) => (typeof v === 'boolean' ? v : d);

export function migrateMeetingSettings(raw: unknown): MeetingSettings {
  const r = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const days = typeof r.retentionDays === 'number' && Number.isFinite(r.retentionDays) ? Math.round(r.retentionDays) : MEETING_DEFAULTS.retentionDays;
  return {
    version: 1,
    detection: r.detection === 'off' || r.detection === 'ask' || r.detection === 'auto' ? r.detection : MEETING_DEFAULTS.detection,
    systemAudio: bool(r.systemAudio, MEETING_DEFAULTS.systemAudio),
    keepAudio: bool(r.keepAudio, MEETING_DEFAULTS.keepAudio),
    retentionDays: Math.min(3650, Math.max(0, days)),
    myName: typeof r.myName === 'string' ? r.myName.trim().slice(0, 60) : '',
    autoSummary: bool(r.autoSummary, MEETING_DEFAULTS.autoSummary),
    hotkey: bool(r.hotkey, MEETING_DEFAULTS.hotkey),
    ffmpegPath: typeof r.ffmpegPath === 'string' ? r.ffmpegPath.trim().slice(0, 1000) : '',
  };
}
