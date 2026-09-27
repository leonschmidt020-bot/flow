import { describe, expect, it } from 'vitest';
import { _dicts, allKeys, t } from '../../src/shared/i18n';

describe('i18n', () => {
  it('English has every German key and no empty strings', () => {
    for (const k of allKeys) {
      expect(_dicts.en[k], k).toBeTruthy();
      expect(_dicts.de[k], k).toBeTruthy();
    }
  });
  it('placeholders are filled', () => {
    expect(t('de', 'modelDownloading', { pct: 42 })).toBe('Wird geladen … 42 %');
    expect(t('en', 'version', { v: '1.0.0' })).toBe('Version 1.0.0');
  });
  it('no forbidden brand names', () => {
    for (const l of ['de', 'en'] as const) for (const k of allKeys) expect(_dicts[l][k].toLowerCase()).not.toContain('wispr');
  });
});
