// Error reports for a friend who helps you (opt-in, off by default).
//
// With „Fehlerberichte automatisch an den geteilten Tresor senden“ switched on and a ClipVault vault paired, Flow puts a
// short Markdown report into the shared vault. Every member's ClipVault shows it; the Mac app recognises it by the
// FIRST LINE `# Flow-Fehlerbericht` (REPORT_HEADER) and offers it as a card.
//
// What is in it: Flow version, Windows build, CPU/arch, hotkey, microphone name, model status, the automatic checks
// below (ok / problem) and the last relevant log lines with the user name replaced by <user>.
// What is never in it: dictated text, clipboard content, file contents, history. The log itself never holds dictated
// text (log.ts) – and if FLOW_LOG_TEXT=1 is set for debugging, no log lines are included at all.
//
// When: (a) new error lines in the log – at most one report per 30 min, bundled; (b) once a day a short report, only if
// there were errors or warnings since the last one; (c) „Fehlerbericht jetzt senden“ (hub + tray).

export const REPORT_HEADER = '# Flow-Fehlerbericht';
export const MIN_GAP_MS = 30 * 60_000;
export const DAILY_MS = 24 * 60 * 60_000;
/** wait a little after the first error so a burst ends up in one report */
export const BUNDLE_MS = 60_000;

/** a log line that should trigger a report */
const ERROR_RX = /\b(asr error|foregroundExe failed|mic error|mic start failed|hook failed|dictation failed|uncaught|unhandled|crash|render-process-gone|child-process-gone|init failed|Cannot find module|was compiled against)\b/i;
/** relevant for the report body (errors + context) */
const RELEVANT_RX = /(Flow \d+\.\d+\.\d+ starting|hotkey|asr|mic |mic started|dictation|update|foregroundExe|failed|error|warn|second instance|clipvault|model)/i;
const WARN_RX = /\b(warn|failed|error)\b/i;

export const isErrorLine = (line: string) => ERROR_RX.test(line);
export const isWarnLine = (line: string) => WARN_RX.test(line);

