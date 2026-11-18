import { describe, expect, it } from 'vitest';
import {
  analyze, anonymize, buildReport, BUNDLE_MS, DAILY_MS, isErrorLine, MIN_GAP_MS, REPORT_HEADER, ReportScheduler, type ReportContext,
} from '../../src/main/errorReport';

const ctx = (o: Partial<ReportContext> = {}): ReportContext => ({
  version: '0.4.1', windows: 'Windows_NT 10.0.26100', arch: 'arm64', cpu: 'Snapdragon X Plus', hotkey: 'RightCtrl',
  modelStatus: 'ready', user: 'maxmuster', home: 'C:\\Users\\maxmuster', reason: 'manual', now: new Date('2026-11-18T10:00:00Z'), ...o,
});
const T = '2026-11-18T09:00:00.000Z';
const OK_LOG = [
  `${T} Flow 0.4.1 starting (win32-arm64, electron 39.0.0)`,
  `${T} mic started {"label":"Mikrofonarray (Realtek)","sampleRate":48000}`,
  `${T} hotkey: hook started RightCtrl`,
  `${T} dictation: 3.2 s audio, asr 410 ms, 1 chunk(s), 12 words, app WINWORD.EXE · speech 2.8 s, level peak -6 / rms -24 dBFS, start 40 ms warm`,
];

describe('error report – content', () => {
  it('first line is the fixed header, everything ok on a clean log', () => {
    const r = buildReport(OK_LOG, ctx());
    expect(r.split('\n')[0]).toBe(REPORT_HEADER);
    expect(r).toContain('**Alles ok**');
    expect(r).toContain('Flow 0.4.1 (Windows)');
    expect(r).toContain('| Mikrofon | Mikrofonarray (Realtek) |');
    expect(r).toContain('Snapdragon X Plus (arm64)');
    expect(r).not.toContain('❌');
  });

  it('finds the checklist problems', () => {
    const lines = [
      ...OK_LOG,
      `${T} hotkey hint shown (copilot key)`,
      `${T} foregroundExe failed Error: koffi`,
      `${T} asr error Error: model.onnx truncated`,
      `${T} mic error {"name":"NotAllowedError","message":"Permission denied"}`,
      `${T} hotkey: hook failed Error: uiohook`,
      `${T} dictation failed Error: paste`,
      `${T} Error: Cannot find module 'uiohook_napi.node'`,
      `${T} dictation: 2.0 s audio, asr 300 ms, 1 chunk(s), 3 words, app ? · speech 1.5 s, level peak -30 / rms -52 dBFS (×12.0), start 40 ms cold`,
    ];
    const c = analyze(lines, ctx({ latestVersion: '0.4.2', secondInstance: true, modelStatus: 'error' }));
    const bad = Object.fromEntries(c.map((x) => [x.key, !x.ok]));
    expect(bad).toMatchObject({ version: true, hotkey: true, hook: true, app: true, model: true, mic: true, level: true, insert: true, instances: true, natives: true });
    expect(c.find((x) => x.key === 'mic')!.detail).toMatch(/kein Zugriff/);
    expect(c.find((x) => x.key === 'level')!.detail).toMatch(/1 von 2/);
  });

  it('hotkey hint does not count once the user switched the key', () => {
    const c = analyze([...OK_LOG, `${T} hotkey hint shown (copilot key)`], ctx({ hotkey: 'CtrlWin' }));
    expect(c.find((x) => x.key === 'hotkey')!.ok).toBe(true);
  });

  it('at most 40 log lines, never more', () => {
    const many = Array.from({ length: 120 }, (_, i) => `${T} update check failed ${i}`);
    const r = buildReport(many, ctx());
    const block = r.split('```')[1]!.trim().split('\n');
    expect(block).toHaveLength(40);
    expect(block.at(-1)).toContain('failed 119');
  });

  it('no log lines at all when FLOW_LOG_TEXT is on', () => {
    const r = buildReport([...OK_LOG, `${T} dictation text: geheimer Satz`], ctx({ logHasText: true }));
    expect(r).not.toContain('geheimer Satz');
    expect(r).not.toContain('```');
  });

  it('dictation text never leaks via irrelevant lines', () => {
    const r = buildReport([...OK_LOG, `${T} hallo welt das ist privat`], ctx());
    expect(r).not.toContain('privat');
  });
});

