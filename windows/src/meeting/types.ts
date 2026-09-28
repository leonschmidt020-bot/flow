// Notetaker data model (port of MeetingModel.swift). Pure – shared by main, renderer and tests.

export type MeetingStatus = 'recording' | 'processing' | 'done' | 'failed';
export type MeetingSource = 'recording' | 'import';

/**
 * One transcript line. `speaker`: "me" = own microphone, "S1", "S2", … = diarized speakers,
 * "live" = the other side during the live transcript (before the speakers are separated).
 */
export interface Segment { id: string; speaker: string; start: number; end: number; text: string }

export interface Meeting {
  version: 1;
  /** folder name: yyyy-MM-dd_HHmm_xxxx */
  id: string;
  title: string;
  /** ISO start time */
  date: string;
  /** seconds */
  duration: number;
  /** detected call app (Teams, Zoom …) or null */
  app: string | null;
  source: MeetingSource;
  /** imported file: the original is only referenced, never copied */
  sourcePath?: string;
  status: MeetingStatus;
  progressNote?: string;
  /** 0…1 while processing */
  progress?: number;
  segments: Segment[];
  speakerNames: Record<string, string>;
  summary?: string;
  /** „Behalten“: never deleted automatically */
  keep?: boolean;
  /** which tracks were recorded (ich.wav = microphone, andere.wav = system audio) */
  tracks: { mic: boolean; system: boolean };
  /** meeting.json was unreadable and the entry was rebuilt from the folder – never auto-deleted */
  damaged?: boolean;
}

export interface Word { word: string; start: number; end: number }
export interface Turn { speaker: number | string; start: number; end: number }

export const MIC_FILE = 'ich.wav';
export const SYSTEM_FILE = 'andere.wav';
export const META_FILE = 'meeting.json';
export const PACKAGE_DIR = 'Kontext-Paket';

/** hub list entry + detail (the renderer gets the full meeting only for the selected one) */
export interface MeetingListItem {
  id: string; title: string; date: string; duration: number; app: string | null; source: MeetingSource;
  status: MeetingStatus; progressNote?: string; progress?: number; keep: boolean; deletesAt: string | null;
  speakers: number; words: number; hasSummary: boolean; damaged: boolean;
  /** lower-cased title + transcript + summary, for the search box */
  haystack: string;
}

export interface MeetingHubState {
  meetings: MeetingListItem[];
  recording: { id: string; startedAt: string; system: boolean } | null;
  prompt: { app: string } | null;
  importing: { file: string; progress: number; note: string } | null;
  claude: boolean;
  ffmpeg: string | null;
  diarization: { status: 'missing' | 'downloading' | 'ready' | 'error'; progress: number; error: string };
  settings: import('./settings').MeetingSettings;
  platform: string;
}
