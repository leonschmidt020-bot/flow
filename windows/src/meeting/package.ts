// „Prompt für Agent“ – the context package for a coding/chat agent (port of MCPackage.swift, Mac 1.7.15 layout):
//
// <meeting>\Kontext-Paket\
//   transkript.md  the COMPLETE transcript (times, speakers), its own file so an agent reliably reads all of it;
//                  ends with „— Ende des Transkripts —“
//   meeting.md     overview: title, date, participants, summary, file list (+ path of the original audio)
// (bilder.md / bilder\ exist on the Mac only – Windows Flow does not capture the screen.)
// Rebuilt on every click so the paths in the prompt are always right; lives in the meeting folder and disappears with it.
import { mkdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import nodePath from 'node:path';
import { duration, longDate, speakerKeys, speakerName, stamp, wordsIn, type Loc } from './format';
import { MIC_FILE, PACKAGE_DIR, SYSTEM_FILE, type Meeting } from './types';

export const TRANSCRIPT_FILE = 'transkript.md';
export const OVERVIEW_FILE = 'meeting.md';
export const END_MARK: Record<Loc, string> = { de: '— Ende des Transkripts —', en: '— End of transcript —' };

export interface PackageOptions {
  loc?: Loc;
  myName?: string;
  timeZone?: string;
  /** path flavour of the target OS (tests build Windows paths on macOS) */
  pathApi?: typeof nodePath;
}

export interface PackageResult {
  dir: string;
  files: { transcript: string; overview: string };
  segments: number;
  words: number;
  transcriptLines: number;
  /** original recording(s): imported file or the kept WAV tracks */
  audio: string[];
}

export interface PackageContents { result: PackageResult; transcript: string; overview: string }

/** where the original audio is (imported file → its own path; recording → kept WAVs that exist) */
export function audioFiles(m: Meeting, folder: string, exists: (p: string) => boolean = existsSync, P: typeof nodePath = nodePath): string[] {
  if (m.source === 'import') return m.sourcePath ? [m.sourcePath] : [];
  return [MIC_FILE, SYSTEM_FILE].map((f) => P.join(folder, f)).filter(exists);
}

export function buildPackageContents(m: Meeting, folder: string, audio: string[], o: PackageOptions = {}): PackageContents {
  const loc = o.loc ?? 'de';
  const P = o.pathApi ?? nodePath;
  const dir = P.join(folder, PACKAGE_DIR);
  const transcript = transcriptMd(m, loc, o.myName ?? '');
  const result: PackageResult = {
    dir,
    files: { transcript: P.join(dir, TRANSCRIPT_FILE), overview: P.join(dir, OVERVIEW_FILE) },
    segments: m.segments.length,
    words: m.segments.reduce((n, s) => n + wordsIn(s.text), 0),
    transcriptLines: transcript.split('\n').length,
    audio,
  };
  return { result, transcript, overview: overviewMd(m, result, loc, o) };
}

/** build and write the package (the folder is replaced every time) */
export function writePackage(m: Meeting, folder: string, o: PackageOptions = {}): PackageResult {
  const c = buildPackageContents(m, folder, audioFiles(m, folder), o);
  rmSync(c.result.dir, { recursive: true, force: true });
  mkdirSync(c.result.dir, { recursive: true, mode: 0o700 });
  writeFileSync(c.result.files.transcript, c.transcript, { encoding: 'utf8', mode: 0o600 });
  writeFileSync(c.result.files.overview, c.overview, { encoding: 'utf8', mode: 0o600 });
  return c.result;
}

function people(m: Meeting, loc: Loc, myName: string): string[] {
  return speakerKeys(m).map((k) => speakerName(m, k, myName, loc));
}

function appLabel(m: Meeting, loc: Loc): string | null {
  if (m.source === 'import') return loc === 'de' ? 'importierte Audiodatei' : 'imported audio file';
  return m.app && m.app.trim() ? m.app : null;
}

export function transcriptMd(m: Meeting, loc: Loc = 'de', myName = ''): string {
  const ppl = people(m, loc, myName);
  const de = loc === 'de';
  let s = `# ${m.title} – ${de ? 'vollständiges Transkript' : 'complete transcript'}\n\n`;
  s += de ? `> ${m.segments.length} Abschnitte · Zeiten [mm:ss] ab Meeting-Beginn` : `> ${m.segments.length} segments · times [mm:ss] from the start of the meeting`;
  s += ppl.length ? ` · ${de ? 'Sprecher' : 'Speakers'}: ${ppl.join(', ')}` : '';
  s += '\n\n';
  for (const seg of m.segments) s += `[${stamp(seg.start)}] **${speakerName(m, seg.speaker, myName, loc)}:** ${seg.text}\n\n`;
  if (m.segments.length === 0) s += de ? '_(kein Transkript vorhanden)_\n' : '_(no transcript)_\n';
  s += `\n${END_MARK[loc]}\n`;
  return s;
}

function overviewMd(m: Meeting, r: PackageResult, loc: Loc, o: PackageOptions): string {
  const de = loc === 'de';
  const ppl = people(m, loc, o.myName ?? '');
  let s = `# ${m.title}\n\n`;
  s += de ? '> Meeting-Paket aus Flow (lokal). Zeiten [mm:ss] zählen ab Meeting-Beginn.\n\n' : '> Meeting package from Flow (local). Times [mm:ss] count from the start of the meeting.\n\n';
  s += `- **${de ? 'Datum' : 'Date'}:** ${longDate(m.date, loc, o.timeZone)}\n`;
  s += `- **${de ? 'Dauer' : 'Duration'}:** ${duration(m.duration, loc)}\n`;
  const app = appLabel(m, loc);
  if (app) s += `- **App:** ${app}\n`;
  if (ppl.length) s += `- **${de ? 'Teilnehmer' : 'Participants'}:** ${ppl.join(', ')}\n`;
  s += `\n## ${de ? 'Dateien in diesem Paket' : 'Files in this package'}\n\n`;
  s += de
    ? `- \`${TRANSCRIPT_FILE}\` – **das vollständige Transkript**: ${r.segments} Abschnitte, ca. ${r.words} Wörter, ${r.transcriptLines} Zeilen\n`
    : `- \`${TRANSCRIPT_FILE}\` – **the complete transcript**: ${r.segments} segments, about ${r.words} words, ${r.transcriptLines} lines\n`;
  for (const a of r.audio) s += `- ${de ? 'Originalaufnahme' : 'Original recording'}: \`${a}\`\n`;
  s += '\n';
  if (m.summary && m.summary.trim()) s += `## ${de ? 'Zusammenfassung' : 'Summary'}\n\n${m.summary.trim()}\n\n`;
  s += `---\n\n${de ? 'Das vollständige Transkript steht in' : 'The complete transcript is in'} \`${TRANSCRIPT_FILE}\`.\n`;
  return s;
}

/** the text that goes to the clipboard – every file with its full path, counts, and the reading order */
export function agentPrompt(m: Meeting, r: PackageResult, o: PackageOptions = {}): string {
  const loc = o.loc ?? 'de';
  const de = loc === 'de';
  const P = o.pathApi ?? nodePath;
  const info = [longDate(m.date, loc, o.timeZone, true)];
  if (m.duration > 0) info.push(duration(m.duration, loc));
  const app = appLabel(m, loc);
  if (app) info.push(app);
  const ppl = people(m, loc, o.myName ?? '');
  let p = de ? `Meeting „${m.title}“ – ${info.join(', ')}` : `Meeting “${m.title}” – ${info.join(', ')}`;
  p += ppl.length ? (de ? `. Teilnehmer: ${ppl.join(', ')}.\n\n` : `. Participants: ${ppl.join(', ')}.\n\n`) : '.\n\n';
  p += de ? `Alle Unterlagen liegen lokal auf diesem PC im Ordner:\n${r.dir}${P.sep}\n\n` : `All material is stored locally on this PC in the folder:\n${r.dir}${P.sep}\n\n`;
  p += de
    ? `- ${r.files.transcript} – das VOLLSTÄNDIGE Transkript mit Zeitstempeln und Sprechern (${r.segments} Abschnitte, ca. ${r.words} Wörter, ${r.transcriptLines} Zeilen, endet mit „${END_MARK.de}“)\n`
    : `- ${r.files.transcript} – the COMPLETE transcript with timestamps and speakers (${r.segments} segments, about ${r.words} words, ${r.transcriptLines} lines, ends with “${END_MARK.en}”)\n`;
  p += de
    ? `- ${r.files.overview} – Überblick: Datum, Teilnehmer, Zusammenfassung, Dateiliste\n`
    : `- ${r.files.overview} – overview: date, participants, summary, file list\n`;
  for (const a of r.audio) p += `- ${de ? 'Originalaufnahme' : 'Original recording'}: ${a}\n`;
  p += de
    ? `\nLies zuerst ${TRANSCRIPT_FILE} KOMPLETT – bei einer langen Datei in mehreren Teilen, bis „${END_MARK.de}“ – dann ${OVERVIEW_FILE}. Bestätige kurz, dass du alles gelesen hast, und warte dann auf meine Aufgabe.`
    : `\nRead ${TRANSCRIPT_FILE} COMPLETELY first – for a long file in several parts, until “${END_MARK.en}” – then ${OVERVIEW_FILE}. Briefly confirm that you have read everything, then wait for my task.`;
  return p;
}