describe('error report – anonymization', () => {
  it('user name and home dir become placeholders, also JSON-escaped and with slashes', () => {
    const u = 'maxmuster', home = 'C:\\Users\\maxmuster';
    expect(anonymize('open C:\\Users\\maxmuster\\AppData\\x.node', u, home)).toBe('open <home>\\AppData\\x.node');
    expect(anonymize('{"p":"C:\\\\Users\\\\maxmuster\\\\a"}', u, home)).toBe('{"p":"<home>\\\\a"}');
    expect(anonymize('c:/users/MaxMuster/x', u, home)).toBe('<home>/x');
    expect(anonymize('device of maxmuster ok', u, home)).toBe('device of <user> ok');
    // other profiles too
    expect(anonymize('D:\\Users\\jemand\\x', u, home)).toBe('D:\\Users\\<user>\\x');
    // a part of another word stays
    expect(anonymize('maxmusterhaus', u, home)).toBe('maxmusterhaus');
  });
  it('the whole report contains no user name', () => {
    const r = buildReport([...OK_LOG, `${T} asr error Error: ENOENT C:\\Users\\maxmuster\\AppData\\Roaming\\Flow\\models`], ctx({ reason: 'error' }));
    expect(r.toLowerCase()).not.toContain('maxmuster');
    expect(r).toContain('<home>');
  });
});

describe('error report – throttling', () => {
  const clock = (t0 = 1_000_000_000) => { let t = t0; return { now: () => t, add: (ms: number) => { t += ms; } }; };

  it('bundles a burst, then at most one report per 30 min', () => {
    const c = clock();
    const s = new ReportScheduler(null, c.now);
    expect(s.due()).toBeNull();
    s.onLine('x asr error boom');
    expect(s.due()).toBeNull(); // wait for the burst
    c.add(BUNDLE_MS);
    for (let i = 0; i < 20; i++) s.onLine('x mic error again');
    expect(s.due()).toBe('error');
    s.sent('error');
    expect(s.due()).toBeNull();
    s.onLine('x asr error later');
    c.add(BUNDLE_MS * 5);
    expect(s.due()).toBeNull(); // still inside 30 min
    c.add(MIN_GAP_MS);
    expect(s.due()).toBe('error');
  });

  it('daily report only when there were warnings or errors', () => {
    const c = clock();
    const s = new ReportScheduler(null, c.now);
    c.add(DAILY_MS);
    expect(s.due()).toBeNull(); // quiet day → nothing, next window starts
    s.onLine('x update warn something');
    c.add(DAILY_MS - 1);
    expect(s.due()).toBeNull();
    c.add(1);
    expect(s.due()).toBe('daily');
    s.sent('daily');
    c.add(DAILY_MS);
    expect(s.due()).toBeNull();
  });

  it('a manual report resets pending errors; state survives a restart', () => {
    const c = clock();
    const s = new ReportScheduler(null, c.now);
    s.onLine('x foregroundExe failed');
    s.sent('manual');
    c.add(BUNDLE_MS);
    expect(s.due()).toBeNull();
    s.onLine('x hook failed');
    c.add(BUNDLE_MS);
    const again = new ReportScheduler(JSON.parse(JSON.stringify(s.state)), c.now);
    expect(again.due()).toBeNull(); // last report < 30 min ago, also after restart
    c.add(MIN_GAP_MS);
    expect(again.due()).toBe('error');
  });

  it('which lines count as errors', () => {
    for (const l of ['asr error x', 'foregroundExe failed', 'mic error {}', 'hotkey: hook failed', 'clipvault init failed', 'Error: Cannot find module x.node'])
      expect(isErrorLine(l), l).toBe(true);
    for (const l of ['mic started {}', 'dictation: 3 s', 'update check', 'hotkey: hook started'])
      expect(isErrorLine(l), l).toBe(false);
  });
});
