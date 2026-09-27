// Dictation history (local only), capped and pruned by retention days.
import { randomUUID } from 'node:crypto';
import { JsonFile } from './store';

export interface DictationRecord {
  id: string;
  date: string; // ISO
  text: string;
  raw: string;
  app: string;
  durationSec: number;
  words: number;
  ms: number;
}

export const HISTORY_MAX = 2000;

export function prune(records: DictationRecord[], retentionDays: number, now = Date.now()): DictationRecord[] {
  const cutoff = now - retentionDays * 86400_000;
  return records.filter((r) => Date.parse(r.date) >= cutoff).slice(0, HISTORY_MAX);
}

export function sanitizeHistory(v: unknown): DictationRecord[] {
  const arr = Array.isArray(v) ? v : v && typeof v === 'object' && Array.isArray((v as { records?: unknown }).records) ? (v as { records: unknown[] }).records : [];
  return arr.filter((r): r is DictationRecord => !!r && typeof r === 'object' && typeof (r as DictationRecord).text === 'string' && typeof (r as DictationRecord).date === 'string')
    .map((r) => ({ id: String(r.id ?? randomUUID()), date: r.date, text: r.text, raw: String(r.raw ?? r.text), app: String(r.app ?? ''),
      durationSec: Number(r.durationSec) || 0, words: Number(r.words) || 0, ms: Number(r.ms) || 0 }));
}

export class History {
  records: DictationRecord[] = [];
  private file: JsonFile<{ version: 1; records: DictationRecord[] }>;
  constructor(file: string, private retentionDays: () => number) {
    this.file = new JsonFile(file, 400);
    this.records = prune(sanitizeHistory(this.file.load(() => ({ version: 1 as const, records: [] })).value), retentionDays());
  }
  add(r: Omit<DictationRecord, 'id' | 'date'> & { date?: string }): DictationRecord {
    const rec: DictationRecord = { id: randomUUID(), date: r.date ?? new Date().toISOString(), ...r } as DictationRecord;
    this.records = prune([rec, ...this.records], this.retentionDays());
    this.persist();
    return rec;
  }
  delete(id: string) { this.records = this.records.filter((r) => r.id !== id); this.persist(); }
  clear() { this.records = []; this.persist(); }
  wordsToday(now = new Date()): number {
    const d = now.toDateString();
    return this.records.filter((r) => new Date(r.date).toDateString() === d).reduce((n, r) => n + r.words, 0);
  }
  persist() { this.file.save({ version: 1, records: this.records }); }
  flush() { this.file.flush(); }
}
