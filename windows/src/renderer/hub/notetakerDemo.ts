// Demo data for the offscreen render check of the Notetaker page (neutral names, no personal data).
import { MEETING_DEFAULTS } from '../../meeting/settings';
import type { Meeting, MeetingHubState, MeetingListItem } from '../../meeting/types';
import type { MeetingApi } from './notetaker';

const seg = (speaker: string, start: number, text: string, i: number) => ({ id: `d${i}`, speaker, start, end: start + 6, text });

export function demoMeetings(kind: string): { state: MeetingHubState; meetings: Meeting[] } {
  const now = Date.now();
  const at = (minAgo: number) => new Date(now - minAgo * 60_000).toISOString();
  const lines: [string, number, string][] = [
    ['S1', 4, 'Guten Morgen zusammen. Heute geht es um den Umzug des Büros und den neuen Zeitplan.'],
    ['S2', 12, 'Danke. Der Umzug ist für den 12. Oktober geplant, die Kisten kommen eine Woche vorher.'],
    ['me', 21, 'Wer kümmert sich um die Drucker und das Netzwerk im neuen Gebäude?'],
    ['S2', 27, 'Das übernimmt das Technikteam. Die Leitungen werden am Montag geprüft.'],
    ['S1', 36, 'Und bleiben wir im Budget? Letzte Woche waren die Möbel noch offen.'],
    ['S2', 44, 'Ja, wir liegen etwa fünf Prozent unter der Planung, weil die Möbel günstiger waren.'],
    ['me', 55, 'Sehr gut. Dann schicke ich heute Nachmittag die Einladung für die nächste Besprechung.'],
    ['S1', 63, 'Perfekt, bis dahin sammle ich die offenen Fragen aus dem Team.'],
  ];
  const meetings: Meeting[] = [
    { version: 1, id: 'm1', title: 'Büro-Umzug · Planung', date: at(35), duration: 1834, app: 'Microsoft Teams', source: 'recording', status: 'done',
      segments: lines.map(([s, t, x], i) => seg(s, t, x, i)), speakerNames: { S1: 'Alex' }, tracks: { mic: true, system: true },
      summary: '**Kurzfassung** – Der Umzug findet am 12. Oktober statt, das Budget wird eingehalten.\n**Aufgaben**\n- Technikteam: Leitungen prüfen (Montag)\n- Ich: Einladung verschicken (heute)' },
    { version: 1, id: 'm2', title: 'Interview_Aufnahme', date: at(80), duration: 2710, app: null, source: 'import', sourcePath: 'C:\\Users\\Demo\\Music\\Interview_Aufnahme.m4a', status: 'processing', progress: 0.62,
      progressNote: 'transcribeRoom', segments: [], speakerNames: {}, tracks: { mic: false, system: false } },
    { version: 1, id: 'm3', title: 'Release-Abstimmung', date: at(60 * 26), duration: 912, app: 'Zoom', source: 'recording', status: 'done', keep: true,
      segments: [seg('S1', 2, 'Kurzes Update zum Release: alle Tests sind grün.', 1), seg('me', 9, 'Super, dann veröffentlichen wir morgen früh.', 2)], speakerNames: {}, tracks: { mic: true, system: true } },
    { version: 1, id: 'm4', title: 'Kurze Notiz', date: at(60 * 49), duration: 45, app: null, source: 'recording', status: 'failed', progressNote: 'interrupted',
      segments: [], speakerNames: {}, tracks: { mic: true, system: false } },
  ];
  const list = kind === 'empty' ? [] : meetings;
  const item = (m: Meeting): MeetingListItem => ({
    id: m.id, title: m.title, date: m.date, duration: m.duration, app: m.app, source: m.source, status: m.status, progressNote: m.progressNote, progress: m.progress,
    keep: !!m.keep, deletesAt: m.keep ? null : new Date(Date.parse(m.date) + 3 * 86400_000).toISOString(), speakers: new Set(m.segments.map((s) => s.speaker)).size,
    words: m.segments.reduce((n, s) => n + s.text.split(/\s+/).length, 0), hasSummary: !!m.summary, damaged: false,
    haystack: (m.title + ' ' + m.segments.map((s) => s.text).join(' ')).toLowerCase(),
  });
  const recording = kind === 'recording';
  const state: MeetingHubState = {
    meetings: (recording ? [{ ...meetings[0]!, id: 'live', title: 'Teams-Meeting · jetzt', status: 'recording' as const, date: at(12), summary: undefined }, ...list] : list).map(item),
    recording: recording ? { id: 'live', startedAt: at(12.05), system: true } : null,
    prompt: null,
    importing: kind === 'ready' ? { file: 'Interview_Aufnahme.m4a', progress: 0.62, note: 'transcribeRoom' } : null,
    claude: true, ffmpeg: null,
    diarization: { status: 'ready', progress: 1, error: '' },
    settings: { ...MEETING_DEFAULTS, myName: '' },
    platform: 'win32',
  };
  if (recording) meetings.unshift({ ...meetings[0]!, id: 'live', title: 'Teams-Meeting · jetzt', status: 'recording', summary: undefined, speakerNames: {},
    segments: lines.slice(0, 5).map(([s, t, x], i) => seg(s === 'me' ? 'me' : 'live', t, x, i)) });
  return { state, meetings };
}

export function demoMeetingApi(kind: string): MeetingApi {
  const d = demoMeetings(kind);
  const noop = async () => {};
  return {
    state: async () => d.state, get: async (id) => d.meetings.find((m) => m.id === id) ?? null,
    start: noop, stop: noop, pickFile: noop, dropFiles: noop, rename: noop, renameSpeaker: noop, setKeep: noop, delete: noop, reprocess: noop,
    summarize: noop, copyPrompt: async () => ({ ok: true }), copyTranscript: async () => true, openFolder: noop,
    setSettings: async (p) => ({ ...d.state.settings, ...p }), onState: () => () => {},
  };
}
