// Call detection from fake registry snapshots (Windows microphone consent store) – start, stop, several apps,
// Flow's own exe excluded, unknown apps ignored – plus the controller's reaction (card, auto start, „Meeting vorbei“).
import { describe, expect, it } from 'vitest';
import { createRequire } from 'node:module';
import { mkdtempSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { activeCalls, appOfKey, CallDetector, micInUse, micUser, nameHint, parseMicConsent, type ActiveCall, type MicUser } from '../../src/meeting/detect';
import { ENUM_PROC, PROTOS } from '../../src/meeting/micRegistry';
import { MeetingController, type PillCard } from '../../src/meeting/controller';
import { MockCapture } from '../../src/meeting/recorder';

const R = 'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone';
const T0 = 0x1dc2f0000000000n; // a FILETIME
const FLOW = 'C:\\Users\\Test\\AppData\\Local\\Programs\\Flow\\Flow.exe';
const np = (exe: string) => `${R}\\NonPackaged\\${exe.replace(/\\/g, '#')}`;

/** snapshot builder: name → [start, stop] */
function snap(entries: Record<string, [bigint, bigint]>): MicUser[] {
  return Object.entries(entries).map(([k, [a, b]]) => micUser(k, a, b));
}

describe('registry snapshot → active calls', () => {
  it('in use: Start > Stop, or Stop == 0 (never used: both 0)', () => {
    expect(micInUse(T0, 0n)).toBe(true);
    expect(micInUse(T0 + 10n, T0)).toBe(true);
    expect(micInUse(T0, T0 + 10n)).toBe(false);
    expect(micInUse(0n, 0n)).toBe(false);
  });
  it('key → app: packaged family name / NonPackaged exe path with #', () => {
    expect(appOfKey(`${R}\\MSTeams_8wekyb3d8bbwe`)).toBe('msteams_8wekyb3d8bbwe');
    expect(appOfKey(np('C:\\Users\\Test\\AppData\\Roaming\\Zoom\\bin\\Zoom.exe'))).toBe('zoom.exe');
  });
  it('Teams joins a call → detected; call ends → gone', () => {
    const joined = activeCalls(snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0 + 5n, T0] }));
    expect(joined).toEqual([{ id: 'teams', name: 'Microsoft Teams', exe: 'msteams_8wekyb3d8bbwe' }]);
    expect(activeCalls(snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0 + 5n, T0 + 900n] }))).toEqual([]);
  });
  it('several apps at once, sorted and unique; browsers named like the Mac', () => {
    const calls = activeCalls(snap({
      [np('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe')]: [T0, 0n],
      [np('C:\\Users\\Test\\AppData\\Roaming\\Zoom\\bin\\Zoom.exe')]: [T0 + 1n, 0n],
      [np('C:\\Program Files\\Zoom2\\Zoom.exe')]: [T0 + 2n, 0n],
      [np('C:\\Users\\Test\\AppData\\Local\\Discord\\app-1.0\\Discord.exe')]: [T0, T0 + 1n], // released
    }));
    expect(calls.map((c) => c.name)).toEqual(['Chrome (z. B. Google Meet)', 'Zoom']);
  });
  it('Flow’s own exe is never a call; unknown apps are ignored', () => {
    const calls = activeCalls(snap({
      [np(FLOW)]: [T0, 0n],
      [np('C:\\Tools\\audacity.exe')]: [T0, 0n],
      [`${R}\\Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe`]: [T0, 0n],
    }), FLOW);
    expect(calls).toEqual([]);
    // even if Flow's exe were named like a call app, the full-path exclusion wins
    expect(activeCalls(snap({ [np('C:\\Flow\\chrome.exe')]: [T0, 0n] }), 'C:\\Flow\\chrome.exe')).toEqual([]);
  });
  it('reg.exe fallback output is parsed the same way', () => {
    const out = [
      R, '    NonPackaged    REG_SZ    x', '',
      `${R}\\MSTeams_8wekyb3d8bbwe`, '    Value    REG_SZ    Allow', '    LastUsedTimeStart    REG_QWORD    0x1dc2f0000000005', '    LastUsedTimeStop    REG_QWORD    0x0', '',
      `${R}\\NonPackaged`, '',
      np('C:\\Program Files\\Slack\\slack.exe'), '    LastUsedTimeStart    REG_QWORD    0x1dc2f0000000001', '    LastUsedTimeStop    REG_QWORD    0x1dc2f0000000009', '',
    ].join('\r\n');
    const users = parseMicConsent(out);
    expect(users.map((u) => [u.app, u.active])).toEqual([['msteams_8wekyb3d8bbwe', true], ['slack.exe', false]]);
  });
  it('window titles only improve the name', () => {
    const teams: ActiveCall = { id: 'teams', name: 'Microsoft Teams', exe: 'ms-teams.exe' };
    const chrome: ActiveCall = { id: 'chrome', name: 'Chrome (z. B. Google Meet)', exe: 'chrome.exe' };
    expect(nameHint(teams, ['Chat | Microsoft Teams', 'Wochenplanung | Microsoft Teams'])).toBe('Teams · Wochenplanung');
    expect(nameHint(chrome, ['Meet – abc-defg-hij - Google Chrome'])).toBe('Google Meet');
    expect(nameHint(chrome, ['Nachrichten - Google Chrome'])).toBeNull();
  });
  it('koffi prototypes parse (on any OS)', () => {
    const koffi = createRequire(import.meta.url)('koffi');
    koffi.proto(ENUM_PROC);
    for (const [n, p] of Object.entries(PROTOS)) expect(() => koffi.proto(p), n).not.toThrow();
  });
});

