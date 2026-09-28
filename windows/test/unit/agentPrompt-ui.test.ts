// Agent-Prompt card/hub helpers: prompt typesetting, counts line, labels, strings (DE/EN), card view from a phase.
import { describe, expect, it } from 'vitest';
import { countsLine, promptLines, rulesLabel, sourceLabel } from '../../src/renderer/pill/apCard';
import { _apDicts, apKeys, apt, reasonText } from '../../src/agentPrompt/i18n';
import { gistOf } from '../../src/agentPrompt/core';
import { SAMPLE_PROMPT_DE } from '../../src/agentPrompt/testSet';

describe('card helpers', () => {
  it('prompt lines: heading, goal, items, blank lines collapsed', () => {
    const l = promptLines('**Ziel:** X\n\n\n## Aufgabe\n1. **Baue** A\n- B\nText\n\n');
    expect(l).toEqual([
      { t: 'goal', k: 'Ziel', v: 'X' }, { t: 'blank' }, { t: 'heading', s: 'Aufgabe' }, { t: 'item', s: '1. Baue A' }, { t: 'item', s: '- B' }, { t: 'text', s: 'Text' },
    ]);
  });
  it('counts line like the Mac (DE/EN, singular/plural)', () => {
    const g = gistOf(SAMPLE_PROMPT_DE);
    expect(countsLine('de', g)).toBe('5 Anforderungen · 3 Prüfpunkte · 2 Regeln · 1 offene Frage');
    expect(countsLine('en', { goal: '', tasks: 1, criteria: 0, rules: 1, open: 0 })).toBe('1 requirement · 1 rule');
  });
  it('source + rules labels', () => {
    expect(sourceLabel('claude/sonnet/low')).toBe('Sonnet · low');
    expect(sourceLabel('regeln')).toBe('regeln');
    expect(rulesLabel('de', 'Claude-CLI fehlt')).toBe('Regeln · ohne Claude-CLI');
    expect(rulesLabel('de', 'Zeitlimit (45 s)')).toBe('Regeln · Zeitlimit (45 s)');
    expect(rulesLabel('en', 'Zeitlimit (45 s)')).toBe('Rules · time limit (45 s)');
    expect(reasonText('en', 'Claude nicht erreichbar')).toBe('Claude not reachable');
  });
  it('every string exists in DE and EN', () => {
    for (const k of apKeys) { expect(_apDicts.de[k], k).toBeTruthy(); expect(_apDicts.en[k], k).toBeTruthy(); }
    expect(apt('de', 'titleDone')).toBe('Dein Agent-Prompt ist fertig');
    expect(apt('de', 'titleOffer')).toBe('Daraus einen Agent-Prompt machen?');
    expect(apt('en', 'buildingLive', { a: 3, b: 9 })).toBe('Claude is writing – 3 of ~9 words');
  });
});
