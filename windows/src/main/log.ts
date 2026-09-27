// Local log file (<userData>/logs/flow.log, rotated at 1 MB). Never contains dictated text unless FLOW_LOG_TEXT=1.
import { appendFileSync, mkdirSync, renameSync, statSync, existsSync } from 'node:fs';
import path from 'node:path';

let file = '';
export function initLog(dir: string) {
  mkdirSync(dir, { recursive: true });
  file = path.join(dir, 'flow.log');
}
export function log(...args: unknown[]) {
  const line = `${new Date().toISOString()} ${args.map((a) => (a instanceof Error ? `${a.message}\n${a.stack}` : typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`;
  if (process.env.FLOW_DEBUG) process.stdout.write(line);
  if (!file) return;
  try {
    if (existsSync(file) && statSync(file).size > 1_000_000) renameSync(file, file + '.1');
    appendFileSync(file, line);
  } catch { /* ignore */ }
}
export const logText = process.env.FLOW_LOG_TEXT === '1';
