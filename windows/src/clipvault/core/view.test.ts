import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { Store } from './store';
import { buildList, toView } from './view';
import { sanitizeSettings } from './settings';

let dir: string;
beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cv-view-test-')); });
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('list view for the UI', () => {
  it('masks secret-collection entries unless revealed; never leaks the text in the list', () => {
    const s = new Store(dir);
    s.load();
    const pw = s.collections.find((c) => c.secret)!;
    const it = s.addText('super-geheim-123').item;
    s.setCollection(it.id, pw.id);
    const list = buildList(s, { collection: pw.id });
    const v = list.sections[0]!.items[0]!;
    expect(v.masked).toBe(true);
    expect(JSON.stringify(list)).not.toContain('super-geheim');
    expect(v.expiresInH).toBe(24);
    expect(toView(it, s, { revealSecrets: true }).text).toBe('super-geheim-123');
  });

  it('titles, link detection, counts and collection counts', () => {
    const s = new Store(dir);
    s.load();
    s.addText('https://example.com/pfad');
    s.addText('Erste Zeile\nzweite Zeile');
    const l = buildList(s, {});
    const [a, b] = l.sections[0]!.items;
    expect(a!.title).toBe('Erste Zeile');
    expect(b!.isLink).toBe(true);
    expect(b!.subtitle).toContain('example.com');
    expect(l.counts.links).toBe(1);
    expect(l.collections.length).toBe(2);
    expect(l.historyCount).toBe(2);
  });

  it('settings are sanitized (bad values fall back to defaults)', () => {
    const st = sanitizeSettings({ maxAgeDays: 999, maxItems: 'x', hotkey: 42, sync: { enabled: 'yes' }, ignoredApps: ['KeePass.exe', 3] });
    expect(st.maxAgeDays).toBe(30);
    expect(st.maxItems).toBe(200);
    expect(st.hotkey).toBe('Control+Shift+V');
    expect(st.sync.enabled).toBe(false);
    expect(st.ignoredApps).toEqual(['KeePass.exe']);
    expect(st.encryptAtRest).toBe(false);
  });
});
