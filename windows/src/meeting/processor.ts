// After the meeting: separate speakers + transcribe with word times (port of MeetingProcessor.process).
//   online call  (system track has > 4 s speech): diarize the system track → S1, S2, …; own microphone → "me",
//                minus echo (mic without headphones hears the others)
//   in person / imported file (only one track): diarize that track
// Everything local. Dependencies are injected so the logic is unit-testable without models.
import type { Segment, Turn, Word } from './types';
import { assignWords, groupWords, mergeAdjacent, removeEcho, speechSeconds } from './merge';

export interface ProcessDeps {
  transcribe(samples: Float32Array, onProgress: (p: number) => void): Promise<Word[]>;
  diarize(samples: Float32Array, onProgress: (p: number) => void): Promise<Turn[]>;
  /** fillers / dictionary (TextCleaner.applyRules) */
  clean(text: string): string;
  /** progress note for the UI */
  note(key: ProcessStep, progress: number): void;
}

export type ProcessStep = 'diarizeOthers' | 'transcribeOthers' | 'transcribeMe' | 'diarizeRoom' | 'transcribeRoom';

export interface Tracks {
  /** own microphone (recording) or the imported file */
  mic?: () => Float32Array;
  /** system audio (the other side of a call) */
  system?: () => Float32Array;
}

/** tracks are loaded lazily and one after the other (a 1 h track is ~230 MB as float) */
export async function processTracks(tracks: Tracks, d: ProcessDeps): Promise<Segment[]> {
  let segments: Segment[] = [];
  let sys: Float32Array | null = tracks.system ? tracks.system() : null;
  const online = !!sys && speechSeconds(sys) > 4;
  if (online && sys) {
    d.note('diarizeOthers', 0);
    const turns = await d.diarize(sys, (p) => d.note('diarizeOthers', p));
    d.note('transcribeOthers', 0);
    const words = await d.transcribe(sys, (p) => d.note('transcribeOthers', p));
    segments = assignWords(words, turns, d.clean);
  }
  sys = null;
  const mic = tracks.mic ? tracks.mic() : null;
  if (mic && speechSeconds(mic) > 1) {
    if (online) {
      d.note('transcribeMe', 0);
      const words = await d.transcribe(mic, (p) => d.note('transcribeMe', p));
      segments = segments.concat(removeEcho(groupWords(words, 'me', d.clean), segments));
    } else {
      d.note('diarizeRoom', 0);
      const turns = await d.diarize(mic, (p) => d.note('diarizeRoom', p));
      d.note('transcribeRoom', 0);
      const words = await d.transcribe(mic, (p) => d.note('transcribeRoom', p));
      segments = assignWords(words, turns, d.clean);
    }
  }
  return mergeAdjacent(segments.sort((a, b) => a.start - b.start));
}