describe('CallDetector', () => {
  it('emits only when the set of calls changes', async () => {
    const snaps: MicUser[][] = [
      [],
      snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, 0n] }),
      snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, 0n] }),
      snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, 0n], [np('C:\\x\\Zoom.exe')]: [T0, 0n] }),
      snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, T0 + 1n] }),
    ];
    let i = 0;
    const d = new CallDetector(async () => snaps[Math.min(i++, snaps.length - 1)]!, 1000);
    const events: string[] = [];
    d.on('change', (a: ActiveCall[]) => events.push(a.map((x) => x.id).join('+') || '-'));
    for (let k = 0; k < 5; k++) await d.poll();
    expect(events).toEqual(['teams', 'teams+zoom', '-']);
  });
  it('a failing probe counts as "no calls"', async () => {
    const d = new CallDetector(async () => { throw new Error('denied'); }, 1000);
    await d.poll();
    expect(d.active).toEqual([]);
  });
});

describe('controller reacts to detection', () => {
  function setup(detection: 'ask' | 'auto' | 'off', overDeadlineMs = 60_000) {
    const root = mkdtempSync(path.join(os.tmpdir(), 'flow-detect-'));
    let snapshot: MicUser[] = [];
    const cards: (PillCard | null)[] = [];
    const toasts: string[] = [];
    const c = new MeetingController({
      root, modelsRoot: root, platform: 'win32', locale: () => 'de', micDeviceId: () => '', clean: (t) => t,
      asr: () => null, waitAsr: () => new Promise(() => {}), capture: () => new MockCapture({ mic: new Float32Array(1600), system: new Float32Array(1600) }),
      copyText: () => {}, log: () => {},
      pill: { meeting: () => {}, task: () => {}, card: (x) => cards.push(x), toast: (t) => toasts.push(t), level: () => {} },
      callProbe: async () => snapshot, ownExe: FLOW, timing: { pollMs: 60_000, endGraceMs: 5, overTimeoutMs: 60_000, overDeadlineMs, promptTimeoutMs: 60_000 },
      diarizer: async () => ({ diarize: async () => [] }), transcriber: () => async () => [],
    });
    c.setSettings({ detection });
    c.init();
    const set = async (s: MicUser[]) => {
      snapshot = s;
      await new Promise((r) => setTimeout(r, 5)); // let the initial poll of start() finish
      await (c as unknown as { detector: CallDetector }).detector.poll();
    };
    return { c, cards, toasts, set };
  }
  const teams = snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, 0n] });
  const teamsEnded = snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, T0 + 1n] });

  it('ask: card „Microsoft Teams erkannt · Meeting aufnehmen?“, accept → recording; mic closes → „Meeting vorbei?“', async () => {
    const { c, cards, set } = setup('ask');
    await set(teams);
    expect(cards.at(-1)).toMatchObject({ kind: 'detected', title: 'Microsoft Teams erkannt', sub: 'Meeting aufnehmen?', yes: 'Aufnehmen', no: 'Nicht jetzt' });
    c.cardAnswer(true);
    await new Promise((r) => setTimeout(r, 30));
    expect(c.isRecording).toBe(true);
    expect(c.store.meetings[0]!.title.startsWith('Microsoft Teams-Meeting · ')).toBe(true);
    await set(teamsEnded);
    await new Promise((r) => setTimeout(r, 30));
    expect(cards.at(-1)).toMatchObject({ kind: 'over', sub: 'Meeting abgeschlossen?', yes: 'Ja, beenden', no: 'Weiter aufnehmen' });
    c.cardAnswer(true);
    await new Promise((r) => setTimeout(r, 30));
    expect(c.isRecording).toBe(false);
    c.dispose();
  });
  it('„Nicht jetzt“ → no second card for the same call; asks again after the mic was released', async () => {
    const { c, cards, set } = setup('ask');
    await set(teams);
    c.cardAnswer(false);
    const n = cards.filter((x) => x?.kind === 'detected').length;
    await set(snap({ [`${R}\\MSTeams_8wekyb3d8bbwe`]: [T0, 0n], [np('C:\\x\\Zoom.exe')]: [T0, 0n] }));
    expect(cards.filter((x) => x?.kind === 'detected').length).toBe(n + 1); // Zoom is new
    expect(cards.at(-1)!.title).toBe('Zoom erkannt');
    c.dispose();
  });
  it('auto: starts by itself and stops by itself when the call app releases the mic', async () => {
    const { c, toasts, set } = setup('auto');
    await set(teams);
    await new Promise((r) => setTimeout(r, 30));
    expect(c.isRecording).toBe(true);
    expect(toasts).toContain('Microsoft Teams: Meeting-Aufnahme läuft');
    await set(teamsEnded);
    await new Promise((r) => setTimeout(r, 60));
    expect(c.isRecording).toBe(false);
    expect(toasts).toContain('Microsoft Teams: Meeting vorbei – wird ausgewertet');
    c.dispose();
  });
  it('„Meeting abgeschlossen?“ verdrängt/weggeklickt → endet trotzdem (Frist), nur „Weiter aufnehmen“ hält', async () => {
    const { c, cards, set } = setup('ask', 80);
    await set(teams);
    c.cardAnswer(true);
    await new Promise((r) => setTimeout(r, 30));
    expect(c.isRecording).toBe(true);
    await set(teamsEnded);
    await new Promise((r) => setTimeout(r, 20));
    expect(cards.at(-1)).toMatchObject({ kind: 'over' });
    (c as unknown as { clearCard: () => void }).clearCard();   // z. B. von einer anderen Karte verdrängt
    await new Promise((r) => setTimeout(r, 150));
    expect(c.isRecording).toBe(false);
    c.dispose();
  });
  it('„Weiter aufnehmen“ hält die Aufnahme über die Frist hinaus', async () => {
    const { c, set } = setup('ask', 80);
    await set(teams);
    c.cardAnswer(true);
    await new Promise((r) => setTimeout(r, 30));
    await set(teamsEnded);
    await new Promise((r) => setTimeout(r, 20));
    c.cardAnswer(false);
    await new Promise((r) => setTimeout(r, 150));
    expect(c.isRecording).toBe(true);
    c.dispose();
  });
  it('off: nothing happens', async () => {
    const { c, cards, set } = setup('off');
    await set(teams);
    expect(cards.filter(Boolean)).toEqual([]);
    expect(c.isRecording).toBe(false);
    c.dispose();
  });
});
