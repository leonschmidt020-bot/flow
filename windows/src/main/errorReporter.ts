// Wires errorReport.ts into the app: watches the log, sends via ClipVault's shared vault, remembers when it last sent.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildReport, ReportScheduler, type SchedulerState } from './errorReport';
import { log, logFile, logText, onLogLine } from './log';

export type SendResult = 'sent' | 'queued' | 'off' | 'unpaired' | 'error';

export interface ReporterDeps {
  stateFile: string;
  version: string;
  enabled(): boolean;
  hotkey(): string;
  model(): { status: string; error?: string };
  latestVersion(): string | null;
  /** null = ClipVault off */
  share(): ((text: string) => Promise<'sent' | 'queued' | 'off' | 'unpaired'>) | null;
}

function tailLines(file: string, max: number): string[] {
  const out: string[] = [];
  for (const f of [file + '.1', file]) {
    try { if (existsSync(f)) out.push(...readFileSync(f, 'utf8').split('\n').filter(Boolean)); } catch { /* ignore */ }
  }
  return out.slice(-max);
}

export class ErrorReporter {
  private sched: ReportScheduler;
  private secondInstance = false;
  private timer: NodeJS.Timeout | null = null;
  private off: (() => void) | null = null;
  private sending = false;

  constructor(private d: ReporterDeps) {
    let st: Partial<SchedulerState> | null = null;
    try { st = JSON.parse(readFileSync(d.stateFile, 'utf8')); } catch { /* first run */ }
    this.sched = new ReportScheduler(st);
  }
  start() {
    // our own lines („error report …“) must not trigger the next report
    this.off = onLogLine((l) => { if (!l.includes('error report')) this.sched.onLine(l); });
    this.timer = setInterval(() => void this.tick(), 60_000);
    this.timer.unref?.();
  }
  stop() { this.off?.(); if (this.timer) clearInterval(this.timer); this.timer = null; }
  noteSecondInstance() { this.secondInstance = true; }

  private save() { try { writeFileSync(this.d.stateFile, JSON.stringify(this.sched.state)); } catch { /* ignore */ } }

  private async tick() {
    if (!this.d.enabled() || !this.d.share()) return;
    const why = this.sched.due();
    if (why) await this.send(why);
    else this.save();
  }

  build(reason: 'error' | 'daily' | 'manual'): string {
    const m = this.d.model();
    const cpu = os.cpus()[0]?.model?.trim() ?? 'unbekannt';
    return buildReport(tailLines(logFile(), 600), {
      version: this.d.version, latestVersion: this.d.latestVersion(),
      windows: `${os.type()} ${os.release()}`, arch: process.arch, cpu,
      hotkey: this.d.hotkey(), modelStatus: m.status, modelError: m.error,
      secondInstance: this.secondInstance,
      user: os.userInfo().username, home: os.homedir(), logHasText: logText, reason,
    });
  }

  async send(reason: 'error' | 'daily' | 'manual'): Promise<SendResult> {
    const share = this.d.share();
    if (!share) return 'off';
    if (this.sending) return 'queued';
    this.sending = true;
    try {
      const r = await share(this.build(reason));
      if (r === 'sent' || r === 'queued') {
        this.sched.sent(reason);
        this.secondInstance = false;
        this.save();
        log(`error report ${r} (${reason})`);
      }
      return r;
    } catch (e) {
      log('error report send failed', e);
      return 'error';
    } finally { this.sending = false; }
  }
}

export const reporterStateFile = (userData: string) => path.join(userData, 'error-report.json');
