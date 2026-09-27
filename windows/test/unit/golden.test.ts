// Behavioural parity with the Mac app: every case of the Mac regression sets (PolishCases + ListCases,
// all 5 target apps) must produce exactly what the Mac rules produced (test/fixtures/mac-golden.json).
import { describe, expect, it } from 'vitest';
import golden from '../fixtures/mac-golden.json';
import * as QP from '../../src/core/quickPolish';
import { targetForBundle, type Target } from '../../src/core/smartLists';

const norm = (s: string) => s.replace(/[ \t]+/g, ' ').trim();

describe('QuickPolish parity with the Mac app (PolishCases)', () => {
  const cases = golden.polish.filter((c) => !c.screen); // screen-context cases need macOS accessibility
  it('has cases', () => expect(cases.length).toBeGreaterThan(100));
  for (const c of cases) {
    it(`${c.id} ${c.tag}`, () => {
      expect(norm(QP.apply(c.input, targetForBundle(c.app)).text)).toBe(norm(c.mac));
    });
  }
});

describe('SmartLists parity with the Mac app (ListCases × 5 targets)', () => {
  it('has cases', () => expect(golden.lists.length).toBeGreaterThan(250));
  for (const c of golden.lists) {
    it(`${c.id} ${c.tag}`, () => {
      for (const [target, mac] of Object.entries(c.mac as Record<string, string>)) {
        expect(norm(QP.apply(c.input, target as Target).text), `${c.id} @ ${target}`).toBe(norm(mac));
      }
    });
  }
});
