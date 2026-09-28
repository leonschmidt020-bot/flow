// Call detection on Windows – the equivalent of the Mac's MeetingAppDetector (Core Audio: which known call app has
// microphone input running). Windows records microphone use per app for its privacy indicator under
//   HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
//     <PackageFamilyName>              Store/MSIX apps, e.g. new Teams: MSTeams_8wekyb3d8bbwe
//     NonPackaged\C:#Path#To#App.exe   classic apps ("\" written as "#")
// each with LastUsedTimeStart / LastUsedTimeStop (FILETIME). In use right now: Start > Stop, or Stop == 0.
// Joining a Teams call opens the mic → the key flips within a second → „Meeting erkannt“ card on the next poll (3 s).
// Read via koffi (advapi32, no child process per poll; see micRegistry.ts); `reg.exe query` is the fallback.
// Local only: no network, no screen, no audio. Everything below except the probes is pure and unit-tested.
import { execFile } from 'node:child_process';
import { EventEmitter } from 'node:events';

export const MIC_CONSENT_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone';

/** one app entry of the consent store */
export interface MicUser { key: string; app: string; start: bigint; stop: bigint; active: boolean }

export const micInUse = (start: bigint, stop: bigint) => start > 0n && (stop === 0n || start > stop);

/** "MSTeams_8wekyb3d8bbwe" / "NonPackaged\C:#Program Files#Zoom#bin#Zoom.exe" → "msteams_8wekyb3d8bbwe" / "zoom.exe" */
export function appOfKey(key: string): string {
  const last = key.split('\\').pop() ?? key;
  return (last.split('#').pop() ?? last).toLowerCase();
}

export function micUser(key: string, start: bigint, stop: bigint): MicUser {
  return { key, app: appOfKey(key), start, stop, active: micInUse(start, stop) };
}

/** `reg query <key> /s` output → entries (fallback probe) */
export function parseMicConsent(out: string): MicUser[] {
  const res: MicUser[] = [];
  let cur: { key: string; start: bigint; stop: bigint; has: boolean } | null = null;
  const push = () => { if (cur?.has) res.push(micUser(cur.key, cur.start, cur.stop)); };
  for (const line of out.split(/\r?\n/)) {
    if (/^HKEY_/i.test(line.trim())) { push(); cur = { key: line.trim(), start: 0n, stop: 0n, has: false }; continue; }
    const m = /^\s+(LastUsedTimeStart|LastUsedTimeStop)\s+REG_QWORD\s+(0x[0-9a-f]+)/i.exec(line);
    if (m && cur) { cur.has = true; const v = BigInt(m[2]!); if (m[1]!.toLowerCase() === 'lastusedtimestart') cur.start = v; else cur.stop = v; }
  }
  push();
  return res;
}

export interface KnownCallApp { id: string; name: string; browser?: boolean; match: RegExp }

export const CALL_APPS: KnownCallApp[] = [
  { id: 'teams', name: 'Microsoft Teams', match: /^(msteams_8wekyb3d8bbwe|ms-teams\.exe|teams\.exe)$/ },
  { id: 'zoom', name: 'Zoom', match: /^(zoom\.exe|zoom_.*|zoomvideo.*)$/ },
  { id: 'webex', name: 'Webex', match: /^(webex\.exe|ciscocollabhost\.exe|atmgr\.exe|webexmta\.exe|cisco.*webex.*)$/ },
  { id: 'slack', name: 'Slack', match: /^(slack\.exe|91750d7e\.slack_.*)$/ },
  { id: 'discord', name: 'Discord', match: /^discord(ptb|canary)?\.exe$/ },
  { id: 'skype', name: 'Skype', match: /^(skype\.exe|microsoft\.skypeapp_.*)$/ },
  { id: 'whatsapp', name: 'WhatsApp', match: /^(whatsapp\.exe|whatsapp\.root\.exe|5319275a\.whatsappdesktop_.*)$/ },
  { id: 'signal', name: 'Signal', match: /^signal\.exe$/ },
  { id: 'telegram', name: 'Telegram', match: /^(telegram\.exe|telegrammessengerllp\.telegramdesktop_.*)$/ },
  { id: 'goto', name: 'GoTo Meeting', match: /^(g2mcomm\.exe|gotomeeting\.exe|goto\.exe)$/ },
  { id: 'chrome', name: 'Chrome (z. B. Google Meet)', browser: true, match: /^chrome\.exe$/ },
  { id: 'edge', name: 'Microsoft Edge (z. B. Google Meet)', browser: true, match: /^msedge\.exe$/ },
  { id: 'firefox', name: 'Firefox (z. B. Google Meet)', browser: true, match: /^firefox\.exe$/ },
  { id: 'brave', name: 'Brave (z. B. Google Meet)', browser: true, match: /^brave\.exe$/ },
  { id: 'opera', name: 'Opera (z. B. Google Meet)', browser: true, match: /^opera\.exe$/ },
  { id: 'vivaldi', name: 'Vivaldi (z. B. Google Meet)', browser: true, match: /^vivaldi\.exe$/ },
  { id: 'arc', name: 'Arc (z. B. Google Meet)', browser: true, match: /^arc\.exe$/ },
];

