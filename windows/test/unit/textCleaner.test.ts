import { describe, expect, it } from 'vitest';
import { applyRules, tidy, applyDictionary, removeFillers } from '../../src/core/textCleaner';
import { processTranscript } from '../../src/core/pipeline';

const all = { removeFillers: true, voiceCommands: true, dictionary: [] };

describe('filler words', () => {
  it('removes ähm/äh and keeps "um" (German preposition)', () => {
    expect(applyRules('Ähm ich komme um zehn Uhr, äh, zum Meeting.', all)).toBe('Ich komme um zehn Uhr, zum Meeting.');
  });
  it('removes English fillers and doubled words', () => {
    expect(applyRules('So uh I I think the the plan works.', all)).toBe('So I think the plan works.');
  });
  it('keeps doubled words when disabled', () => {
    expect(applyRules('ich ich weiß', { ...all, removeFillers: false })).toBe('Ich ich weiß');
  });
  it('handles umlaut words as whole words for repeats', () => {
    expect(removeFillers('schön schön gemacht')).toBe('schön gemacht');
    expect(removeFillers('Müller Müllers')).toBe('Müller Müllers');
  });
});

describe('voice commands', () => {
  it('neue Zeile / neuer Absatz', () => {
    expect(applyRules('Hallo Anna, neue Zeile wie geht es dir? Neuer Absatz Viele Grüße', all)).toBe('Hallo Anna\nWie geht es dir?\n\nViele Grüße');
  });
  it('new line / new paragraph', () => {
    expect(applyRules('first point new line second point new paragraph thanks', all)).toBe('First point\nSecond point\n\nThanks');
  });
  it('off → literal', () => {
    expect(applyRules('neue Zeile', { ...all, voiceCommands: false })).toBe('Neue Zeile');
  });
});

describe('dictionary', () => {
  const dictionary = [{ heard: 'clip vault', write: 'ClipVault' }, { heard: 'nico', write: 'Nico' }, { heard: 'hint', write: 'X', vocabOnly: true }];
  it('replaces whole words case-insensitively', () => {
    expect(applyDictionary('Öffne clip vault und Clip Vault', dictionary)).toBe('Öffne ClipVault und ClipVault');
  });
  it('no partial matches', () => {
    expect(applyDictionary('nicos Auto', dictionary)).toBe('nicos Auto');
  });
  it('vocabOnly entries do not replace', () => {
    expect(applyDictionary('hint', dictionary)).toBe('hint');
  });
  it('special characters in entries are literal', () => {
    expect(applyDictionary('c plus plus ist toll', [{ heard: 'c plus plus', write: 'C++ ($1)' }])).toBe('C++ ($1) ist toll');
  });
});

describe('tidy', () => {
  it('spaces and capitalisation', () => {
    expect(tidy('hallo .Wie geht es?Gut')).toBe('Hallo. Wie geht es? Gut');
    expect(tidy('hallo.wie')).toBe('Hallo.wie');
    expect(tidy('ungefähr3000 Leute')).toBe('Ungefähr 3000 Leute');
    expect(tidy('claude.ai und 9.40 Uhr')).toBe('Claude.ai und 9.40 Uhr');
  });
});

describe('pipeline', () => {
  const o = { ...all, polish: true, dictionary: [{ heard: 'flow app', write: 'Flow' }] };
  it('full chain: fillers → dictionary → polish (self-correction)', () => {
    expect(processTranscript('ähm wir treffen uns am Donnerstag, nein warte, am Freitag in der flow app', o))
      .toBe('Wir treffen uns am Freitag in der Flow.');
  });
  it('lists by voice', () => {
    expect(processTranscript('Ich muss noch Milch, Brot, Eier und Butter kaufen.', o)).toBe('Einkaufen:\n- Milch\n- Brot\n- Eier\n- Butter');
  });
  it('polish off keeps sentence but honours explicit hint', () => {
    expect(processTranscript('Milch, Brot und Eier als Liste', { ...o, polish: false })).toBe('- Milch\n- Brot\n- Eier');
    expect(processTranscript('wir treffen uns am Donnerstag, nein warte, am Freitag', { ...o, polish: false })).toBe('Wir treffen uns am Donnerstag, nein warte, am Freitag');
  });
  it('empty stays empty', () => {
    expect(processTranscript('  ähm  ', o)).toBe('');
  });
});
