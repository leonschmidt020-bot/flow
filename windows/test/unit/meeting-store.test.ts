// Meeting store: atomic JSON, corruption recovery, crash recovery, retention (3 days unless „Behalten“).
import { beforeEach, describe, expect, it } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, utimesSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { deletionDate, isExpired, MeetingStore, sanitizeMeeting } from '../../src/meeting/store';
import { migrateMeetingSettings, MEETING_DEFAULTS } from '../../src/meeting/settings';
import type { Meeting } from '../../src/meeting/types';

const DAY = 86400_000;
const NOW = Date.parse('2026-09-28T12:00:00Z');
let root = '';
beforeEach(() => { root = mkdtempSync(path.join(os.tmpdir(), 'flow-meetings-')); });

const mk = (id: string, daysAgo: number, over: Partial<Meeting> = {}): Meeting => ({
  version: 1, id, title: id, date: new Date(NOW - daysAgo * DAY).toISOString(), duration: 60, app: null, source: 'recording', status: 'done',
  segments: [{ id: 'x', speaker: 'S1', start: 0, end: 1, text: 'Hallo' }], speakerNames: {}, tracks: { mic: true, system: false }, ...over,
});

describe('retention', () => {
  it('deletion date = date + days; never for kept, damaged or retention 0', () => {
    const m = mk('a', 0);
    expect(deletionDate(m, 3)!.getTime()).toBe(Date.parse(m.date) + 3 * DAY);
    expect(deletionDate({ ...m, keep: true }, 3)).toBeNull();
    expect(deletionDate({ ...m, damaged: true }, 3)).toBeNull();
    expect(deletionDate(m, 0)).toBeNull();
  });
  it('expired only when done/failed and past the date', () => {
    expect(isExpired(mk('a', 2.9), 3, NOW)).toBe(false);
    expect(isExpired(mk('a', 3.1), 3, NOW)).toBe(true);
    expect(isExpired(mk('a', 10, { status: 'processing' }), 3, NOW)).toBe(false);
    expect(isExpired(mk('a', 10, { status: 'recording' }), 3, NOW)).toBe(false);
    expect(isExpired(mk('a', 10, { status: 'failed' }), 3, NOW)).toBe(true);
    expect(isExpired(mk('a', 10, { keep: true }), 3, NOW)).toBe(false);
  });
  it('cleanup deletes expired meetings for good, keeps „Behalten“ and fresh ones', () => {
    const s = new MeetingStore(root);
    s.save(mk('old', 5)); s.save(mk('kept', 30, { keep: true })); s.save(mk('fresh', 1));
    writeFileSync(path.join(s.folder('old'), 'ich.wav'), 'x');
    s.load();
    expect(s.cleanup(3, NOW).sort()).toEqual(['old']);
    expect(existsSync(s.folder('old'))).toBe(false);
    expect(s.meetings.map((m) => m.id).sort()).toEqual(['fresh', 'kept']);
    // retention 0 = forever
    s.save(mk('ancient', 400));
    expect(s.cleanup(0, NOW)).toEqual([]);
  });
  it('active (recording/processing this session) meetings are never removed', () => {
    const s = new MeetingStore(root);
    s.save(mk('busy', 9));
    s.active.add('busy');
    expect(s.cleanup(3, NOW)).toEqual([]);
  });
  it('orphan folders (no meeting.json) go by folder age; folders with an unreadable meeting.json stay', () => {
    const s = new MeetingStore(root);
    const orphanOld = path.join(root, 'orphan_old'), orphanNew = path.join(root, 'orphan_new'), broken = path.join(root, 'broken');
    for (const d of [orphanOld, orphanNew, broken]) mkdirSync(d, { recursive: true });
    writeFileSync(path.join(broken, 'meeting.json'), '{ nope');
    const old = new Date(NOW - 10 * DAY);
    utimesSync(orphanOld, old, old); utimesSync(broken, old, old);
    s.load();
    s.cleanup(3, NOW);
    expect(existsSync(orphanOld)).toBe(false);
    expect(existsSync(orphanNew)).toBe(true);
    expect(existsSync(broken)).toBe(true);
  });
});

