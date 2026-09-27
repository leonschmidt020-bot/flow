import type { Settings } from './settings';

export interface HistoryItem { id: string; date: string; text: string; app: string; words: number; durationSec: number }
export interface AsrView {
  model: string; status: 'missing' | 'downloading' | 'verifying' | 'extracting' | 'loading' | 'ready' | 'error';
  progress: number; bytesPerSec: number; error: string; installed: Record<string, boolean>;
}
export interface HubState {
  settings: Settings;
  history: HistoryItem[];
  totalDictations: number;
  wordsToday: number;
  wordsTotal: number;
  asr: AsrView;
  micError: string;
  version: string;
  platform: string;
  paused: boolean;
  hotkeysDisabled: boolean;
}
