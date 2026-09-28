// „Prompt für Agent“: package layout (Mac 1.7.15), exact file names, counts and full Windows paths in the prompt.
import { describe, expect, it } from 'vitest';
import { mkdtempSync, readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { agentPrompt, audioFiles, buildPackageContents, END_MARK, transcriptMd, writePackage } from '../../src/meeting/package';
import type { Meeting } from '../../src/meeting/types';

const meeting = (over: Partial<Meeting> = {}): Meeting => ({
  version: 1, id: '2026-09-27_1405_AB12', title: 'Wochenplanung', date: '2026-09-27T12:05:00.000Z', duration: 1834, app: 'Microsoft Teams',
  source: 'recording', status: 'done', speakerNames: { S1: 'Alex' }, tracks: { mic: true, system: true },
  segments: [
    { id: 'a', speaker: 'S1', start: 3.2, end: 8, text: 'Guten Morgen zusammen, heute geht es um den Umzug.' },
    { id: 'b', speaker: 'me', start: 9.5, end: 12, text: 'Danke, ich fange mit dem Zeitplan an.' },
    { id: 'c', speaker: 'S2', start: 75, end: 80, text: 'Die Kisten kommen am Montag.' },
  ],
  ...over,
});

const WIN = 'C:\\Users\\Test\\AppData\\Roaming\\Flow\\meetings\\2026-09-27_1405_AB12';

describe('package contents', () => {
  it('transkript.md has every segment with time + speaker and ends with the end mark', () => {
    const tr = transcriptMd(meeting());
    expect(tr.startsWith('# Wochenplanung – vollständiges Transkript\n\n> 3 Abschnitte · Zeiten [mm:ss] ab Meeting-Beginn · Sprecher: Alex, Ich, Sprecher 2\n')).toBe(true);
    expect(tr).toContain('[00:03] **Alex:** Guten Morgen zusammen, heute geht es um den Umzug.');
    expect(tr).toContain('[00:09] **Ich:** Danke, ich fange mit dem Zeitplan an.');
    expect(tr).toContain('[01:15] **Sprecher 2:** Die Kisten kommen am Montag.');
    expect(tr.trimEnd().endsWith('— Ende des Transkripts —')).toBe(true);
    expect(END_MARK.de).toBe('— Ende des Transkripts —');
  });

  it('own name replaces „Ich“, empty transcript is stated', () => {
    expect(transcriptMd(meeting(), 'de', 'Sam')).toContain('**Sam:**');
    expect(transcriptMd(meeting({ segments: [] }))).toContain('_(kein Transkript vorhanden)_');
  });

  it('prompt: folder, every file with its full Windows path, counts, reading order', () => {
    const audio = [`${WIN}\\ich.wav`, `${WIN}\\andere.wav`];
    const c = buildPackageContents(meeting(), WIN, audio, { pathApi: path.win32, timeZone: 'Europe/Berlin' });
    const r = c.result;
    expect(r.dir).toBe(`${WIN}\\Kontext-Paket`);
    expect(r.files.transcript).toBe(`${WIN}\\Kontext-Paket\\transkript.md`);
    expect(r.files.overview).toBe(`${WIN}\\Kontext-Paket\\meeting.md`);
    expect(r.segments).toBe(3);
    expect(r.words).toBe(9 + 7 + 5);
    expect(r.transcriptLines).toBe(c.transcript.split('\n').length);
    const p = agentPrompt(meeting(), r, { pathApi: path.win32, timeZone: 'Europe/Berlin' });
    expect(p).toBe(
      'Meeting „Wochenplanung“ – Sonntag, 27. September 2026, um 14:05, 30 Min., Microsoft Teams. Teilnehmer: Alex, Ich, Sprecher 2.\n\n'
      + `Alle Unterlagen liegen lokal auf diesem PC im Ordner:\n${WIN}\\Kontext-Paket\\\n\n`
      + `- ${WIN}\\Kontext-Paket\\transkript.md – das VOLLSTÄNDIGE Transkript mit Zeitstempeln und Sprechern (3 Abschnitte, ca. 21 Wörter, ${r.transcriptLines} Zeilen, endet mit „— Ende des Transkripts —“)\n`
      + `- ${WIN}\\Kontext-Paket\\meeting.md – Überblick: Datum, Teilnehmer, Zusammenfassung, Dateiliste\n`
      + `- Originalaufnahme: ${WIN}\\ich.wav\n- Originalaufnahme: ${WIN}\\andere.wav\n`
      + '\nLies zuerst transkript.md KOMPLETT – bei einer langen Datei in mehreren Teilen, bis „— Ende des Transkripts —“ – dann meeting.md. '
      + 'Bestätige kurz, dass du alles gelesen hast, und warte dann auf meine Aufgabe.');
  });

  it('meeting.md: overview + file list + summary + pointer to the transcript', () => {
    const c = buildPackageContents(meeting({ summary: '**Kurzfassung** – Umzug am 12. Oktober.' }), WIN, [`${WIN}\\ich.wav`], { pathApi: path.win32, timeZone: 'Europe/Berlin' });
    expect(c.overview).toContain('# Wochenplanung\n\n> Meeting-Paket aus Flow (lokal).');
    expect(c.overview).toContain('- **Datum:** Sonntag, 27. September 2026, 14:05');
    expect(c.overview).toContain('- **Dauer:** 30 Min.');
    expect(c.overview).toContain('- **App:** Microsoft Teams');
    expect(c.overview).toContain('- **Teilnehmer:** Alex, Ich, Sprecher 2');
    expect(c.overview).toContain(`- \`transkript.md\` – **das vollständige Transkript**: 3 Abschnitte, ca. 21 Wörter, ${c.result.transcriptLines} Zeilen`);
    expect(c.overview).toContain(`- Originalaufnahme: \`${WIN}\\ich.wav\``);
    expect(c.overview).toContain('## Zusammenfassung\n\n**Kurzfassung** – Umzug am 12. Oktober.');
    expect(c.overview.trimEnd().endsWith('Das vollständige Transkript steht in `transkript.md`.')).toBe(true);
  });

  it('imported file: the original path is referenced, app says so', () => {
    const m = meeting({ source: 'import', app: null, sourcePath: 'D:\\Aufnahmen\\Interview.m4a' });
    expect(audioFiles(m, WIN, () => true, path.win32)).toEqual(['D:\\Aufnahmen\\Interview.m4a']);
    const c = buildPackageContents(m, WIN, audioFiles(m, WIN, () => true, path.win32), { pathApi: path.win32, timeZone: 'UTC' });
    const p = agentPrompt(m, c.result, { pathApi: path.win32, timeZone: 'UTC' });
    expect(p).toContain('importierte Audiodatei');
    expect(p).toContain('- Originalaufnahme: D:\\Aufnahmen\\Interview.m4a\n');
  });

  it('recording without kept audio lists no original', () => {
    expect(audioFiles(meeting(), WIN, () => false, path.win32)).toEqual([]);
  });

  it('English variant has its own end mark and the same structure', () => {
    const c = buildPackageContents(meeting(), WIN, [], { pathApi: path.win32, loc: 'en', timeZone: 'UTC' });
    expect(c.transcript.trimEnd().endsWith('— End of transcript —')).toBe(true);
    const p = agentPrompt(meeting(), c.result, { pathApi: path.win32, loc: 'en', timeZone: 'UTC' });
    expect(p).toContain(`- ${WIN}\\Kontext-Paket\\transkript.md – the COMPLETE transcript with timestamps and speakers (3 segments, about 21 words, ${c.result.transcriptLines} lines, ends with “— End of transcript —”)`);
    expect(p).toContain('Read transkript.md COMPLETELY first');
    expect(p).toContain('Participants: Alex, Me, Speaker 2.');
  });

  it('writePackage writes exactly transkript.md + meeting.md and replaces an old package', () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'flow-pkg-'));
    mkdirSync(path.join(dir, 'Kontext-Paket'), { recursive: true });
    writeFileSync(path.join(dir, 'Kontext-Paket', 'alt.md'), 'old');
    writeFileSync(path.join(dir, 'ich.wav'), 'RIFF');
    const r = writePackage(meeting(), dir);
    expect(readdirSync(r.dir).sort()).toEqual(['meeting.md', 'transkript.md']);
    expect(readFileSync(r.files.transcript, 'utf8')).toBe(transcriptMd(meeting()));
    expect(r.audio).toEqual([path.join(dir, 'ich.wav')]);
    expect(existsSync(path.join(dir, 'Kontext-Paket', 'alt.md'))).toBe(false);
  });
});

describe('notetaker strings', () => {
  it('German and English have the same keys and placeholders', async () => {
    const { _mdicts } = await import('../../src/meeting/i18n');
    const de = _mdicts.de as Record<string, string>, en = _mdicts.en as Record<string, string>;
    expect(Object.keys(en).sort()).toEqual(Object.keys(de).sort());
    const vars = (s: string) => (s.match(/\{\w+\}/g) ?? []).sort().join();
    for (const k of Object.keys(de)) expect(vars(en[k]!), k).toBe(vars(de[k]!));
  });
});