/** user name / home directory → <user> (also in JSON-escaped paths) */
export function anonymize(line: string, user: string, home: string): string {
  let s = line;
  const esc = (x: string) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const homes = [home, home.replace(/\\/g, '\\\\'), home.replace(/\\/g, '/')].filter((h) => h && h.length > 3);
  for (const h of homes) s = s.replace(new RegExp(esc(h), 'gi'), '<home>');
  if (user && user.length >= 2) s = s.replace(new RegExp(`(?<![A-Za-z0-9])${esc(user)}(?![A-Za-z0-9])`, 'gi'), '<user>');
  // other profile paths that slipped through (C:\Users\<name>\…)
  s = s.replace(/([A-Za-z]:[\\/]{1,2}Users[\\/]{1,2})[^\\/"'\s]+/gi, '$1<user>');
  return s;
}

export interface ReportContext {
  version: string;
  latestVersion?: string | null;
  windows: string;
  arch: string;
  cpu: string;
  hotkey: string;
  modelStatus: string;
  modelError?: string;
  /** another Flow instance was started since the last report */
  secondInstance?: boolean;
  user: string;
  home: string;
  /** FLOW_LOG_TEXT=1 – the log may hold dictated text → leave log lines out */
  logHasText?: boolean;
  reason: 'error' | 'daily' | 'manual';
  now?: Date;
}

export interface Check { key: string; label: string; ok: boolean; detail: string }

const newer = (a: string, b: string) => {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0);
  return false;
};

/** dictation lines: `… app <exe> · speech … level peak P / rms R dBFS (×G) …` */
function dictations(lines: string[]) {
  return lines.filter((l) => /\bdictation: /.test(l)).map((l) => ({
    app: /\bapp (\S+)/.exec(l)?.[1] ?? '',
    rms: Number(/rms (-?\d+(?:\.\d+)?) dBFS/.exec(l)?.[1] ?? NaN),
    gain: Number(/\(×(\d+(?:\.\d+)?)\)/.exec(l)?.[1] ?? NaN),
    words: Number(/(\d+) words/.exec(l)?.[1] ?? NaN),
  }));
}

/** the automatic part of the checklist (what can be seen from the log + state) */
export function analyze(lines: string[], c: ReportContext): Check[] {
  const has = (rx: RegExp) => lines.filter((l) => rx.test(l));
  const d = dictations(lines).slice(-10);
  const quiet = d.filter((x) => (Number.isFinite(x.rms) && x.rms < -45) || (Number.isFinite(x.gain) && x.gain > 8));
  const noApp = d.filter((x) => x.app === '?');
  const fg = has(/foregroundExe failed/);
  const asrErr = has(/asr error/);
  const micErr = has(/mic error|mic start failed/);
  const denied = micErr.filter((l) => /NotAllowed|Permission|denied/i.test(l));
  const hook = has(/hotkey: hook failed/);
  const copilot = has(/hotkey hint shown \((copilot key|no right Ctrl yet)\)/);
  const insert = has(/dictation failed|insert failed|paste failed/);
  const natives = has(/Cannot find module|was compiled against|\.node\b.*(error|failed)|koffi.*(error|failed)|uiohook.*(error|failed)/i);
  const starts = has(/Flow \d+\.\d+\.\d+ starting/);
  const empty = d.filter((x) => x.words === 0);
  const outdated = !!c.latestVersion && newer(c.latestVersion, c.version);
  return [
    { key: 'version', label: 'Aktuelle Version', ok: !outdated, detail: outdated ? `${c.version} läuft, ${c.latestVersion} ist da` : c.version },
    { key: 'hotkey', label: 'Diktat-Taste passt zur Tastatur', ok: !(copilot.length && c.hotkey === 'RightCtrl'),
      detail: copilot.length && c.hotkey === 'RightCtrl' ? 'keine rechte Strg-Taste erkannt (Copilot-Taste?), Taste ist noch RightCtrl' : c.hotkey },
    { key: 'hook', label: 'Tastatur-Hook', ok: !hook.length, detail: hook.length ? `${hook.length}× hook failed` : 'ok' },
    { key: 'app', label: 'App-Erkennung', ok: !fg.length && !noApp.length, detail: fg.length ? 'foregroundExe failed' : noApp.length ? `${noApp.length} Diktat(e) mit „app ?“` : 'ok' },
    { key: 'model', label: 'Sprachmodell', ok: c.modelStatus === 'ready' && !asrErr.length,
      detail: `${c.modelStatus}${c.modelError ? ` (${c.modelError})` : ''}${asrErr.length ? `, ${asrErr.length}× asr error` : ''}` },
    { key: 'mic', label: 'Mikrofon', ok: !micErr.length, detail: denied.length ? 'kein Zugriff (Windows-Datenschutz → Mikrofon)' : micErr.length ? `${micErr.length}× Mikrofon-Fehler` : 'ok' },
    { key: 'level', label: 'Mikrofon-Pegel', ok: !quiet.length && !empty.length,
      detail: quiet.length ? `${quiet.length} von ${d.length} Diktaten sehr leise (rms < −45 dBFS oder Verstärkung > ×8)` : empty.length ? `${empty.length} Diktat(e) ohne Wörter` : d.length ? `ok (${d.length} Diktate)` : 'noch kein Diktat' },
    { key: 'insert', label: 'Text eingefügt', ok: !insert.length, detail: insert.length ? `${insert.length}× Diktat/Einfügen gescheitert` : 'ok' },
    { key: 'instances', label: 'Nur eine Flow-Instanz', ok: !c.secondInstance, detail: c.secondInstance ? 'zweiter Start erkannt' : 'ok' },
    { key: 'natives', label: 'Programmteile (.node) geladen', ok: !natives.length, detail: natives.length ? `${natives.length} Ladefehler` : 'ok' },
    { key: 'restarts', label: 'Stabil (keine Neustart-Serie)', ok: starts.length <= 5, detail: `${starts.length} Start(s) im Log-Ausschnitt` },
  ];
}

/** Markdown report – first line is REPORT_HEADER (the Mac recognises it by that) */
export function buildReport(allLines: string[], c: ReportContext): string {
  const checks = analyze(allLines, c);
  const bad = checks.filter((x) => !x.ok);
  const when = (c.now ?? new Date()).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
  const why = c.reason === 'manual' ? 'von Hand gesendet' : c.reason === 'daily' ? 'Tagesbericht' : 'neue Fehler im Log';
  const rel = c.logHasText ? [] : allLines.filter((l) => RELEVANT_RX.test(l)).slice(-40).map((l) => anonymize(l, c.user, c.home).slice(0, 400));
  const out = [
    REPORT_HEADER,
    '',
    `**${bad.length ? `${bad.length} Problem${bad.length === 1 ? '' : 'e'}` : 'Alles ok'}** · Flow ${c.version} (Windows) · ${when} · ${why}`,
    '',
    '| | |',
    '|---|---|',
    `| Windows | ${c.windows} |`,
    `| CPU | ${c.cpu} (${c.arch}) |`,
    `| Taste | ${c.hotkey} |`,
    `| Mikrofon | ${micName(allLines)} |`,
    `| Sprachmodell | ${c.modelStatus} |`,
    '',
    '## Prüfliste',
    '',
    ...checks.map((x) => `- ${x.ok ? '✅' : '❌'} **${x.label}** – ${x.detail}`),
    '',
    '## Log (letzte relevante Zeilen, ohne diktierte Texte)',
    '',
    rel.length ? '```\n' + rel.join('\n') + '\n```' : c.logHasText ? '_ausgelassen (FLOW_LOG_TEXT ist an)_' : '_keine_',
    '',
    '_Enthält nie diktierte Texte, Zwischenablage oder Dateien. Abschalten: Flow → Einstellungen → Fehlerberichte._',
  ];
  return out.join('\n');
}

function micName(lines: string[]): string {
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = /mic started (\{.*\})/.exec(lines[i]!);
    if (m) { try { const o = JSON.parse(m[1]!); if (typeof o.label === 'string' && o.label) return o.label.slice(0, 80); } catch { /* ignore */ } }
  }
  return 'unbekannt';
}

