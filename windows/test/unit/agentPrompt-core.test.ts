// Agent-Prompt core (port of APCore.swift + the Mac self test): triggers, detection (full labelled set), rule builder, gist.
import { describe, expect, it } from 'vitest';
import {
  appCategory, appName, clean, detect, gistOf, isAgentTarget, isEnglish, match, missingDetails, structure, type APContext,
} from '../../src/agentPrompt/core';
import { icu } from '../../src/agentPrompt/regex';
import {
  DETECTION, FALLBACK_DE, FALLBACK_EN, LONG_DE1, MAIL, SAMPLE_PROMPT_DE, TERM, TRIGGERS, VSC,
} from '../../src/agentPrompt/testSet';

describe('regex port (ICU → JS)', () => {
  it('\\b and \\w know umlauts like ICU', () => {
    expect(icu(String.raw`\bänder(?:e|n)\b`, 'i').test('bitte ändere das')).toBe(true);
    expect(icu(String.raw`\bprüf\b`, 'i').test('prüfen')).toBe(false);
    expect(icu(String.raw`^[\w-]+$`).test('Größe-ß')).toBe(true);
  });
});

describe('triggers („Prompt: …“, mishearings, sentences about prompts)', () => {
  it(`has the full Mac set (${TRIGGERS.length} sentences)`, () => {
    expect(TRIGGERS.length).toBeGreaterThanOrEqual(37);
  });
  for (const [s, want] of TRIGGERS) {
    it(want ? `triggers: ${s.slice(0, 60)}` : `no trigger: ${s.slice(0, 60)}`, () => {
      const m = match(s);
      if (want) {
        expect(m, s).not.toBeNull();
        expect(m!.body.startsWith(want), `${m!.body} (${m!.phrase})`).toBe(true);
      } else {
        expect(m, m ? `${m.phrase} → ${m.body}` : '').toBeNull();
      }
    });
  }
  it('trigger at the end gets a full stop, trigger phrase is reported', () => {
    const m = match('Die Suche soll auch Tippfehler finden und Umlaute ignorieren, mach daraus einen Prompt')!;
    expect(m.atEnd).toBe(true);
    expect(m.body.endsWith('ignorieren.')).toBe(true);
    expect(m.phrase.toLowerCase()).toContain('prompt');
  });
});

describe('automatic detection (full labelled set)', () => {
  it('at least 40 cases, both classes', () => {
    expect(DETECTION.length).toBeGreaterThanOrEqual(42);
    expect(DETECTION.filter((c) => c.offer).length).toBeGreaterThanOrEqual(20);
    expect(DETECTION.filter((c) => !c.offer).length).toBeGreaterThanOrEqual(20);
  });
  for (const c of DETECTION) {
    it(`${c.offer ? 'JA  ' : 'nein'} ${c.note} (${c.exe || 'unbekannt'})`, () => {
      const d = detect({ text: c.text, duration: c.seconds, exe: c.exe, title: c.title });
      expect(d.offer, `Punkte ${d.score}: ${d.reasons.join(' · ')}`).toBe(c.offer);
    });
  }
  it('empty dictation never offers', () => {
    expect(detect({ text: '', duration: 0, exe: TERM }).offer).toBe(false);
  });
  it('reasons + score are explained', () => {
    const d = detect({ text: LONG_DE1, duration: 42, exe: VSC, title: 'SettingsPanel.tsx' });
    expect(d.reasons[0]).toBe(`${d.words} Wörter`);
    expect(d.reasons.some((r) => r.startsWith('Auftrag:'))).toBe(true);
    expect(d.reasons.some((r) => r.startsWith('Technik:'))).toBe(true);
    expect(d.technical).toContain('settingspanel.tsx');
    expect(d.agentApp).toBe(true);
  });
  it('Windows app categories + agent titles', () => {
    expect(appCategory('Code.exe')).toBe('ai');
    expect(appCategory('C:\\Program Files\\WindowsApps\\WindowsTerminal.exe')).toBe('ai');
    expect(appCategory('WhatsApp.exe')).toBe('personal');
    expect(appCategory('OUTLOOK.EXE')).toBe('email');
    expect(appCategory('slack.exe')).toBe('work');
    expect(appCategory('chrome.exe')).toBe('other');
    expect(isAgentTarget('chrome.exe', 'Claude - Google Chrome')).toBe(true);
    expect(isAgentTarget('chrome.exe', 'Wetter - Google Chrome')).toBe(false);
    expect(appName('Code.exe')).toBe('Visual Studio Code');
    expect(appName('Foo.exe')).toBe('Foo');
  });
  it('language guess', () => {
    expect(isEnglish(FALLBACK_EN)).toBe(true);
    expect(isEnglish(FALLBACK_DE)).toBe(false);
  });
});

describe('rule builder (fallback without Claude) keeps every detail', () => {
  const ctx: APContext = { appName: 'Visual Studio Code', exe: VSC, windowTitle: 'SettingsPanel.tsx - admin-dashboard', selection: '' };
  const p = structure(FALLBACK_DE, ctx);
  for (const must of ['100', '/api/users', 'users.controller.ts', 'npm run test', 'Lisa', 'Dependencies', 'Settings Page', 'drei Sekunden', 'limit']) {
    it(`keeps „${must}“`, () => expect(p).toContain(must));
  }
  it('self-correction visible without losing details (50 → 100)', () => {
    expect(p).toContain('korrigiert: die ersten 100');
    expect(p).toContain('User geladen werden');
  });
  it('an unambiguous self-correction is resolved', () => {
    expect(clean('Ruf bitte am Donnerstag an, nein warte, am Freitag.')).toBe('Ruf bitte am Freitag an.');
  });
  it('structure goal/task/acceptance, rules, open points, context', () => {
    expect(p).toContain('**Ziel:**');
    expect(p).toContain('## Aufgabe');
    expect(p).toContain('## Akzeptanzkriterien');
    expect(p).toContain('## Regeln');
    expect(p).toContain('Keine neuen Dependencies');
    expect(p).toContain('## Offene Punkte');
    expect(p).toContain('Suchfilter');
    expect(p).toContain('## Kontext');
    expect(p).toContain('admin-dashboard');
    expect(p.toLowerCase()).not.toContain('ich mache jetzt mal');
  });
  it('never a mail subject as context', () => {
    const pm = structure(FALLBACK_DE, { appName: 'Outlook', exe: MAIL, windowTitle: 'Re: Gehalt', selection: '' });
    expect(pm).not.toContain('Gehalt');
  });
  it('English → English headings, details kept', () => {
    const e = structure(FALLBACK_EN);
    for (const h of ['**Goal:**', '## Task', '## Rules', '## Open questions']) expect(e).toContain(h);
    for (const must of ['ReportView.swift', 'CSV', 'date, amount and category', 'PDF', 'Excel']) expect(e).toContain(must);
  });
  it('all numbers/files taken over', () => {
    expect(missingDetails(FALLBACK_DE, p)).toEqual([]);
  });
  it('gist: goal + counts', () => {
    const g = gistOf(p);
    expect(g.tasks).toBeGreaterThanOrEqual(2);
    expect(g.goal).not.toBe('');
    const g2 = gistOf(SAMPLE_PROMPT_DE);
    expect(g2).toMatchObject({ tasks: 5, rules: 2, open: 1, criteria: 3 });
    expect(g2.goal.startsWith('Die Settings Page')).toBe(true);
  });
});
