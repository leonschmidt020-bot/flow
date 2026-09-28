// Formatting helpers shared by the package builder, the hub and the pill. Pure.
import type { Meeting } from './types';

export type Loc = 'de' | 'en';

/** [mm:ss] or h:mm:ss (Meeting.stamp in the Mac app) */
export function stamp(t: number): string {
  const s = Math.max(0, Math.floor(t));
  const p = (n: number) => String(n).padStart(2, '0');
  return s >= 3600 ? `${Math.floor(s / 3600)}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}` : `${p(Math.floor(s / 60))}:${p(s % 60)}`;
}

/** „45 Sek.“, „12 Min.“, „1 Std. 5 Min.“ (HubNoteDetail.duration) */
export function duration(sec: number, loc: Loc = 'de'): string {
  const t = Math.round(Math.max(0, sec));
  if (loc === 'en') {
    if (t < 60) return `${t} sec`;
    if (t < 3600) return `${Math.floor(t / 60)} min`;
    return `${Math.floor(t / 3600)} h ${Math.floor(t / 60) % 60} min`;
  }
  if (t < 60) return `${t} Sek.`;
  if (t < 3600) return `${Math.floor(t / 60)} Min.`;
  return `${Math.floor(t / 3600)} Std. ${Math.floor(t / 60) % 60} Min.`;
}

/** elapsed clock for the pill: 12:03 / 1:02:03 */
export function clock(sec: number): string { return stamp(sec); }

export function speakerName(m: Pick<Meeting, 'speakerNames'>, key: string, myName = '', loc: Loc = 'de'): string {
  const n = m.speakerNames[key];
  if (n && n.trim()) return n.trim();
  if (key === 'me') return myName.trim() || (loc === 'de' ? 'Ich' : 'Me');
  if (key === 'live') return loc === 'de' ? 'Teilnehmer' : 'Participants';
  const k = /^S(\d+)$/.exec(key);
  if (k) return `${loc === 'de' ? 'Sprecher' : 'Speaker'} ${k[1]}`;
  return key;
}

/** speaker keys in order of first appearance */
export function speakerKeys(m: Pick<Meeting, 'segments'>): string[] {
  const seen: string[] = [];
  for (const s of m.segments) if (!seen.includes(s.speaker)) seen.push(s.speaker);
  return seen;
}

export const wordsIn = (s: string) => s.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;

/** „Sonntag, 27. September 2026, 14:05“ / „Sunday, 27 September 2026, 14:05“ */
export function longDate(iso: string, loc: Loc = 'de', timeZone?: string, withAt = false): string {
  const d = new Date(iso);
  const day = new Intl.DateTimeFormat(loc === 'de' ? 'de-DE' : 'en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone }).format(d);
  const time = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit', timeZone }).format(d);
  return withAt ? `${day}, ${loc === 'de' ? 'um' : 'at'} ${time}` : `${day}, ${time}`;
}

/** „27. Sep., 14:05“ – default title suffix */
export function shortDate(d: Date, loc: Loc = 'de'): string {
  const day = new Intl.DateTimeFormat(loc === 'de' ? 'de-DE' : 'en-GB', { day: 'numeric', month: 'short' }).format(d);
  const time = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit' }).format(d);
  return `${day}, ${time}`;
}

/** yyyy-MM-dd_HHmm_xxxx in local time */
export function meetingId(d: Date, rand: string): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}_${rand.replace(/[^a-zA-Z0-9]/g, '').slice(0, 4).toUpperCase()}`;
}

/** transcript as plain text (copy button, Claude input) */
export function transcriptText(m: Meeting, myName = '', loc: Loc = 'de', withTimes = true): string {
  return m.segments.map((s) => (withTimes ? `[${stamp(s.start)}] ` : '') + `${speakerName(m, s.speaker, myName, loc)}: ${s.text}`).join('\n');
}