// ------------------------------------------------------------------ when to send
export interface SchedulerState { lastSentAt: number; lastDailyAt: number; firstErrorAt: number; warnSince: boolean }

export class ReportScheduler {
  state: SchedulerState;
  constructor(state: Partial<SchedulerState> | null, private now: () => number = Date.now) {
    this.state = { lastSentAt: 0, lastDailyAt: 0, firstErrorAt: 0, warnSince: false, ...(state ?? {}) };
    if (!this.state.lastDailyAt) this.state.lastDailyAt = this.now();
  }
  /** feed every new log line */
  onLine(line: string) {
    if (isErrorLine(line) && !this.state.firstErrorAt) this.state.firstErrorAt = this.now();
    if (isWarnLine(line)) this.state.warnSince = true;
  }
  /** called every minute: what to send now (null = nothing) */
  due(): 'error' | 'daily' | null {
    const t = this.now();
    if (this.state.firstErrorAt && t - this.state.firstErrorAt >= BUNDLE_MS && t - this.state.lastSentAt >= MIN_GAP_MS) return 'error';
    if (t - this.state.lastDailyAt >= DAILY_MS) {
      if (this.state.warnSince || this.state.firstErrorAt) return 'daily';
      this.state.lastDailyAt = t; // nothing happened – skip today
    }
    return null;
  }
  sent(reason: 'error' | 'daily' | 'manual') {
    const t = this.now();
    this.state.lastSentAt = t;
    this.state.firstErrorAt = 0;
    this.state.warnSince = false;
    if (reason !== 'error') this.state.lastDailyAt = t;
  }
}