describe('store corruption + crash recovery', () => {
  it('atomic save keeps the last good copy; a corrupt meeting.json falls back to .bak', () => {
    const s = new MeetingStore(root);
    s.save(mk('m', 0, { title: 'Erste Fassung' }));
    s.save(mk('m', 0, { title: 'Zweite Fassung' }));
    writeFileSync(s.file('m'), '{"title": "kaputt');
    const t = new MeetingStore(root);
    t.load();
    expect(t.get('m')!.title).toBe('Erste Fassung');
    expect(t.get('m')!.damaged).toBeUndefined();
  });
  it('both copies unreadable → shown as damaged (failed), folder + audio kept, never auto-deleted', () => {
    const s = new MeetingStore(root);
    const dir = path.join(root, '2026-09-20_0900_ZZZZ');
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, 'meeting.json'), 'garbage');
    writeFileSync(path.join(dir, 'meeting.json.bak'), 'more garbage');
    writeFileSync(path.join(dir, 'ich.wav'), 'RIFF');
    s.load();
    const m = s.get('2026-09-20_0900_ZZZZ')!;
    expect(m.damaged).toBe(true);
    expect(m.status).toBe('failed');
    expect(m.progressNote).toBe('damaged');
    expect(m.tracks.mic).toBe(true);
    expect(s.cleanup(1, NOW + 100 * DAY)).toEqual([]);
    expect(readFileSync(path.join(dir, 'meeting.json'), 'utf8')).toBe('garbage'); // not overwritten
  });
  it('a meeting left in „recording“/„processing“ by a crash becomes failed/interrupted (persisted)', () => {
    const s = new MeetingStore(root);
    s.save(mk('crash', 0, { status: 'recording', segments: [] }));
    s.save(mk('half', 0, { status: 'processing' }));
    const t = new MeetingStore(root);
    t.load();
    expect(t.get('crash')!.status).toBe('failed');
    expect(t.get('crash')!.progressNote).toBe('interrupted');
    expect(JSON.parse(readFileSync(t.file('half'), 'utf8')).status).toBe('failed');
  });
  it('sanitize: garbage fields are repaired, non-meetings rejected', () => {
    expect(sanitizeMeeting(null, 'x')).toBeNull();
    expect(sanitizeMeeting({ title: 'no date' }, 'x')).toBeNull();
    const m = sanitizeMeeting({ date: '2026-09-27T10:00:00Z', status: 'weird', segments: [{ text: 'a', start: 2 }, { nope: 1 }, { text: 'b', start: 1, end: 'x' }], speakerNames: { S1: 3, S2: 'Kim' } }, 'id1')!;
    expect(m.status).toBe('done');
    expect(m.segments.map((s) => s.text)).toEqual(['b', 'a']);
    expect(m.segments[0]!.end).toBe(1);
    expect(m.speakerNames).toEqual({ S2: 'Kim' });
    expect(m.title).toBe('Meeting');
  });
  it('delete refuses path tricks', () => {
    const s = new MeetingStore(root);
    mkdirSync(path.join(root, '..', 'keepme-' + path.basename(root)), { recursive: true });
    s.delete('../keepme-' + path.basename(root));
    expect(existsSync(path.join(root, '..', 'keepme-' + path.basename(root)))).toBe(true);
  });
});

describe('notetaker settings', () => {
  it('defaults: ask, system audio, keep audio, 3 days, no auto summary', () => {
    expect(migrateMeetingSettings(undefined)).toEqual(MEETING_DEFAULTS);
    expect(MEETING_DEFAULTS).toMatchObject({ detection: 'ask', systemAudio: true, keepAudio: true, retentionDays: 3, autoSummary: false, hotkey: true });
  });
  it('invalid values are replaced, ranges clamped', () => {
    const s = migrateMeetingSettings({ detection: 'always', retentionDays: -4, myName: '  Sam  ', keepAudio: 'yes' });
    expect(s.detection).toBe('ask');
    expect(s.retentionDays).toBe(0);
    expect(s.myName).toBe('Sam');
    expect(s.keepAudio).toBe(true);
  });
});