export interface ActiveCall { id: string; name: string; exe: string }

/** NonPackaged key form of an exe path, for excluding Flow itself */
export const exeKey = (exePath: string) => exePath.replace(/[\\/]/g, '#').toLowerCase();

/** known call apps that use the microphone right now (sorted, unique); Flow's own exe and unknown apps are ignored */
export function activeCalls(users: readonly MicUser[], ownExe = ''): ActiveCall[] {
  const own = ownExe ? exeKey(ownExe) : '';
  const found = new Map<string, ActiveCall>();
  for (const u of users) {
    if (!u.active) continue;
    if (own && u.key.toLowerCase().endsWith(own)) continue;
    const k = CALL_APPS.find((a) => a.match.test(u.app));
    if (k && !found.has(k.id)) found.set(k.id, { id: k.id, name: k.name, exe: u.app });
  }
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Window titles are only a naming hint: "Wochenplanung | Microsoft Teams" → "Wochenplanung",
 * "Meet – abc-defg-hij - Google Chrome" → "Google Meet". null = no better name.
 */
export function nameHint(call: ActiveCall, titles: readonly string[]): string | null {
  const app = CALL_APPS.find((a) => a.id === call.id);
  if (app?.browser) {
    if (titles.some((t) => /^Meet\s*[–-]|Google Meet/i.test(t))) return 'Google Meet';
    if (titles.some((t) => /teams\.microsoft\.com|Microsoft Teams/i.test(t))) return 'Microsoft Teams (Browser)';
    if (titles.some((t) => /zoom/i.test(t))) return 'Zoom (Browser)';
    return null;
  }
  if (call.id === 'teams') {
    const t = titles.map((x) => /^(.+?)\s*\|\s*Microsoft Teams/i.exec(x)?.[1]?.trim()).find((x) => x && !/^(chat|aktivität|activity|kalender|calendar|teams)$/i.test(x));
    return t ? `Teams · ${t.slice(0, 60)}` : null;
  }
  return null;
}

export type Probe = () => Promise<MicUser[]>;

/** fallback probe: one reg.exe per poll */
export const regProbe: Probe = () => new Promise((resolve) => {
  execFile('reg.exe', ['query', MIC_CONSENT_KEY, '/s'], { windowsHide: true, timeout: 2500, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => resolve(err ? [] : parseMicConsent(String(stdout))));
});

/** polls the probe (3 s like the Mac); emits 'change' (ActiveCall[]) when the set of calls changes */
export class CallDetector extends EventEmitter {
  private timer: NodeJS.Timeout | null = null;
  active: ActiveCall[] = [];
  private busy = false;
  constructor(private probe: Probe, private intervalMs = 3000, private ownExe = '') { super(); }
  start() { if (!this.timer) { this.timer = setInterval(() => void this.poll(), this.intervalMs); this.timer.unref?.(); void this.poll(); } }
  stop() { if (this.timer) clearInterval(this.timer); this.timer = null; }
  get running() { return !!this.timer; }
  async poll() {
    if (this.busy) return;
    this.busy = true;
    try {
      let users: MicUser[] = [];
      try { users = await this.probe(); } catch { users = []; }
      const next = activeCalls(users, this.ownExe);
      if (next.map((a) => a.id).join() !== this.active.map((a) => a.id).join()) { this.active = next; this.emit('change', next); }
    } finally { this.busy = false; }
  }
}
