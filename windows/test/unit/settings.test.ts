import { describe, expect, it } from 'vitest';
import { DEFAULTS, migrateSettings, patchSettings, SETTINGS_VERSION } from '../../src/shared/settings';

describe('settings migration', () => {
  it('empty / garbage → defaults', () => {
    expect(migrateSettings(undefined)).toEqual(DEFAULTS);
    expect(migrateSettings('nope')).toEqual(DEFAULTS);
    expect(migrateSettings([1, 2])).toEqual(DEFAULTS);
  });
  it('v1 field names and legacy values are migrated', () => {
    const s = migrateSettings({
      lang: 'german', uiLanguage: 'en', hotkey: 'ctrl+win', fillers: false, commands: false, autostart: false,
      engine: 'whisper', micUID: 'abc', aiPolish: 'off', dictionary: { 'clip vault': 'ClipVault', nico: 'Nico' },
    });
    expect(s.version).toBe(SETTINGS_VERSION);
    expect(s.language).toBe('de');
    expect(s.locale).toBe('en');
    expect(s.hotkey).toBe('CtrlWin');
    expect(s.removeFillers).toBe(false);
    expect(s.voiceCommands).toBe(false);
    expect(s.startWithWindows).toBe(false);
    expect(s.engine).toBe('whisper-turbo');
    expect(s.micDeviceId).toBe('abc');
    expect(s.polish).toBe(false);
    expect(s.dictionary).toEqual([{ heard: 'clip vault', write: 'ClipVault' }, { heard: 'nico', write: 'Nico' }]);
  });
  it('Mac-app style dictionary array is accepted, invalid entries dropped, duplicates removed', () => {
    const s = migrateSettings({ version: 2, dictionary: [
      { heard: 'Timo', write: 'Timo', learned: true }, { heard: '', write: 'x' }, { heard: 'timo', write: 'dup' }, { nope: 1 }, { heard: 'a', write: 'b', vocabOnly: true },
    ] });
    expect(s.dictionary).toEqual([{ heard: 'Timo', write: 'Timo' }, { heard: 'a', write: 'b', vocabOnly: true }]);
  });
  it('invalid values fall back per field, valid ones stay', () => {
    const s = migrateSettings({ version: 2, hotkey: 'F13', language: 'fr', engine: 'x', historyRetentionDays: -5, keepInClipboard: true, locale: 'en' });
    expect(s.hotkey).toBe(DEFAULTS.hotkey);
    expect(s.language).toBe('auto');
    expect(s.engine).toBe('parakeet-v3');
    expect(s.historyRetentionDays).toBe(1);
    expect(s.keepInClipboard).toBe(true);
    expect(s.locale).toBe('en');
  });
  it('v2 files are not re-interpreted as v1', () => {
    const s = migrateSettings({ version: 2, lang: 'en', language: 'de' });
    expect(s.language).toBe('de');
  });
  it('patch validates', () => {
    const s = patchSettings(DEFAULTS, { hotkey: 'F9', language: 'en' });
    expect(s.hotkey).toBe('F9');
    expect(patchSettings(s, { hotkey: 'Bogus' as never }).hotkey).toBe('RightCtrl');
  });
  it('is idempotent', () => {
    const once = migrateSettings({ lang: 'english', hotkey: 'rctrl' });
    expect(migrateSettings(once)).toEqual(once);
  });
});
